import 'package:sqflite/sqflite.dart';

import '../contracts/contracts.dart';
import '../core/ids.dart';
import 'local_db.dart';
import 'outbox.dart';

/// A supplier as this phone knows them.
class LocalSupplier {
  const LocalSupplier({
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

  /// What the pharmacy owes them **now, as far as this phone can tell**: the server's
  /// figure plus whatever this phone has received on account or paid that is still queued.
  /// Positive: the pharmacy owes. Negative: it has paid ahead.
  final int balanceSantim;

  /// The queued part of [balanceSantim] — not yet on the server, so not yet visible to any
  /// other phone.
  final int pendingSantim;
}

/// One entry in a supplier's history on this phone.
class PayableEntry {
  const PayableEntry({
    required this.at,
    required this.amountSantim,
    required this.isPayment,
    required this.synced,
    this.costSantim,
    this.method,
    this.fromTill = false,
  });
  final DateTime at;

  /// For a delivery, what it left owing; for a payment, what was paid. Never negative.
  final int amountSantim;
  final bool isPayment;
  final bool synced;

  /// What a delivery cost in all — so "80.00 delivered, 30.00 owing" can be said.
  final int? costSantim;
  final String? method;

  /// Whether a payment's cash came out of a till.
  final bool fromTill;
}

/// Suppliers and what is owed to them, on the device (FR-18, ADR-038).
///
/// The mirror image of [CustomerRepository]: there the pharmacy is owed, here it owes. A
/// supplier is opened while receiving, offline; a delivery says what of it is not paid yet
/// (in `InventoryRepository.commitReceipt`); a payment is recorded here.
///
/// **The balance is two numbers added together**, exactly as a customer's is: the server's
/// figure from the last pull, plus what this phone has done since that is still queued. A
/// pull replaces the first and cannot touch the second (ADR-012 §3).
class SupplierRepository {
  SupplierRepository(this._db, this._outbox);

  final LocalDb _db;
  final Outbox _outbox;

  /// What this phone has put on each supplier's account that the server has not
  /// acknowledged: deliveries left owing, less payments made.
  static const _pending = '''
    COALESCE((SELECT SUM(g.owed_santim)
                FROM goods_receipt g
               WHERE g.supplier_id = s.id AND g.synced = 0), 0)
    - COALESCE((SELECT SUM(sp.amount_santim)
                  FROM supplier_payment sp
                 WHERE sp.supplier_id = s.id AND sp.synced = 0), 0)
  ''';

  /// Every supplier, the one owed most first — the order someone deciding whom to pay
  /// reads in.
  Future<List<LocalSupplier>> suppliers() async {
    final rows = await _db.db.rawQuery('''
      SELECT s.id, s.name, s.phone, s.note, s.balance_santim AS server, $_pending AS pending
        FROM supplier s
       WHERE s.deleted = 0
       ORDER BY (s.balance_santim + $_pending) DESC, s.name COLLATE NOCASE
    ''');
    return rows.map(_supplier).toList();
  }

  Future<LocalSupplier?> supplier(String id) async {
    final rows = await _db.db.rawQuery('''
      SELECT s.id, s.name, s.phone, s.note, s.balance_santim AS server, $_pending AS pending
        FROM supplier s WHERE s.id = ?
    ''', [id]);
    return rows.isEmpty ? null : _supplier(rows.first);
  }

  /// The supplier with exactly this name, ignoring case and outer spaces — so "epss" typed
  /// on a receipt is EPSS, and not a second supplier owed separately.
  Future<LocalSupplier?> byName(String name) async {
    final rows = await _db.db.rawQuery('''
      SELECT s.id, s.name, s.phone, s.note, s.balance_santim AS server, $_pending AS pending
        FROM supplier s
       WHERE s.deleted = 0 AND s.name = ? COLLATE NOCASE
       LIMIT 1
    ''', [name.trim()]);
    return rows.isEmpty ? null : _supplier(rows.first);
  }

  static LocalSupplier _supplier(Map<String, Object?> r) {
    final pending = (r['pending'] as int?) ?? 0;
    return LocalSupplier(
      id: r['id']! as String,
      name: r['name']! as String,
      phone: r['phone'] as String?,
      note: r['note'] as String?,
      balanceSantim: ((r['server'] as int?) ?? 0) + pending,
      pendingSantim: pending,
    );
  }

  /// Everything the pharmacy owes, as this phone sees it. A supplier paid ahead is not
  /// netted off: money one supplier holds does not make the debt to another smaller.
  Future<int> totalOwed() async {
    final all = await suppliers();
    return all.fold<int>(
        0, (sum, s) => s.balanceSantim > 0 ? sum + s.balanceSantim : sum);
  }

  /// Opens a supplier, offline. The id is minted here (ADR-006), so the receipt that
  /// follows can name it before the server has heard of either.
  Future<LocalSupplier> create({
    required String name,
    String? phone,
    String? note,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw ArgumentError('a supplier needs a name');
    final id = newId();
    final createdAt = DateTime.now().toUtc().toIso8601String();
    final cleanPhone = _blankToNull(phone);
    final cleanNote = _blankToNull(note);

    await _db.db.transaction((txn) async {
      await txn.insert('supplier', {
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
        entityType: 'supplier',
        entityId: id,
        payload: {
          'name': trimmed,
          'phone': cleanPhone,
          'note': cleanNote,
          'createdAt': createdAt,
        },
      );
    });
    return LocalSupplier(
        id: id,
        name: trimmed,
        phone: cleanPhone,
        note: cleanNote,
        balanceSantim: 0);
  }

  /// The supplier a receipt names: the one already known by that name, or a new one.
  ///
  /// This is how the supplier list builds itself. Nobody is asked to "set up suppliers"
  /// before they may receive a delivery; they type the name they always typed.
  Future<LocalSupplier> findOrCreate(String name) async =>
      await byName(name) ?? await create(name: name);

  static String? _blankToNull(String? value) {
    final v = value?.trim();
    return v == null || v.isEmpty ? null : v;
  }

  /// Records money paid to a supplier.
  ///
  /// [shiftId] is set only when the cash came **out of an open till**. That cash has left
  /// the drawer, so the cash-up stops expecting it (BR-8.2). Cash from anywhere else, and
  /// any other tender, touches no till.
  ///
  /// The amount may exceed what is owed: that is a payment in advance.
  Future<String> recordPayment({
    required String supplierId,
    required int amountSantim,
    required String branchId,
    required String paidBy,
    String method = 'cash',
    String? shiftId,
    String? note,
  }) async {
    if (amountSantim <= 0) {
      throw ArgumentError('a payment must be more than nothing');
    }
    if (method != 'cash' && method != 'other_recorded') {
      throw ArgumentError('unknown payment method: $method');
    }
    if (shiftId != null && method != 'cash') {
      // Only cash leaves a drawer. A transfer "from the till" is a contradiction, and
      // recording one would take money off a cash-up that never held it.
      throw ArgumentError('only cash can come out of a till');
    }
    final id = newId();
    final paidAt = DateTime.now().toUtc().toIso8601String();
    final cleanNote = _blankToNull(note);

    await _db.db.transaction((txn) async {
      await txn.insert('supplier_payment', {
        'id': id,
        'branch_id': branchId,
        'supplier_id': supplierId,
        'amount_santim': amountSantim,
        'method': method,
        'paid_at': paidAt,
        'shift_id': shiftId,
        'paid_by': paidBy,
        'note': cleanNote,
        'synced': 0,
      });
      await _outbox.enqueue(
        txn,
        opId: newId(),
        entityType: 'supplier_payment',
        entityId: id,
        payload: {
          'supplierId': supplierId,
          'amountSantim': amountSantim,
          'method': method,
          'paidAt': paidAt,
          'shiftId': shiftId,
          'paidBy': paidBy,
          'note': cleanNote,
        },
      );
    });
    return id;
  }

  /// What this phone has recorded for one supplier, newest first: its deliveries and its
  /// payments. **This phone's entries only** — the balance is complete, the list is not
  /// (as with a customer's history).
  Future<List<PayableEntry>> history(String supplierId,
      {int limit = 30}) async {
    final rows = await _db.db.rawQuery('''
      SELECT g.received_at AS at, g.owed_santim AS amount, 0 AS is_payment,
             g.synced AS synced, NULL AS method, 0 AS from_till,
             (SELECT COALESCE(SUM(l.qty * l.cost_santim), 0)
                FROM goods_receipt_line l WHERE l.goods_receipt_id = g.id) AS cost
        FROM goods_receipt g WHERE g.supplier_id = ?
      UNION ALL
      SELECT sp.paid_at, sp.amount_santim, 1, sp.synced, sp.method,
             CASE WHEN sp.shift_id IS NULL THEN 0 ELSE 1 END, NULL
        FROM supplier_payment sp WHERE sp.supplier_id = ?
      ORDER BY at DESC LIMIT ?
    ''', [supplierId, supplierId, limit]);
    return rows
        .map((r) => PayableEntry(
              at: DateTime.parse(r['at']! as String),
              amountSantim: r['amount']! as int,
              isPayment: (r['is_payment']! as int) == 1,
              synced: (r['synced']! as int) == 1,
              costSantim: r['cost'] as int?,
              method: r['method'] as String?,
              fromTill: (r['from_till']! as int) == 1,
            ))
        .toList();
  }

  /// Applies the suppliers of a pull, inside the pull's own transaction. Replaces the
  /// **server's** figure and nothing else; what is still queued lives in other tables.
  static Future<void> applyPulled(
      DatabaseExecutor txn, List<SupplierRef> suppliers) async {
    for (final s in suppliers) {
      await txn.insert(
        'supplier',
        {
          'id': s.id,
          'name': s.name,
          'phone': s.phone,
          'note': s.note,
          'balance_santim': s.balanceSantim,
          'change_seq': s.changeSeq,
          'deleted': s.deletedAt == null ? 0 : 1,
          'synced': 1,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  /// Builds the wire operation for a queued supplier or payment.
  Operation toOperation(
    OutboxEntry entry, {
    required String tenantId,
    required String branchId,
    required String actorId,
    required String terminalId,
  }) {
    switch (entry.entityType) {
      case 'supplier':
        return OperationSupplier(
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
          entityType: 'supplier',
          payload: SupplierPayload.fromJson(entry.payload),
        );
      case 'supplier_payment':
        return OperationSupplierPayment(
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
          entityType: 'supplier_payment',
          payload: SupplierPaymentPayload.fromJson(entry.payload),
        );
      default:
        throw StateError('not a supplier entity type: ${entry.entityType}');
    }
  }
}
