import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../contracts/contracts.dart';
import 'customer_repository.dart';
import 'supplier_repository.dart';
import 'local_db.dart';

class LocalProduct {
  const LocalProduct({
    required this.id,
    required this.name,
    required this.unit,
    required this.isControlled,
    required this.priceSantim,
    this.packs = const [],
    this.barcodes = const [],
    this.wholesalePriceSantim,
  });

  final String id;
  final String name;

  /// The base unit — what stock is counted in, and what [priceSantim] is the price of.
  final String unit;
  final bool isControlled;
  final int priceSantim;

  /// The packs this product is also received and sold in, smallest first (FR-11). Empty
  /// for a product that only ever leaves the shelf one base unit at a time.
  final List<ProductPack> packs;

  /// The barcodes that identify this product, canonical (FR-13) — what a scan is
  /// compared with. Empty for a product that has never been linked to one.
  final List<String> barcodes;

  /// What one base unit sells for to a wholesale customer (FR-19), or null when the
  /// product has only the one price.
  final int? wholesalePriceSantim;

  /// Whether anything about this product is priced differently for a wholesale customer:
  /// the base unit, or any of its packs.
  bool get hasWholesalePrice =>
      wholesalePriceSantim != null ||
      packs.any((p) => p.wholesalePriceSantim != null);

  /// Builds a product from a `product` row.
  factory LocalProduct.fromRow(Map<String, Object?> r) => LocalProduct(
        id: r['id'] as String,
        name: r['name'] as String,
        unit: r['unit'] as String,
        isControlled: (r['is_controlled'] as int) == 1,
        priceSantim: r['price_santim'] as int,
        packs: decodePacks(r['packs_json'] as String?),
        barcodes: decodeBarcodes(r['barcodes_json'] as String?),
        wholesalePriceSantim: r['wholesale_price_santim'] as int?,
      );
}

/// Reads the barcodes stored on a product row. Never throws, for the reason [decodePacks]
/// does not: a product whose barcodes cannot be read is still found by name.
List<String> decodeBarcodes(String? json) {
  if (json == null || json.isEmpty) return const [];
  try {
    return (jsonDecode(json) as List<dynamic>).whereType<String>().toList();
  } catch (_) {
    return const [];
  }
}

/// Reads the packs stored on a product row. Never throws: a product whose pack list cannot
/// be read is still a product that can be sold by the base unit, and refusing to list it
/// would take a medicine off the counter over a display convenience.
List<ProductPack> decodePacks(String? json) {
  if (json == null || json.isEmpty) return const [];
  try {
    final packs = (jsonDecode(json) as List<dynamic>)
        .map((e) => ProductPack.fromJson(e as Map<String, dynamic>))
        .where((p) => p.size >= 2 && p.priceSantim >= 0)
        .toList()
      ..sort((a, b) => a.size.compareTo(b.size));
    return packs;
  } catch (_) {
    return const [];
  }
}

/// `2 box + 14` — a base-unit count the way someone counting a shelf says it, using the
/// product's largest pack. Just the number when there are no packs or it does not fill one.
///
/// Display only. Nothing is ever computed from this string, and the count it was built
/// from stays an integer of base units (docs/04 §3).
String describeQuantity(int baseQty, LocalProduct product) {
  if (product.packs.isEmpty || baseQty <= 0) return '$baseQty';
  final pack = product.packs.last;
  final whole = baseQty ~/ pack.size;
  if (whole == 0) return '$baseQty';
  final loose = baseQty % pack.size;
  return loose == 0 ? '$whole ${pack.name}' : '$whole ${pack.name} + $loose';
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
    return rows.map(LocalProduct.fromRow).toList();
  }

  /// FEFO — first to expire, first out (AC-3.2).
  ///
  /// Expiry order, not receipt order: what actually costs a pharmacy money is stock dying on
  /// the shelf, and that happens precisely when the longest-dated box goes out first.
  ///
  /// Already-expired batches are excluded **from selection**, but no longer hidden: if the
  /// only stock is expired, [expiredFallbackBatch] finds it so the counter can be warned and
  /// an authorised person can override (E-4.2, ADR-020). Hiding it read to the user as "there
  /// is no stock" rather than "the only stock here is expired", which removed exactly the
  /// information they needed while they reached for the box.
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

  /// The soonest-expiring **expired** batch for this product, or null if there is none.
  ///
  /// Only consulted when [fefoBatch] found nothing, so the ordinary path is untouched: a
  /// pharmacy with good stock never sees this and never sees a warning.
  Future<LocalBatch?> expiredFallbackBatch(
      String productId, String branchId) async {
    final today = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    final rows = await _db.db.query(
      'stock_batch',
      where:
          'product_id = ? AND branch_id = ? AND deleted = 0 AND expiry_date < ? AND qty_on_hand > 0',
      whereArgs: [productId, branchId, today],
      // Most-recently expired first: of a bad set of options it is the least bad, and it is
      // the box a pharmacist would reach for if they were choosing deliberately.
      orderBy: 'expiry_date DESC',
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

  /// Every batch of one product at a branch, first-to-expire first — the FEFO order the
  /// counter will dispense in (prototype screen 13).
  Future<List<LocalBatch>> batchesFor(String productId, String branchId) async {
    final rows = await _db.db.query(
      'stock_batch',
      where: 'product_id = ? AND branch_id = ? AND deleted = 0',
      whereArgs: [productId, branchId],
      orderBy: 'expiry_date ASC',
    );
    return rows.map(_batch).toList();
  }

  /// Stock per product at a branch: on hand, batch count and nearest expiry among the
  /// batches that still hold stock (prototype screen 12).
  Future<List<ProductStock>> stockByProduct(String branchId) async {
    final rows = await _db.db.rawQuery('''
      SELECT p.id, p.name, p.unit, p.is_controlled, p.price_santim, p.packs_json,
             p.barcodes_json, p.wholesale_price_santim,
             COALESCE(SUM(b.qty_on_hand), 0)                        AS on_hand,
             COUNT(b.id)                                             AS batches,
             MIN(CASE WHEN b.qty_on_hand > 0 THEN b.expiry_date END) AS nearest,
             MIN(b.qty_on_hand)                                      AS lowest
        FROM product p
        LEFT JOIN stock_batch b
               ON b.product_id = p.id AND b.branch_id = ? AND b.deleted = 0
       WHERE p.deleted = 0
       GROUP BY p.id
       ORDER BY p.name COLLATE NOCASE
    ''', [branchId]);
    return rows
        .map((r) => ProductStock(
              product: LocalProduct.fromRow(r),
              onHand: (r['on_hand'] as int?) ?? 0,
              batchCount: (r['batches'] as int?) ?? 0,
              nearestExpiry: r['nearest'] as String?,
              oversold: ((r['lowest'] as int?) ?? 0) < 0,
            ))
        .toList();
  }

  /// What Home's "Needs attention" counts: batches expiring within [days] that still hold
  /// stock, and batches driven negative by an oversell (BR-3.2, BR-3.4).
  Future<({int expiring, int negative})> attention(String branchId,
      {int days = 60, DateTime? today}) async {
    final now = today ?? DateTime.now();
    String iso(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final rows = await _db.db.rawQuery('''
      SELECT
        SUM(CASE WHEN qty_on_hand > 0 AND expiry_date >= ? AND expiry_date <= ? THEN 1 ELSE 0 END) AS expiring,
        SUM(CASE WHEN qty_on_hand < 0 THEN 1 ELSE 0 END) AS negative
        FROM stock_batch WHERE branch_id = ? AND deleted = 0
    ''', [iso(now), iso(now.add(Duration(days: days))), branchId]);
    return (
      expiring: (rows.first['expiring'] as int?) ?? 0,
      negative: (rows.first['negative'] as int?) ?? 0,
    );
  }

  /// What moved one product's stock here, newest first: sales, receipts and counts made on
  /// this device (prototype screen 13 — "an auditable movement trail").
  ///
  /// Every delta is in base units, so a box sold shows as the thirty that left the shelf
  /// rather than as one (FR-11).
  Future<List<StockMovement>> movements(String productId, String branchId,
      {int limit = 12}) async {
    final rows = await _db.db.rawQuery('''
      SELECT 'sale' AS kind, s.sold_at AS at,
             -l.qty * COALESCE(l.pack_size, 1) AS delta, s.id AS ref, NULL AS detail
        FROM sale_line l JOIN sale s ON s.id = l.sale_id
       WHERE l.product_id = ? AND s.branch_id = ?
      UNION ALL
      SELECT 'receipt', g.received_at, gl.qty * COALESCE(gl.pack_size, 1), g.id,
             g.supplier_name
        FROM goods_receipt_line gl JOIN goods_receipt g ON g.id = gl.goods_receipt_id
       WHERE gl.product_id = ? AND g.branch_id = ?
      UNION ALL
      SELECT 'count', a.counted_at, a.delta, a.id, a.reason
        FROM stock_adjustment a
       WHERE a.product_id = ? AND a.branch_id = ?
      ORDER BY at DESC LIMIT ?
    ''',
        [productId, branchId, productId, branchId, productId, branchId, limit]);
    return rows
        .map((r) => StockMovement(
              kind: r['kind'] as String,
              at: DateTime.parse(r['at'] as String),
              delta: r['delta'] as int,
              reference: r['ref'] as String,
              detail: r['detail'] as String?,
            ))
        .toList();
  }

  LocalBatch _batch(Map<String, Object?> r) => LocalBatch(
        id: r['id'] as String,
        productId: r['product_id'] as String,
        lotNo: r['lot_no'] as String,
        expiryDate: r['expiry_date'] as String,
        qtyOnHand: r['qty_on_hand'] as int,
      );

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
            // Null from a server that predates contract 1.5.0, which reads back as "no
            // packs" — the same thing it means.
            'packs_json': product.packs == null
                ? null
                : jsonEncode(product.packs!.map((p) => p.toJson()).toList()),
            'barcodes_json':
                product.barcodes == null ? null : jsonEncode(product.barcodes),
            'wholesale_price_santim': product.wholesalePriceSantim,
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

      // Credit customers and what the server says each owes (FR-16). In the same
      // transaction as the cursor: a balance and the point it is correct as of move
      // together or not at all.
      await CustomerRepository.applyPulled(txn, response.customers ?? const []);
      // Suppliers and what the server says each is owed (FR-18), likewise.
      await SupplierRepository.applyPulled(txn, response.suppliers ?? const []);

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

/// One row of the inventory list.
class ProductStock {
  const ProductStock({
    required this.product,
    required this.onHand,
    required this.batchCount,
    required this.nearestExpiry,
    required this.oversold,
  });
  final LocalProduct product;
  final int onHand;
  final int batchCount;

  /// ISO calendar date of the first batch to expire that still holds stock.
  final String? nearestExpiry;

  /// Some batch of this product is below zero and needs a count (BR-3.2).
  final bool oversold;
}

/// One line of a product's movement trail.
class StockMovement {
  const StockMovement({
    required this.kind,
    required this.at,
    required this.delta,
    required this.reference,
    this.detail,
  });

  /// `sale`, `receipt` or `count`.
  final String kind;
  final DateTime at;
  final int delta;
  final String reference;

  /// The supplier for a receipt, the reason for a count.
  final String? detail;
}
