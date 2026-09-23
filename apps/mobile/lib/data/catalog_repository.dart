import 'package:sqflite/sqflite.dart';

import '../contracts/contracts.dart';
import 'local_db.dart';

class LocalProduct {
  const LocalProduct({
    required this.id,
    required this.name,
    required this.unit,
    required this.isControlled,
    required this.priceSantim,
  });

  final String id;
  final String name;
  final String unit;
  final bool isControlled;
  final int priceSantim;
}

class LocalBatch {
  const LocalBatch({
    required this.id,
    required this.productId,
    required this.lotNo,
    required this.expiryDate,
    required this.qtyOnHand,
  });

  final String id;
  final String productId;
  final String lotNo;
  final String expiryDate;
  final int qtyOnHand;
}

/// Reference data on the device: the catalog and what stock we believe is on the shelf.
class CatalogRepository {
  CatalogRepository(this._db);

  final LocalDb _db;

  Future<List<LocalProduct>> products() async {
    final rows = await _db.db.query(
      'product',
      where: 'deleted = 0',
      orderBy: 'name ASC',
    );
    return rows
        .map((r) => LocalProduct(
              id: r['id'] as String,
              name: r['name'] as String,
              unit: r['unit'] as String,
              isControlled: (r['is_controlled'] as int) == 1,
              priceSantim: r['price_santim'] as int,
            ))
        .toList();
  }

  /// FEFO — first to expire, first out (AC-3.2).
  ///
  /// Expiry order, not receipt order: what actually costs a pharmacy money is stock dying on
  /// the shelf, and that happens precisely when the longest-dated box goes out first.
  ///
  /// Already-expired batches are excluded. Dispensing those needs an explicit authorised
  /// override (E-4.2), which is Phase 1 — until then the batch is simply not offered.
  ///
  /// A null result does NOT stop the sale. The terminal may hold stock the server has not
  /// told it about, or none at all, and refusing to sell would close the counter over a
  /// number we already know can be wrong (BR-3.2).
  Future<LocalBatch?> fefoBatch(String productId, String branchId) async {
    final today = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    final rows = await _db.db.query(
      'stock_batch',
      where:
          'product_id = ? AND branch_id = ? AND deleted = 0 AND expiry_date >= ?',
      whereArgs: [productId, branchId, today],
      orderBy: 'expiry_date ASC, qty_on_hand DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return LocalBatch(
      id: r['id'] as String,
      productId: r['product_id'] as String,
      lotNo: r['lot_no'] as String,
      expiryDate: r['expiry_date'] as String,
      qtyOnHand: r['qty_on_hand'] as int,
    );
  }

  Future<int> onHand(String productId, String branchId) async {
    final rows = await _db.db.rawQuery(
      'SELECT coalesce(sum(qty_on_hand), 0) AS n FROM stock_batch '
      'WHERE product_id = ? AND branch_id = ? AND deleted = 0',
      [productId, branchId],
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  /// Decrements local stock as a sale is committed, so the next FEFO read sees the truth
  /// this terminal knows. May go negative, deliberately (BR-3.2).
  Future<void> decrementLocal(
    DatabaseExecutor txn, {
    required String batchId,
    required int qty,
  }) async {
    await txn.rawUpdate(
      'UPDATE stock_batch SET qty_on_hand = qty_on_hand - ? WHERE id = ?',
      [qty, batchId],
    );
  }

  /// Credits a batch locally when stock arrives, keyed on the batch id the client minted.
  ///
  /// Idempotent by id: the server applies the same receipt against the same batch id, so a
  /// pulled correction converges with this rather than double-counting it.
  Future<void> upsertLocalBatch(
    DatabaseExecutor txn, {
    required String batchId,
    required String branchId,
    required String productId,
    required String lotNo,
    required String expiryDate,
    required int qty,
  }) async {
    final existing = await txn.query(
      'stock_batch',
      where: 'branch_id = ? AND product_id = ? AND lot_no = ? AND deleted = 0',
      whereArgs: [branchId, productId, lotNo],
      limit: 1,
    );

    if (existing.isNotEmpty) {
      await txn.rawUpdate(
        'UPDATE stock_batch SET qty_on_hand = qty_on_hand + ? WHERE id = ?',
        [qty, existing.first['id']],
      );
      return;
    }

    await txn.insert('stock_batch', {
      'id': batchId,
      'branch_id': branchId,
      'product_id': productId,
      'lot_no': lotNo,
      'expiry_date': expiryDate,
      'qty_on_hand': qty,
      // Zero until the server tells us otherwise: a locally minted batch has no server
      // sequence yet, and claiming one would make the next pull skip the real value.
      'change_seq': 0,
      'deleted': 0,
    });
  }

  /// Batches worth looking at: oversold first, then soonest to expire.
  ///
  /// The order is the priority order. A negative count means the shelf and the system
  /// disagree, and until somebody counts, every expiry decision resting on that number is
  /// guesswork.
  Future<List<LocalBatch>> batchesForReconciliation(String branchId) async {
    final rows = await _db.db.query(
      'stock_batch',
      where: 'branch_id = ? AND deleted = 0',
      whereArgs: [branchId],
      orderBy: 'qty_on_hand < 0 DESC, expiry_date ASC',
      limit: 100,
    );
    return rows
        .map((r) => LocalBatch(
              id: r['id'] as String,
              productId: r['product_id'] as String,
              lotNo: r['lot_no'] as String,
              expiryDate: r['expiry_date'] as String,
              qtyOnHand: r['qty_on_hand'] as int,
            ))
        .toList();
  }

  /// Applies a delta pull. Reference rows are overwritten wholesale because the terminal
  /// never authors them — there is nothing local to lose.
  Future<void> applyPull(PullResponse response) async {
    await _db.db.transaction((txn) async {
      for (final product in response.products) {
        await txn.insert(
          'product',
          {
            'id': product.id,
            'name': product.name,
            'unit': product.unit,
            'is_controlled': product.isControlled ? 1 : 0,
            'price_santim': product.currentPriceSantim,
            'change_seq': product.changeSeq,
            'deleted': product.deletedAt == null ? 0 : 1,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }

      for (final batch in response.stockBatches) {
        await txn.insert(
          'stock_batch',
          {
            'id': batch.id,
            'branch_id': batch.branchId,
            'product_id': batch.productId,
            'lot_no': batch.lotNo,
            'expiry_date': batch.expiryDate,
            'qty_on_hand': batch.qtyOnHand,
            'change_seq': batch.changeSeq,
            'deleted': batch.deletedAt == null ? 0 : 1,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }

      await txn.insert(
        'meta',
        {'key': 'pull_cursor', 'value': response.cursor.toString()},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.insert(
        'meta',
        {
          'key': 'last_pull_at',
          'value': DateTime.now().toUtc().toIso8601String()
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }
}
