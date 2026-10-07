import 'package:sqflite/sqflite.dart';

import '../contracts/contracts.dart';
import '../core/ids.dart';
import 'local_db.dart';
import 'outbox.dart';

/// A credit customer as this phone knows them.
class LocalCustomer {
  const LocalCustomer({
    required this.id,
    required this.name,
    required this.balanceSantim,
    this.phone,
    this.note,
    this.pendingSantim = 0,
  });

  final String id;
  final String name;
  final String? phone;
  final String? note;

  /// What they owe **now, as far as this phone can tell**: the server's figure plus
  /// whatever this phone has sold them on credit or taken from them that is still queued.
  /// Positive: they owe the pharmacy. Negative: they have paid ahead.
  final int balanceSantim;

  /// The queued part of [balanceSantim] — not yet on the server, and so not yet visible to
  /// any other phone. Shown so the figure is honest about how sure it is.
  final int pendingSantim;
}

/// One entry in a customer's history on this phone.
class CreditEntry {
  const CreditEntry({
    required this.at,
    required this.amountSantim,
    required this.isPayment,
    required this.synced,
    this.method,
  });
  final DateTime at;

  /// Always positive; [isPayment] says which way it moved the balance.
  final int amountSantim;
  final bool isPayment;
  final bool synced;
  final String? method;
}

/// The customer credit ledger on the device — ዕዳ (FR-16, ADR-034).
///
/// Everything a counter does with a debt works with no network: opening an account for
/// someone, selling to them on credit (in `SaleRepository`), and taking money against what
/// they owe. Each commits locally and queues, like a sale.
///
/// **The balance is two numbers added together, and it matters that they stay two.** The
/// server knows every credit sale and repayment that has synced, from every phone, and
/// sends that figure on each pull. This phone knows what it has done since. Neither
/// overwrites the other: a pull replaces the server's figure and leaves the queue alone,
/// and an acknowledgement moves an entry out of the queue at the moment the next pull
/// brings a server figure that already includes it. It is the cash-up's rule (ADR-012 §3)
/// applied to money owed.
class CustomerRepository {
  CustomerRepository(this._db, this._outbox);

  final LocalDb _db;
  final Outbox _outbox;

  /// What this phone has put on each customer's account that the server has not
  /// acknowledged: credit sold, less repayments taken.
  static const _pending = '''
    COALESCE((SELECT SUM(p.amount_santim)
                FROM payment p JOIN sale s ON s.id = p.sale_id
               WHERE s.customer_id = c.id AND p.method = 'credit' AND s.synced = 0), 0)
    - COALESCE((SELECT SUM(cp.amount_santim)
                  FROM credit_payment cp
                 WHERE cp.customer_id = c.id AND cp.synced = 0), 0)
  ''';

  /// Every customer, who owes most first — the order an owner chasing debts reads in.
  Future<List<LocalCustomer>> customers() async {
    final rows = await _db.db.rawQuery('''
      SELECT c.id, c.name, c.phone, c.note, c.balance_santim AS server, $_pending AS pending
        FROM customer c
       WHERE c.deleted = 0
       ORDER BY (c.balance_santim + $_pending) DESC, c.name COLLATE NOCASE
    ''');
    return rows.map(_customer).toList();
  }

  Future<LocalCustomer?> customer(String id) async {
    final rows = await _db.db.rawQuery('''
      SELECT c.id, c.name, c.phone, c.note, c.balance_santim AS server, $_pending AS pending
        FROM customer c WHERE c.id = ?
    ''', [id]);
    return rows.isEmpty ? null : _customer(rows.first);
  }

  static LocalCustomer _customer(Map<String, Object?> r) {
    final pending = (r['pending'] as int?) ?? 0;
    return LocalCustomer(
      id: r['id']! as String,
      name: r['name']! as String,
      phone: r['phone'] as String?,
      note: r['note'] as String?,
      balanceSantim: ((r['server'] as int?) ?? 0) + pending,
      pendingSantim: pending,
    );
  }

  /// Everything owed to the pharmacy, as this phone sees it. Customers who have paid ahead
  /// are not netted off: money one person is owed back does not make another's debt smaller.
  Future<int> totalOwed() async {
    final all = await customers();
    return all.fold<int>(
        0, (sum, c) => c.balanceSantim > 0 ? sum + c.balanceSantim : sum);
  }

  /// Opens an account for someone, at the counter, offline.
  ///
  /// The id is minted here (ADR-006), so the credit sale that follows can name the
  /// customer before the server has heard of either — and the outbox keeps the two in
  /// order.
  Future<LocalCustomer> create({
    required String name,
    String? phone,
    String? note,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw ArgumentError('a customer needs a name');
    final id = newId();
    final createdAt = DateTime.now().toUtc().toIso8601String();
    final cleanPhone = _blankToNull(phone);
    final cleanNote = _blankToNull(note);

    await _db.db.transaction((txn) async {
      await txn.insert('customer', {
        'id': id,
        'name': trimmed,
        'phone': cleanPhone,
        'note': cleanNote,
        'balance_santim': 0,
        'change_seq': 0,
        'deleted': 0,
        'synced': 0,
      });
      await _outbox.enqueue(
        txn,
        opId: newId(),
        entityType: 'customer',
        entityId: id,
        payload: {
          'name': trimmed,
          'phone': cleanPhone,
          'note': cleanNote,
          'createdAt': createdAt,
        },
      );
    });
    return LocalCustomer(
        id: id,
        name: trimmed,
        phone: cleanPhone,
        note: cleanNote,
        balanceSantim: 0);
  }

  static String? _blankToNull(String? value) {
    final v = value?.trim();
    return v == null || v.isEmpty ? null : v;
  }

  /// Takes money against what a customer owes.
  ///
  /// [shiftId] is the open till, when there is one: cash handed over here goes into the
  /// same drawer as the cash from sales, so the cash-up has to expect it (BR-8.2).
  ///
  /// The amount may exceed the balance. Someone settling 480 with a 500 note and waving
  /// away the change is ordinary, and the honest record is that they are 20 ahead.
  Future<String> recordPayment({
    required String customerId,
    required int amountSantim,
    required String branchId,
    required String receivedBy,
    String method = 'cash',
    String? shiftId,
    String? note,
  }) async {
    if (amountSantim <= 0) {
      throw ArgumentError('a repayment must be more than nothing');
    }
    if (method != 'cash' && method != 'other_recorded') {
      throw ArgumentError('unknown payment method: $method');
    }
    final id = newId();
    final paidAt = DateTime.now().toUtc().toIso8601String();
    final cleanNote = _blankToNull(note);

    await _db.db.transaction((txn) async {
      await txn.insert('credit_payment', {
        'id': id,
        'branch_id': branchId,
        'customer_id': customerId,
        'amount_santim': amountSantim,
        'method': method,
        'paid_at': paidAt,
        'shift_id': shiftId,
        'received_by': receivedBy,
        'note': cleanNote,
        'synced': 0,
      });
      await _outbox.enqueue(
        txn,
        opId: newId(),
        entityType: 'credit_payment',
        entityId: id,
        payload: {
          'customerId': customerId,
          'amountSantim': amountSantim,
          'method': method,
          'paidAt': paidAt,
          'shiftId': shiftId,
          'receivedBy': receivedBy,
          'note': cleanNote,
        },
      );
    });
    return id;
  }

  /// What this phone has recorded for one customer, newest first.
  ///
  /// **This phone's entries only.** The balance above is complete — it starts from the
  /// server's figure — but the list is what was rung up here. A full statement across
  /// phones needs the server and is a report, not something a counter waits for.
  Future<List<CreditEntry>> history(String customerId, {int limit = 30}) async {
    final rows = await _db.db.rawQuery('''
      SELECT s.sold_at AS at, p.amount_santim AS amount, 0 AS is_payment,
             s.synced AS synced, NULL AS method
        FROM payment p JOIN sale s ON s.id = p.sale_id
       WHERE s.customer_id = ? AND p.method = 'credit'
      UNION ALL
      SELECT cp.paid_at, cp.amount_santim, 1, cp.synced, cp.method
        FROM credit_payment cp WHERE cp.customer_id = ?
      ORDER BY at DESC LIMIT ?
    ''', [customerId, customerId, limit]);
    return rows
        .map((r) => CreditEntry(
              at: DateTime.parse(r['at']! as String),
              amountSantim: r['amount']! as int,
              isPayment: (r['is_payment']! as int) == 1,
              synced: (r['synced']! as int) == 1,
              method: r['method'] as String?,
            ))
        .toList();
  }

  /// Applies the customers of a pull, inside the pull's own transaction.
  ///
  /// Replaces the **server's** figure and nothing else. What this phone still has queued
  /// lives in other tables and is added on at read time, so a pull can never erase a debt
  /// that has not synced yet.
  static Future<void> applyPulled(
      DatabaseExecutor txn, List<CustomerRef> customers) async {
    for (final c in customers) {
      await txn.insert(
        'customer',
        {
          'id': c.id,
          'name': c.name,
          'phone': c.phone,
          'note': c.note,
          'balance_santim': c.balanceSantim,
          'change_seq': c.changeSeq,
          'deleted': c.deletedAt == null ? 0 : 1,
          // It came from the server, so the server has it.
          'synced': 1,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  /// Builds the wire operation for a queued customer or repayment.
  Operation toOperation(
    OutboxEntry entry, {
    required String tenantId,
    required String branchId,
    required String actorId,
    required String terminalId,
  }) {
    switch (entry.entityType) {
      case 'customer':
        return OperationCustomer(
          opId: entry.opId,
          terminalId: terminalId,
          terminalSeq: entry.terminalSeq,
          entityId: entry.entityId,
          opType: 'create',
          baseVersion: null,
          tenantId: tenantId,
          branchId: branchId,
          actorId: actorId,
          clientTs: entry.createdAt,
          entityType: 'customer',
          payload: CustomerPayload.fromJson(entry.payload),
        );
      case 'credit_payment':
        return OperationCreditPayment(
          opId: entry.opId,
          terminalId: terminalId,
          terminalSeq: entry.terminalSeq,
          entityId: entry.entityId,
          opType: 'create',
          baseVersion: null,
          tenantId: tenantId,
          branchId: branchId,
          actorId: actorId,
          clientTs: entry.createdAt,
          entityType: 'credit_payment',
          payload: CreditPaymentPayload.fromJson(entry.payload),
        );
      default:
        throw StateError('not a credit entity type: ${entry.entityType}');
    }
  }
}
