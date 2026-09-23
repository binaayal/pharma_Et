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
  });

  final LocalProduct product;
  final int qty;
  final String? batchId;

  /// Integer arithmetic only. The server and the database both assert
  /// `lineTotal == qty * unitPrice`, so a client that computed it any other way would have
  /// its sales rejected (guardian G4).
  int get lineTotalSantim =>
      money.lineTotalSantim(qty: qty, unitPriceSantim: product.priceSantim);
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
  }) async {
    if (lines.isEmpty) {
      throw ArgumentError('a sale must have at least one line');
    }

    final saleId = newId();
    final opId = newId();
    final soldAt = DateTime.now().toUtc();
    final total = lines.fold<int>(0, (sum, line) => sum + line.lineTotalSantim);

    final linePayloads = <Map<String, dynamic>>[];
    final paymentId = newId();

    await _db.db.transaction((txn) async {
      await txn.insert('sale', {
        'id': saleId,
        'branch_id': branchId,
        'cashier_id': cashierId,
        'total_santim': total,
        'sold_at': soldAt.toIso8601String(),
        'synced': 0,
      });

      for (final line in lines) {
        final lineId = newId();
        await txn.insert('sale_line', {
          'id': lineId,
          'sale_id': saleId,
          'product_id': line.product.id,
          'batch_id': line.batchId,
          'qty': line.qty,
          'unit_price_santim': line.product.priceSantim,
          'line_total_santim': line.lineTotalSantim,
        });

        linePayloads.add({
          'id': lineId,
          'productId': line.product.id,
          'batchId': line.batchId,
          'qty': line.qty,
          'unitPriceSantim': line.product.priceSantim,
          'lineTotalSantim': line.lineTotalSantim,
        });

        if (line.batchId != null) {
          await _catalog.decrementLocal(txn,
              batchId: line.batchId!, qty: line.qty);
        }
      }

      await txn.insert('payment', {
        'id': paymentId,
        'sale_id': saleId,
        'method': 'cash',
        'amount_santim': total,
      });

      // Enqueued inside the same transaction, so "the sale is committed" and "the sale will
      // sync" are one indivisible fact. There is no window in which a receipt exists that
      // the server will never hear about.
      await _outbox.enqueue(
        txn,
        opId: opId,
        entityType: 'sale',
        entityId: saleId,
        payload: {
          'shiftId': null,
          'cashierId': cashierId,
          'soldAt': soldAt.toIso8601String(),
          'totalSantim': total,
          'lines': linePayloads,
          'payments': [
            {'id': paymentId, 'method': 'cash', 'amountSantim': total},
          ],
        },
      );
    });

    return CommittedSale(saleId: saleId, totalSantim: total);
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

  /// Builds the wire operation for a queued sale (docs/04 §7.1).
  ///
  /// The envelope is assembled from the generated contract types, so a change to the
  /// schema breaks this at compile time rather than at a pharmacy counter.
  OperationSale toOperation(
    OutboxEntry entry, {
    required String tenantId,
    required String branchId,
    required String actorId,
    required String terminalId,
  }) {
    final payload = entry.payload;
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
      // When the terminal authored it, not when it happens to be sending. Recorded for
      // forensics only — ordering comes from terminalSeq (ADR-006).
      clientTs: entry.createdAt,
      entityType: 'sale',
      payload: SalePayload.fromJson(payload),
    );
  }
}
