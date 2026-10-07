import '../contracts/contracts.dart';
import 'catalog_repository.dart';
import 'local_db.dart';

/// One product, with everything the insight reports need about it.
class ProductInsight {
  const ProductInsight({
    required this.product,
    required this.onHand,
    required this.unitsSold,
    required this.revenueSantim,
    required this.costOfSalesSantim,
    required this.daysSinceLastSale,
    required this.daysSinceFirstReceipt,
    required this.windowDays,
  });

  final LocalProduct product;

  /// Base units on the shelf now, across batches.
  final int onHand;

  /// Base units sold in the window.
  final int unitsSold;
  final int revenueSantim;

  /// What those units cost, **estimated** from what this phone has received the product
  /// at, or null when it has never received any and so has no cost to go on.
  final int? costOfSalesSantim;

  /// Null when it has never been sold on this phone.
  final int? daysSinceLastSale;

  /// Null when it has never been received on this phone.
  final int? daysSinceFirstReceipt;
  final int windowDays;

  /// Revenue less estimated cost. Null wherever the cost is.
  int? get profitSantim =>
      costOfSalesSantim == null ? null : revenueSantim - costOfSalesSantim!;

  /// How many days the shelf lasts at the window's rate of sale, rounded down. Null when
  /// nothing sold — there is no rate to divide by, and "forever" is not a number.
  int? get daysOfCover =>
      unitsSold <= 0 ? null : (onHand * windowDays) ~/ unitsSold;
}

/// A product worth buying more of, and how much.
class ReorderSuggestion {
  const ReorderSuggestion({
    required this.insight,
    required this.suggestedBaseQty,
    this.pack,
    this.packs = 0,
  });

  final ProductInsight insight;

  /// How many base units would bring the shelf up to [InsightsRepository.targetDays] of
  /// sales.
  final int suggestedBaseQty;

  /// The product's largest pack, when it has one: stock is ordered by the box.
  final ProductPack? pack;

  /// [suggestedBaseQty] in whole [pack]s, rounded **up** — nobody orders 0.4 of a box.
  final int packs;
}

/// A batch that could go back to its supplier for credit before it expires.
class ReturnCandidate {
  const ReturnCandidate({
    required this.productName,
    required this.unit,
    required this.lotNo,
    required this.expiryDate,
    required this.qty,
    required this.daysLeft,
    this.valueSantim,
  });

  final String productName;
  final String unit;
  final String lotNo;
  final String expiryDate;
  final int qty;

  /// Days until expiry; negative once it has passed.
  final int daysLeft;

  /// What it cost, estimated — the figure to ask the supplier for. Null without a cost.
  final int? valueSantim;
}

/// A supplier and what could be returned to them.
class SupplierReturns {
  const SupplierReturns({required this.supplier, required this.batches});

  /// As typed on the goods receipt, or null where this phone did not receive the batch
  /// and so does not know who supplied it.
  final String? supplier;
  final List<ReturnCandidate> batches;

  int get valueSantim =>
      batches.fold<int>(0, (sum, b) => sum + (b.valueSantim ?? 0));
}

/// Where the money is — reorder suggestions, profit, dead stock, returns (FR-7a, FR-8a,
/// FR-18's return list; ADR-036).
///
/// Computed **on the phone, from the phone's own records**, so it opens instantly and with
/// no network — which on a sleeping free-tier server is the difference between a report an
/// owner looks at and one they give up on.
///
/// That choice has a price, stated on the screen and here: these figures know what *this
/// phone* sold and received. For a shop with one phone that is everything. For a shop with
/// two, each sees its own half, and the consolidated answer needs the server. And a phone
/// that was reinstalled starts its history again.
///
/// Every figure is integer arithmetic. Cost is an **estimate** — the average of what this
/// phone has received the product at — and is labelled as one wherever it is shown.
class InsightsRepository {
  InsightsRepository(this._db);

  final LocalDb _db;

  /// How far back "selling" looks.
  static const windowDays = 30;

  /// Reorder when the shelf holds less than this many days of sales…
  static const reorderBelowDays = 14;

  /// …and suggest enough to bring it up to this many.
  static const targetDays = 30;

  /// Unsold for this long, with stock on the shelf, is dead stock.
  static const deadAfterDays = 60;

  /// Batches expiring within this many days are worth returning.
  static const returnWithinDays = 60;

  static String _day(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Every product, with its sales, stock and cost.
  Future<List<ProductInsight>> products(String branchId,
      {DateTime? now}) async {
    final at = (now ?? DateTime.now()).toUtc();
    final since =
        at.subtract(const Duration(days: windowDays)).toIso8601String();

    // One pass each, joined in Dart: four small aggregates are easier to get right, and
    // to test, than one query that fans sales out across receipts and doubles a total.
    final sold = {
      for (final r in await _db.db.rawQuery('''
        SELECT l.product_id AS id,
               SUM(l.qty * COALESCE(l.pack_size, 1)) AS units,
               SUM(l.line_total_santim)              AS revenue
          FROM sale_line l JOIN sale s ON s.id = l.sale_id
         WHERE s.branch_id = ? AND s.sold_at >= ?
         GROUP BY l.product_id
      ''', [branchId, since])) r['id']! as String: r,
    };
    final lastSale = {
      for (final r in await _db.db.rawQuery('''
        SELECT l.product_id AS id, MAX(s.sold_at) AS at
          FROM sale_line l JOIN sale s ON s.id = l.sale_id
         WHERE s.branch_id = ? GROUP BY l.product_id
      ''', [branchId])) r['id']! as String: DateTime.parse(r['at']! as String),
    };
    // Cost as two integers, never a ratio: total paid and total base units received.
    final received = {
      for (final r in await _db.db.rawQuery('''
        SELECT gl.product_id AS id,
               SUM(gl.qty * gl.cost_santim)            AS cost,
               SUM(gl.qty * COALESCE(gl.pack_size, 1)) AS units,
               MIN(g.received_at)                      AS first
          FROM goods_receipt_line gl
          JOIN goods_receipt g ON g.id = gl.goods_receipt_id
         WHERE g.branch_id = ? GROUP BY gl.product_id
      ''', [branchId])) r['id']! as String: r,
    };
    final stock = {
      for (final r in await _db.db.rawQuery('''
        SELECT product_id AS id, SUM(qty_on_hand) AS on_hand
          FROM stock_batch WHERE branch_id = ? AND deleted = 0
         GROUP BY product_id
      ''', [branchId])) r['id']! as String: (r['on_hand'] as int?) ?? 0,
    };

    final rows = await _db.db
        .query('product', where: 'deleted = 0 AND is_controlled = 0');
    return [
      for (final row in rows)
        () {
          final product = LocalProduct.fromRow(row);
          final s = sold[product.id];
          final r = received[product.id];
          final units = (s?['units'] as int?) ?? 0;
          final receivedUnits = (r?['units'] as int?) ?? 0;
          final receivedCost = (r?['cost'] as int?) ?? 0;
          final last = lastSale[product.id];
          final first = r?['first'] == null
              ? null
              : DateTime.parse(r!['first']! as String);
          return ProductInsight(
            product: product,
            onHand: stock[product.id] ?? 0,
            unitsSold: units,
            revenueSantim: (s?['revenue'] as int?) ?? 0,
            costOfSalesSantim: receivedUnits <= 0
                ? null
                : estimateCost(units, receivedCost, receivedUnits),
            daysSinceLastSale: last == null ? null : at.difference(last).inDays,
            daysSinceFirstReceipt:
                first == null ? null : at.difference(first).inDays,
            windowDays: windowDays,
          );
        }(),
    ];
  }

  /// What [units] cost, given [totalCost] was paid for [totalUnits]: `units × cost ÷
  /// totalUnits`, rounded to the nearest santim, in integers throughout (G4).
  static int estimateCost(int units, int totalCost, int totalUnits) =>
      (units * totalCost + totalUnits ~/ 2) ~/ totalUnits;

  /// What to buy, most urgent first.
  ///
  /// A product is suggested when it is selling and the shelf holds under
  /// [reorderBelowDays] of those sales — including when it has run out, which is the
  /// case that is already losing sales. A product that is not selling is never suggested,
  /// however little there is of it: buying more of what nobody buys is how dead stock
  /// starts.
  static List<ReorderSuggestion> reorder(List<ProductInsight> all) {
    final out = <ReorderSuggestion>[];
    for (final i in all) {
      final cover = i.daysOfCover;
      if (cover == null || cover >= reorderBelowDays) continue;
      // Enough for [targetDays] at the window's rate, less what is there. Rounded up.
      final target =
          (i.unitsSold * targetDays + i.windowDays - 1) ~/ i.windowDays;
      final need = target - (i.onHand < 0 ? 0 : i.onHand);
      if (need <= 0) continue;
      final pack = i.product.packs.isEmpty ? null : i.product.packs.last;
      out.add(ReorderSuggestion(
        insight: i,
        suggestedBaseQty: need,
        pack: pack,
        packs: pack == null ? 0 : (need + pack.size - 1) ~/ pack.size,
      ));
    }
    out.sort((a, b) {
      final byCover = a.insight.daysOfCover!.compareTo(b.insight.daysOfCover!);
      return byCover != 0
          ? byCover
          : b.insight.unitsSold.compareTo(a.insight.unitsSold);
    });
    return out;
  }

  /// What sold, by what it brought in, most first.
  static List<ProductInsight> bestSellers(List<ProductInsight> all) =>
      all.where((i) => i.unitsSold > 0).toList()
        ..sort((a, b) => b.revenueSantim.compareTo(a.revenueSantim));

  /// Stock that is sitting: on the shelf, and not sold for [deadAfterDays].
  ///
  /// Something received last week and not yet sold is not dead, it is new — so a product
  /// only counts once it has been on this phone's books for [deadAfterDays] too. Most
  /// money tied up first.
  static List<ProductInsight> deadStock(List<ProductInsight> all) =>
      all.where((i) {
        if (i.onHand <= 0) return false;
        final sinceSale = i.daysSinceLastSale;
        if (sinceSale != null) return sinceSale >= deadAfterDays;
        final sinceReceipt = i.daysSinceFirstReceipt;
        return sinceReceipt != null && sinceReceipt >= deadAfterDays;
      }).toList()
        ..sort((a, b) => (b.onHand * b.product.priceSantim)
            .compareTo(a.onHand * a.product.priceSantim));

  /// Batches near expiry, grouped by the supplier they came from, soonest first.
  ///
  /// The list an owner sends to a wholesaler to ask for credit instead of binning the
  /// stock. Batches already expired are included and marked: some suppliers still take
  /// them, and leaving them off would hide exactly the loss this list exists to recover.
  Future<List<SupplierReturns>> returns(String branchId,
      {DateTime? today}) async {
    final now = today ?? DateTime.now();
    final day = DateTime(now.year, now.month, now.day);
    final until = _day(day.add(const Duration(days: returnWithinDays)));

    // A batch's id is the id of the receipt line that created it (ADR-006), which is how
    // a batch finds its supplier with no extra bookkeeping. A batch received on another
    // phone has no line here, and so no supplier this phone can name.
    final rows = await _db.db.rawQuery('''
      SELECT p.name AS product, p.unit AS unit, b.lot_no AS lot, b.expiry_date AS expiry,
             b.qty_on_hand AS qty, g.supplier_name AS supplier,
             gl.cost_santim AS cost, COALESCE(gl.pack_size, 1) AS pack_size
        FROM stock_batch b
        JOIN product p ON p.id = b.product_id
        LEFT JOIN goods_receipt_line gl ON gl.id = b.id
        LEFT JOIN goods_receipt g ON g.id = gl.goods_receipt_id
       WHERE b.branch_id = ? AND b.deleted = 0 AND b.qty_on_hand > 0
         AND b.expiry_date <= ? AND p.is_controlled = 0
       ORDER BY b.expiry_date ASC, p.name COLLATE NOCASE
    ''', [branchId, until]);

    final bySupplier = <String?, List<ReturnCandidate>>{};
    for (final r in rows) {
      final expiry = r['expiry']! as String;
      final parts = expiry.substring(0, 10).split('-').map(int.parse).toList();
      final qty = r['qty']! as int;
      final cost = r['cost'] as int?;
      final packSize = (r['pack_size'] as int?) ?? 1;
      final supplier = (r['supplier'] as String?)?.trim();
      bySupplier
          .putIfAbsent(
              supplier == null || supplier.isEmpty ? null : supplier, () => [])
          .add(ReturnCandidate(
            productName: r['product']! as String,
            unit: r['unit']! as String,
            lotNo: r['lot']! as String,
            expiryDate: expiry,
            qty: qty,
            daysLeft:
                DateTime(parts[0], parts[1], parts[2]).difference(day).inDays,
            valueSantim:
                cost == null ? null : estimateCost(qty, cost, packSize),
          ));
    }

    final out = [
      for (final e in bySupplier.entries)
        SupplierReturns(supplier: e.key, batches: e.value),
    ]..sort((a, b) {
        // Named suppliers first, biggest claim first; the unknowns last.
        if ((a.supplier == null) != (b.supplier == null)) {
          return a.supplier == null ? 1 : -1;
        }
        return b.valueSantim.compareTo(a.valueSantim);
      });
    return out;
  }
}
