import '../contracts/contracts.dart';
import '../core/ids.dart';
import '../core/money.dart' as money;
import 'catalog_repository.dart';
import 'local_db.dart';
import 'outbox.dart';

/// One line of a sale being assembled at the counter.
class CartLine {
  CartLine({
    required this.product,
    required this.qty,
    required this.batchId,
    this.pack,
    this.expiryOverrideBy,
    this.wholesale = false,
  });

  final LocalProduct product;

  /// How many, **in the unit being sold** — tablets, or boxes when [pack] is set.
  final int qty;
  final String? batchId;

  /// The pack this line is rung up in, or null for the base unit (FR-11, ADR-030).
  final ProductPack? pack;

  /// Whether this line is priced from the wholesale list (FR-19, ADR-037).
  final bool wholesale;

  /// The price of one unit of [qty]. A pack has its own price; it is never the base price
  /// multiplied up, and the base price is never a pack price divided down.
  ///
  /// On a wholesale sale it is the wholesale price **of the unit being sold**, where the
  /// owner has set one. Where they have not, it is the ordinary price: a product with no
  /// wholesale price is sold to a clinic at what everyone pays, never at a guess.
  int get unitPriceSantim {
    final p = pack;
    if (p != null) {
      return (wholesale ? p.wholesalePriceSantim : null) ?? p.priceSantim;
    }
    return (wholesale ? product.wholesalePriceSantim : null) ??
        product.priceSantim;
  }

  /// What the line takes off the shelf, in base units — the only figure stock is ever
  /// moved or compared by.
  int get baseQty => qty * (pack?.size ?? 1);

  /// What one unit of [qty] is called: "tablet", or "box".
  String get unitName => pack?.name ?? product.unit;

  /// Who authorised dispensing from an already-expired batch (E-4.2, ADR-020). Null in the
  /// ordinary case, and null too when nobody authorised it — in which case [batchId] is null
  /// as well, and the sale goes through unattributed.
  final String? expiryOverrideBy;

  /// Integer arithmetic only. The server and the database both assert
  /// `lineTotal == qty * unitPrice`, so a client that computed it any other way would have
  /// its sales rejected (guardian G4).
  int get lineTotalSantim =>
      money.lineTotalSantim(qty: qty, unitPriceSantim: unitPriceSantim);
}

class CommittedSale {
  const CommittedSale({required this.saleId, required this.totalSantim});
  final String saleId;
  final int totalSantim;
}

/// Commits a sale to local storage and queues it for sync.
///
/// This is the single most important method in the mobile app, and its shape is the whole
/// argument of ADR-002: **one local transaction, no network.**
///
/// The sale, its lines, its payments, the stock decrement and the outbox entry all commit
/// together or not at all. When that transaction returns, the sale is durable — it will
/// survive the app being killed, the battery dying, or the shop losing power mid-tap — and
/// it is guaranteed to reach the server eventually. Nothing about that guarantee depends on
/// the network having been available at any point (NFR-1.3, guardian G7).
class SaleRepository {
  SaleRepository(this._db, this._outbox, this._catalog);

  final LocalDb _db;
  final Outbox _outbox;
  final CatalogRepository _catalog;

  Future<CommittedSale> commitSale({
    required List<CartLine> lines,
    required String tenantId,
    required String branchId,
    required String cashierId,
    required String terminalId,

    /// The open till session this sale belongs to, so its cash reaches the right cash-up
    /// (BR-8.2). Null only where no shift is open — the sale still commits, because a
    /// missing shift must never stop the counter.
    String? shiftId,

    /// `cash`, or `other_recorded` for Telebirr, CBE Birr and the rest — recorded by hand
    /// in V1, with no live integration (FR-4). Only cash reaches the drawer, so only cash
    /// counts toward a cash-up (BR-8.2).
    String paymentMethod = 'cash',

    /// Who owes the part put on credit (FR-16, ADR-034). Required when [creditSantim] is
    /// more than zero.
    String? customerId,

    /// The price list the cart was rung up on (FR-19). Recorded on the sale so a report
    /// can say how much went out at wholesale; the prices themselves are on the lines.
    bool wholesale = false,

    /// How much of the total is **not paid now** and is owed by [customerId]. The rest —
    /// possibly nothing — is settled by [paymentMethod]. Zero for an ordinary sale.
    int creditSantim = 0,
  }) async {
    if (lines.isEmpty) {
      throw ArgumentError('a sale must have at least one line');
    }
    if (paymentMethod != 'cash' && paymentMethod != 'other_recorded') {
      throw ArgumentError('unknown payment method: $paymentMethod');
    }
    if (creditSantim < 0) {
      throw ArgumentError('credit cannot be negative');
    }
    if (creditSantim > 0 && customerId == null) {
      // A debt owed by nobody cannot be collected. The server refuses it too.
      throw ArgumentError(
          'a sale on credit must name the customer who owes it');
    }

    final saleId = newId();
    final opId = newId();
    final soldAt = DateTime.now().toUtc();
    final total = lines.fold<int>(0, (sum, line) => sum + line.lineTotalSantim);

    if (creditSantim > total) {
      throw ArgumentError('credit cannot exceed the sale total');
    }

    final linePayloads = <Map<String, dynamic>>[];
    // What was paid now, and what is owed. Integer subtraction; the two always add back
    // up to the total, which the server and the contract both check (G4).
    final paidNow = total - creditSantim;
    final payments = <({String id, String method, int amountSantim})>[
      // An ordinary sale keeps its single payment row exactly as before, even at zero.
      if (paidNow > 0 || creditSantim == 0)
        (id: newId(), method: paymentMethod, amountSantim: paidNow),
      if (creditSantim > 0)
        (id: newId(), method: 'credit', amountSantim: creditSantim),
    ];

    await _db.db.transaction((txn) async {
      await txn.insert('sale', {
        'id': saleId,
        'branch_id': branchId,
        'cashier_id': cashierId,
        'shift_id': shiftId,
        'total_santim': total,
        'sold_at': soldAt.toIso8601String(),
        'synced': 0,
        // Named only when something is owed: a cash sale to a known customer is still
        // just a cash sale, and the debt book is not a purchase history (docs/01 §2.3).
        'customer_id': creditSantim > 0 ? customerId : null,
        'price_tier': wholesale ? 'wholesale' : null,
      });

      for (final line in lines) {
        final lineId = newId();
        await txn.insert('sale_line', {
          'id': lineId,
          'sale_id': saleId,
          'product_id': line.product.id,
          'batch_id': line.batchId,
          'qty': line.qty,
          'unit_price_santim': line.unitPriceSantim,
          'line_total_santim': line.lineTotalSantim,
          'pack_size': line.pack?.size,
          'pack_name': line.pack?.name,
        });

        linePayloads.add({
          'id': lineId,
          'productId': line.product.id,
          'batchId': line.batchId,
          'qty': line.qty,
          'unitPriceSantim': line.unitPriceSantim,
          'lineTotalSantim': line.lineTotalSantim,
          // Contract 1.5.0 (FR-11). Omitted for a loose sale, so that is still
          // byte-identical to what a 1.4.0 terminal sends.
          if (line.pack != null) 'packSize': line.pack!.size,
          if (line.pack != null) 'packName': line.pack!.name,
          // Contract 1.3.0 (E-4.2). Omitted when null so the wire form is byte-identical to
          // a 1.2.0 terminal's for every ordinary sale, which is the whole of the N-1
          // promise in practice.
          if (line.expiryOverrideBy != null)
            'expiryOverrideBy': line.expiryOverrideBy,
        });

        if (line.batchId != null) {
          // Base units: two boxes of thirty take sixty off the batch.
          await _catalog.decrementLocal(txn,
              batchId: line.batchId!, qty: line.baseQty);
        }
      }

      for (final payment in payments) {
        await txn.insert('payment', {
          'id': payment.id,
          'sale_id': saleId,
          'method': payment.method,
          'amount_santim': payment.amountSantim,
        });
      }

      // Enqueued inside the same transaction, so "the sale is committed" and "the sale will
      // sync" are one indivisible fact. There is no window in which a receipt exists that
      // the server will never hear about.
      await _outbox.enqueue(
        txn,
        opId: opId,
        entityType: 'sale',
        entityId: saleId,
        payload: {
          'shiftId': shiftId,
          'cashierId': cashierId,
          'soldAt': soldAt.toIso8601String(),
          'totalSantim': total,
          'lines': linePayloads,
          'payments': [
            for (final payment in payments)
              {
                'id': payment.id,
                'method': payment.method,
                'amountSantim': payment.amountSantim,
              },
          ],
          // Contract 1.7.0 (FR-16). Omitted without credit, so an ordinary sale is still
          // byte-identical to what a 1.6.0 terminal sends.
          if (creditSantim > 0) 'customerId': customerId,
          // Contract 1.8.0 (FR-19). Omitted for retail, for the same reason.
          if (wholesale) 'priceTier': 'wholesale',
        },
      );
    });

    return CommittedSale(saleId: saleId, totalSantim: total);
  }

  /// Today's takings on this device since local midnight — what a cashier's Home shows
  /// without a network (the owner's consolidated figure comes from the server).
  Future<({int count, int totalSantim})> todayOnDevice(String branchId,
      {DateTime? now}) async {
    final at = now ?? DateTime.now();
    final midnight = DateTime(at.year, at.month, at.day).toUtc();
    final rows = await _db.db.rawQuery(
      'SELECT COUNT(*) AS n, COALESCE(SUM(total_santim), 0) AS total '
      'FROM sale WHERE branch_id = ? AND sold_at >= ?',
      [branchId, midnight.toIso8601String()],
    );
    return (
      count: (rows.first['n'] as int?) ?? 0,
      totalSantim: (rows.first['total'] as int?) ?? 0,
    );
  }

  /// The lines of one committed sale, for the receipt (prototype screen 10).
  ///
  /// `packName` is null for a line sold in the base unit, and the pack's name as it was at
  /// the counter otherwise — read from the line, not the product, so a receipt reprinted
  /// after the packs were edited still says what was actually handed over.
  Future<List<({String name, int qty, String? packName, int lineTotalSantim})>>
      linesOf(String saleId) async {
    final rows = await _db.db.rawQuery('''
      SELECT p.name AS name, l.qty AS qty, l.pack_name AS pack_name,
             l.line_total_santim AS total
        FROM sale_line l LEFT JOIN product p ON p.id = l.product_id
       WHERE l.sale_id = ? ORDER BY l.rowid
    ''', [saleId]);
    return rows
        .map((r) => (
              name: (r['name'] as String?) ?? '—',
              qty: r['qty'] as int,
              packName: r['pack_name'] as String?,
              lineTotalSantim: r['total'] as int,
            ))
        .toList();
  }

  Future<List<Map<String, Object?>>> recentSales({int limit = 20}) =>
      _db.db.query(
        'sale',
        orderBy: 'sold_at DESC',
        limit: limit,
      );

  Future<int> unsyncedCount() async {
    final rows = await _db.db
        .rawQuery('SELECT count(*) AS n FROM sale WHERE synced = 0');
    return (rows.first['n'] as int?) ?? 0;
  }

  /// Builds the wire operation for a queued entry (docs/04 §7.1).
  ///
  /// The envelope is assembled from the generated contract types, so a change to the schema
  /// breaks this at compile time rather than at a pharmacy counter. The switch is
  /// exhaustive on purpose: a new entity type added to the outbox without a case here
  /// fails to compile, rather than being silently dropped on the next sync.
  Operation toOperation(
    OutboxEntry entry, {
    required String tenantId,
    required String branchId,
    required String actorId,
    required String terminalId,
  }) {
    // When the terminal authored it, not when it happens to be sending. Recorded for
    // forensics only — ordering comes from terminalSeq (ADR-006).
    final clientTs = entry.createdAt;

    switch (entry.entityType) {
      case 'sale':
        return OperationSale(
          opId: entry.opId,
          terminalId: terminalId,
          terminalSeq: entry.terminalSeq,
          entityId: entry.entityId,
          opType: 'create',
          baseVersion: null,
          tenantId: tenantId,
          branchId: branchId,
          actorId: actorId,
          clientTs: clientTs,
          entityType: 'sale',
          payload: SalePayload.fromJson(entry.payload),
        );
      case 'shift':
        return OperationShift(
          opId: entry.opId,
          terminalId: terminalId,
          terminalSeq: entry.terminalSeq,
          entityId: entry.entityId,
          // A shift is created once and updated when it closes; the server keys on
          // entityId either way, so this states intent rather than driving behaviour.
          opType: entry.payload['closedAt'] == null ? 'create' : 'update',
          baseVersion: null,
          tenantId: tenantId,
          branchId: branchId,
          actorId: actorId,
          clientTs: clientTs,
          entityType: 'shift',
          payload: ShiftPayload.fromJson(entry.payload),
        );
      case 'cash_up':
        return OperationCashUp(
          opId: entry.opId,
          terminalId: terminalId,
          terminalSeq: entry.terminalSeq,
          entityId: entry.entityId,
          opType: 'create',
          baseVersion: null,
          tenantId: tenantId,
          branchId: branchId,
          actorId: actorId,
          clientTs: clientTs,
          entityType: 'cash_up',
          payload: CashUpPayload.fromJson(entry.payload),
        );
      case 'controlled_dispense':
        return OperationControlledDispense(
          opId: entry.opId,
          terminalId: terminalId,
          terminalSeq: entry.terminalSeq,
          entityId: entry.entityId,
          opType: 'create',
          baseVersion: null,
          tenantId: tenantId,
          branchId: branchId,
          actorId: actorId,
          clientTs: clientTs,
          entityType: 'controlled_dispense',
          payload: ControlledDispensePayload.fromJson(entry.payload),
        );
      case 'controlled_adjustment':
        return OperationControlledAdjustment(
          opId: entry.opId,
          terminalId: terminalId,
          terminalSeq: entry.terminalSeq,
          entityId: entry.entityId,
          opType: 'create',
          baseVersion: null,
          tenantId: tenantId,
          branchId: branchId,
          actorId: actorId,
          clientTs: clientTs,
          entityType: 'controlled_adjustment',
          payload: ControlledAdjustmentPayload.fromJson(entry.payload),
        );
      default:
        // Better to fail loudly here than to drop a queued transaction quietly. The entry
        // stays in the outbox either way.
        throw StateError(
            'no envelope builder for entity type "\${entry.entityType}"');
    }
  }
}
