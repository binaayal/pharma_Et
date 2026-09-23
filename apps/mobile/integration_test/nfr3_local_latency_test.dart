import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pharmaet_mobile/data/catalog_repository.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/data/outbox.dart';
import 'package:pharmaet_mobile/data/sale_repository.dart';

import '../test/support/latency.dart';

/// NFR-3.2 ON REAL HARDWARE (docs/05-qa §7, docs/02 §NFR-3.2).
///
/// > core-loop actions (add item, commit sale) complete against local SQLite in **< 100 ms**,
/// > independent of network — this is the offline-first payoff and is non-negotiable for
/// > counter UX.
///
/// The CI guard for this runs on the Dart VM on a build machine, which tells us the *shape*
/// of the work has not regressed — one transaction, no network — and nothing about what a
/// cashier experiences. NFR-3.2 is a **device** figure: the market runs cheap Android
/// hardware with slow eMMC storage, and an fsync on that hardware is not the fsync a CI
/// runner performs. docs/05 §7 says so explicitly, and this file is what it asks for.
///
/// Run it with `scripts/device-matrix.sh`, or directly:
///
///     cd apps/mobile && flutter test integration_test/nfr3_local_latency_test.dart -d <id>
///
/// It prints one `NFR3 ` line per operation. Those lines are the device matrix's rows.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const tenantId = '01930000-0000-7000-8000-000000000001';
  const branchId = '01930000-0000-7000-8000-000000000002';
  const cashierId = '01930000-0000-7000-8000-000000000003';
  const terminalId = '01930000-0000-7000-8000-000000000004';

  late LocalDb db;
  late Directory dir;
  late CatalogRepository catalog;
  late SaleRepository sales;
  late List<String> productIds;

  setUpAll(() async {
    // The app's own documents directory on the device — the real filesystem the real
    // database lives on. A tmpfs would measure the wrong storage and flatter the result.
    final docs = await getApplicationDocumentsDirectory();
    dir = Directory('${docs.path}/nfr3_bench')..createSync(recursive: true);
    final file = File('${dir.path}/pharmaet.db');
    if (file.existsSync()) file.deleteSync();

    db = await LocalDb.open(directory: dir.path);
    catalog = CatalogRepository(db);
    sales = SaleRepository(db, Outbox(db), catalog);
    productIds = await seedCatalogue(db, branchId: branchId);
  });

  tearDownAll(() async {
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('device identity', () async {
    // Printed so a result can never be attributed to the wrong handset. A device matrix of
    // numbers with no devices attached to them is a table, not evidence.
    final info = Platform.operatingSystem;
    final version = Platform.operatingSystemVersion;
    // ignore: avoid_print
    print('NFR3 device  os=$info  version=$version');
  });

  testWidgets('add item: FEFO batch selection (NFR-3.2)', (tester) async {
    // What the counter does between a tap on a product and the line appearing in the cart.
    final sample = await measure('add_item', (i) async {
      await catalog.fefoBatch(
          productIds[i.abs() % productIds.length], branchId);
    });

    // ignore: avoid_print
    print('NFR3 ${sample.report}');
    expect(sample.p95Ms, lessThan(100),
        reason:
            'NFR-3.2: adding an item must stay under 100 ms on this device');
  });

  testWidgets('commit sale: local transaction + outbox enqueue (NFR-3.2)',
      (tester) async {
    // The expensive one, and the one that must not be slow: it writes the sale, its lines,
    // the stock decrement and the outbox row in a single transaction, and it is what the
    // cashier waits on with a customer in front of them.
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

    // ignore: avoid_print
    print('NFR3 ${sample.report}');
    expect(sample.p95Ms, lessThan(100),
        reason:
            'NFR-3.2: committing a sale must stay under 100 ms on this device');
  });

  testWidgets(
      'commit sale stays fast with a day of sales already on the device',
      (tester) async {
    // A terminal that has been offline since Monday is not an edge case in this market; it
    // is the design. A budget that only holds against an empty database would be met on the
    // bench and missed in the shop, which is the failure mode docs/05 §7 is guarding.
    final sample = await measure('commit_sale_loaded', (i) async {
      final index = i.abs() % productIds.length;
      final product = LocalProduct(
        id: productIds[index],
        name: 'Product $index',
        unit: 'tablet',
        isControlled: false,
        priceSantim: 1000 + index,
      );
      await sales.commitSale(
        lines: [CartLine(product: product, qty: 1, batchId: null)],
        tenantId: tenantId,
        branchId: branchId,
        cashierId: cashierId,
        terminalId: terminalId,
      );
    }, iterations: 200);

    // ignore: avoid_print
    print('NFR3 ${sample.report}');
    expect(sample.p95Ms, lessThan(100),
        reason:
            'NFR-3.2 must hold with a backlog on the device, not only on an empty one');
  });
}
