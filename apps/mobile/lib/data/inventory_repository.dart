import '../contracts/contracts.dart';
import '../core/ids.dart';
import 'catalog_repository.dart';
import 'local_db.dart';
import 'outbox.dart';

/// One line of a goods receipt being entered at the counter.
class ReceiptLine {
  const ReceiptLine({
    required this.product,
    required this.lotNo,
    required this.expiryDate,
    required this.qty,
    required this.costSantim,
  });

  final LocalProduct product;
  final String lotNo;

  /// ISO calendar date. Gregorian in storage; the Ethiopian calendar is what the user
  /// sees, and the conversion never reaches this layer (BR-10.2).
  final String expiryDate;
  final int qty;
  final int costSantim;
}

/// Why a count was corrected. Mirrors the contract's closed list exactly.
enum AdjustmentReason {
  recount('recount'),
  damage('damage'),
  expiryWriteoff('expiry_writeoff'),
  theftOrLoss('theft_or_loss'),
  receiptCorrection('receipt_correction'),
  other('other');

  const AdjustmentReason(this.wire);
  final String wire;

  /// Only a recount may go unexplained: an unexplained write-off is indistinguishable from
  /// a covered-up one, and the server refuses it anyway.
  bool get requiresNote => this != AdjustmentReason.recount;
}

/// Goods receipt and stock correction, offline-first (FR-7, FR-3).
///
/// Both are core-loop writes and follow the same rule as a sale: commit locally, queue,
/// never wait on the network. Stock arrives when the wholesaler's van arrives, and a shelf
/// gets counted when somebody notices the number is wrong — neither waits for connectivity,
/// and an app that made them wait would simply not be used for them.
class InventoryRepository {
  InventoryRepository(this._db, this._outbox, this._catalog);

  final LocalDb _db;
  final Outbox _outbox;
  final CatalogRepository _catalog;

  /// Records stock arriving (FR-7 base receipt).
  ///
  /// Local stock is credited immediately so the counter can sell what is physically on the
  /// shelf without waiting for a round trip. The line id doubles as the batch id, so the new
  /// batch is addressable offline with no server-assigned key (ADR-006).
  Future<String> commitReceipt({
    required List<ReceiptLine> lines,
    required String supplierName,
    required String branchId,
  }) async {
    if (lines.isEmpty) {
      throw ArgumentError('a receipt must have at least one line');
    }

    final receiptId = newId();
    final receivedAt = DateTime.now().toUtc();
    final linePayloads = <Map<String, dynamic>>[];

    await _db.db.transaction((txn) async {
      await txn.insert('goods_receipt', {
        'id': receiptId,
        'branch_id': branchId,
        'supplier_name': supplierName,
        'received_at': receivedAt.toIso8601String(),
        'synced': 0,
      });

      for (final line in lines) {
        final lineId = newId();
        await txn.insert('goods_receipt_line', {
          'id': lineId,
          'goods_receipt_id': receiptId,
          'product_id': line.product.id,
          'lot_no': line.lotNo,
          'expiry_date': line.expiryDate,
          'qty': line.qty,
          'cost_santim': line.costSantim,
        });

        linePayloads.add({
          'id': lineId,
          'productId': line.product.id,
          'lotNo': line.lotNo,
          'expiryDate': line.expiryDate,
          'qty': line.qty,
          'costSantim': line.costSantim,
        });

        // Credit local stock now. The server does the same on apply, keyed on the same
        // batch id, so the two converge rather than double-counting.
        await _catalog.upsertLocalBatch(
          txn,
          batchId: lineId,
          branchId: branchId,
          productId: line.product.id,
          lotNo: line.lotNo,
          expiryDate: line.expiryDate,
          qty: line.qty,
        );
      }

      await _outbox.enqueue(
        txn,
        opId: newId(),
        entityType: 'goods_receipt',
        entityId: receiptId,
        payload: {
          'supplierName': supplierName,
          'receivedAt': receivedAt.toIso8601String(),
          'lines': linePayloads,
        },
      );
    });

    return receiptId;
  }

  /// Corrects a count after someone has looked at the shelf (BR-3.2).
  ///
  /// Sends the **delta**, not the new total. The terminal counted against a figure the
  /// server may already disagree with — most likely because of the very sales that made the
  /// count wrong — and "set it to 40" would discard them. A delta composes; an absolute
  /// overwrites.
  Future<int> adjustStock({
    required LocalBatch batch,
    required String branchId,
    required int countedQty,
    required AdjustmentReason reason,
    String? note,
  }) async {
    final delta = countedQty - batch.qtyOnHand;
    if (delta == 0) {
      throw ArgumentError('the count matches; there is nothing to correct');
    }
    if (reason.requiresNote && (note == null || note.trim().isEmpty)) {
      throw ArgumentError('this reason requires a note');
    }

    final id = newId();
    final countedAt = DateTime.now().toUtc();

    await _db.db.transaction((txn) async {
      await txn.insert('stock_adjustment', {
        'id': id,
        'branch_id': branchId,
        'batch_id': batch.id,
        'product_id': batch.productId,
        'delta': delta,
        'reason': reason.wire,
        'note': note?.trim(),
        'previous_qty_on_hand': batch.qtyOnHand,
        'counted_at': countedAt.toIso8601String(),
        'synced': 0,
      });

      await txn.rawUpdate(
        'UPDATE stock_batch SET qty_on_hand = qty_on_hand + ? WHERE id = ?',
        [delta, batch.id],
      );

      await _outbox.enqueue(
        txn,
        opId: newId(),
        entityType: 'stock_adjustment',
        entityId: id,
        payload: {
          'batchId': batch.id,
          'productId': batch.productId,
          'delta': delta,
          'reason': reason.wire,
          'note': note?.trim(),
          'countedAt': countedAt.toIso8601String(),
          'previousQtyOnHand': batch.qtyOnHand,
        },
      );
    });

    return delta;
  }

  /// Batches at this branch that need attention: negative first, then soonest to expire.
  Future<List<LocalBatch>> batchesNeedingAttention(String branchId) =>
      _catalog.batchesForReconciliation(branchId);

  /// Builds the wire operation for a queued inventory entry.
  Operation toOperation(
    OutboxEntry entry, {
    required String tenantId,
    required String branchId,
    required String actorId,
    required String terminalId,
  }) {
    switch (entry.entityType) {
      case 'goods_receipt':
        return OperationGoodsReceipt(
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
          entityType: 'goods_receipt',
          payload: GoodsReceiptPayload.fromJson(entry.payload),
        );
      case 'stock_adjustment':
        return OperationStockAdjustment(
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
          entityType: 'stock_adjustment',
          payload: StockAdjustmentPayload.fromJson(entry.payload),
        );
      default:
        throw StateError('not an inventory entity type: ${entry.entityType}');
    }
  }
}
