import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/data/catalog_repository.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/data/outbox.dart';
import 'package:pharmaet_mobile/data/sale_repository.dart';

import '../support/latency.dart';
import '../support/test_db.dart';

/// G7 — NFR-3.2 REGRESSION GUARD (docs/02 §NFR-3.2, docs/05-qa §7).
///
/// **This is not the NFR-3.2 measurement.** It runs on the Dart VM on whatever machine CI
/// gave us, and that machine's storage has nothing to do with the cheap Android eMMC this
/// product ships to. The real figure is taken on hardware by
/// `integration_test/nfr3_local_latency_test.dart`, and docs/05 §7 requires exactly that.
///
/// What this file is for is catching the change that makes the operation *structurally*
/// slow — a network call on the sale path, a query without its index, an N+1 over cart
/// lines, a transaction that got split into four. Those regressions are visible on any
/// hardware, and catching them here means the device matrix is re-run to confirm a number
/// rather than to discover a defect.
///
/// It shares `measure` and `seedCatalogue` with the device test on purpose: two numbers
/// produced by subtly different code cannot be compared, and comparing them is the point.
void main() {
  late LocalDb db;
  late Directory dir;
  late CatalogRepository catalog;
  late SaleRepository sales;
  late List<String> productIds;

  const tenantId = '01930000-0000-7000-8000-000000000001';
  const branchId = '01930000-0000-7000-8000-000000000002';
  const cashierId = '01930000-0000-7000-8000-000000000003';
  const terminalId = '01930000-0000-7000-8000-000000000004';

  setUp(() async {
    final opened = await openTestDb();
    db = opened.db;
    dir = opened.dir;
    catalog = CatalogRepository(db);
    sales = SaleRepository(db, Outbox(db), catalog);
    productIds = await seedCatalogue(db, branchId: branchId);
  });

  tearDown(() async {
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  // CI ceilings, deliberately **below** the NFR-3.2 budget and set per operation.
  //
  // 100 ms is the requirement on a slow handset. A build machine that needed 100 ms for the
  // same work would mean the operation had become structurally wrong and the device would
  // have no chance, so holding CI to a tighter figure is what makes this a regression guard
  // rather than a restatement of the requirement that cannot fail until it is too late.
  //
  // One shared constant was wrong: these two operations do different work. Measured on a
  // developer machine, `add_item` sits at p95 ≈ 3 ms (one indexed SELECT) and `commit_sale`
  // at p95 ≈ 21 ms (a multi-statement transaction that fsyncs, because durability is the
  // entire point of G7). A single 25 ms ceiling would have been ~4x headroom for one and
  // ~1.2x for the other — which is not a tight guard, it is a flaky one, and docs/05 §3 is
  // explicit that a flaky guardian test is itself a blocking defect.
  const addItemCeilingMs = 15.0;
  const commitSaleCeilingMs = 50.0;

  test('adding an item is one indexed lookup, not a scan', () async {
    final sample = await measure('add_item', (i) async {
      await catalog.fefoBatch(
          productIds[i.abs() % productIds.length], branchId);
    });

    printOnFailure(sample.report);
    expect(sample.p95Ms, lessThan(addItemCeilingMs), reason: sample.report);
  });

  test('committing a sale is one transaction, and stays one', () async {
    final sample = await measure('commit_sale', (i) async {
      final index = i.abs() % productIds.length;
      final product = LocalProduct(
        id: productIds[index],
        name: 'Product $index',
        unit: 'tablet',
        isControlled: false,
        priceSantim: 1000 + index,
      );
      final batch = await catalog.fefoBatch(product.id, branchId);
      await sales.commitSale(
        lines: [CartLine(product: product, qty: 1, batchId: batch?.id)],
        tenantId: tenantId,
        branchId: branchId,
        cashierId: cashierId,
        terminalId: terminalId,
      );
    });

    printOnFailure(sample.report);
    expect(sample.p95Ms, lessThan(commitSaleCeilingMs), reason: sample.report);
  });

  test('a five-line sale does not cost five times a one-line sale', () async {
    // The N+1 guard. A basket is the normal case at a counter, and the cheapest way to lose
    // NFR-3.2 is to open a transaction per line. Measuring the ratio rather than an absolute
    // keeps this meaningful on a fast CI machine and a slow one alike.
    LocalProduct productAt(int index) => LocalProduct(
          id: productIds[index % productIds.length],
          name: 'Product $index',
          unit: 'tablet',
          isControlled: false,
          priceSantim: 1000 + index,
        );

    final one = await measure('sale_1_line', (i) async {
      await sales.commitSale(
        lines: [CartLine(product: productAt(i.abs()), qty: 1, batchId: null)],
        tenantId: tenantId,
        branchId: branchId,
        cashierId: cashierId,
        terminalId: terminalId,
      );
    }, iterations: 50);

    final five = await measure('sale_5_lines', (i) async {
      await sales.commitSale(
        lines: [
          for (var line = 0; line < 5; line++)
            CartLine(
                product: productAt(i.abs() * 5 + line), qty: 1, batchId: null),
        ],
        tenantId: tenantId,
        branchId: branchId,
        cashierId: cashierId,
        terminalId: terminalId,
      );
    }, iterations: 50);

    final ratio = five.p95Ms / one.p95Ms;
    printOnFailure(
        '${one.report}\n${five.report}\nratio=${ratio.toStringAsFixed(2)}');

    // Five lines in one transaction should cost well under five one-line sales, because the
    // per-transaction overhead is paid once. Three is loose enough not to flake and tight
    // enough that a per-line transaction (which would land at or above five) fails.
    expect(ratio, lessThan(3.0),
        reason:
            'a 5-line sale cost ${ratio.toStringAsFixed(2)}x a 1-line sale — '
            'that shape suggests a transaction per line');
  });
}
