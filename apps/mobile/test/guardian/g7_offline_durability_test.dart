import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/data/catalog_repository.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/data/outbox.dart';
import 'package:pharmaet_mobile/data/sale_repository.dart';

import '../support/test_db.dart';

/// G7 — OFFLINE RESILIENCE, device half (docs/05-qa §4; NFR-1.3, BR-4.1).
///
/// The invariant: a locally committed sale survives the app being killed and the device
/// being rebooted, and still syncs afterwards. Nothing about it depends on the network
/// having been reachable at any point.
///
/// These tests do the only thing that can actually prove that — they close the database,
/// throw the object away, and open it again from the same file, which is what a process
/// death looks like from the data's point of view.
void main() {
  late LocalDb db;
  late Directory dir;
  late Outbox outbox;
  late CatalogRepository catalog;
  late SaleRepository sales;

  const tenantId = '01930000-0000-7000-8000-000000000001';
  const branchId = '01930000-0000-7000-8000-000000000002';
  const cashierId = '01930000-0000-7000-8000-000000000003';
  const terminalId = '01930000-0000-7000-8000-000000000004';

  Future<void> wire() async {
    outbox = Outbox(db);
    catalog = CatalogRepository(db);
    sales = SaleRepository(db, outbox, catalog);
  }

  setUp(() async {
    final opened = await openTestDb();
    db = opened.db;
    dir = opened.dir;
    await wire();
  });

  tearDown(() async {
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// Simulates the app being force-stopped and reopened: the handle goes away, the file
  /// stays.
  Future<void> killAndRestart() async {
    await db.close();
    final reopened = await openTestDb(reuse: dir);
    db = reopened.db;
    await wire();
  }

  LocalProduct product({int priceSantim = 1500}) => LocalProduct(
        id: '01930000-0000-7000-8000-00000000000a',
        name: 'Paracetamol 500mg',
        unit: 'tablet',
        isControlled: false,
        priceSantim: priceSantim,
      );

  test('a committed sale survives the app being killed', () async {
    await sales.commitSale(
      lines: [CartLine(product: product(), qty: 2, batchId: null)],
      tenantId: tenantId,
      branchId: branchId,
      cashierId: cashierId,
      terminalId: terminalId,
    );

    expect(await sales.unsyncedCount(), 1);
    expect(await outbox.depth(), 1);

    await killAndRestart();

    // The whole promise, in two assertions: the receipt is still here, and the system still
    // knows it owes the server a sale.
    expect(await sales.unsyncedCount(), 1);
    expect(await outbox.depth(), 1);
  });

  test('three days of offline sales all survive a restart, in order', () async {
    for (var i = 0; i < 60; i++) {
      await sales.commitSale(
        lines: [CartLine(product: product(), qty: 1, batchId: null)],
        tenantId: tenantId,
        branchId: branchId,
        cashierId: cashierId,
        terminalId: terminalId,
      );
    }

    await killAndRestart();

    final pending = await outbox.pending(limit: 500);
    expect(pending.length, 60);

    // Ordering is by the monotonic counter, and the counter survived the restart too —
    // if it had reset, two operations would collide on terminal_seq and one sale would be
    // lost the moment they were pushed.
    final seqs = pending.map((e) => e.terminalSeq).toList();
    expect(seqs, List<int>.generate(60, (i) => i + 1));
  });

  test('the sequence counter never restarts, even across a kill mid-day',
      () async {
    await sales.commitSale(
      lines: [CartLine(product: product(), qty: 1, batchId: null)],
      tenantId: tenantId,
      branchId: branchId,
      cashierId: cashierId,
      terminalId: terminalId,
    );
    await killAndRestart();
    await sales.commitSale(
      lines: [CartLine(product: product(), qty: 1, batchId: null)],
      tenantId: tenantId,
      branchId: branchId,
      cashierId: cashierId,
      terminalId: terminalId,
    );

    final seqs = (await outbox.pending()).map((e) => e.terminalSeq).toList();
    expect(seqs, [1, 2]);
  });

  test('an unacknowledged operation is never dropped by a failed sync',
      () async {
    await sales.commitSale(
      lines: [CartLine(product: product(), qty: 3, batchId: null)],
      tenantId: tenantId,
      branchId: branchId,
      cashierId: cashierId,
      terminalId: terminalId,
    );

    final pending = await outbox.pending();
    // A network failure, five times over. The queue must be exactly as deep afterwards.
    for (var attempt = 0; attempt < 5; attempt++) {
      await outbox.recordFailure(pending, 'connection refused');
    }

    expect(await outbox.depth(), 1);
    await killAndRestart();
    expect(await outbox.depth(), 1);
  });

  test('a sale with no stock and no network still commits', () async {
    // There is no catalog, no batch, and nothing to check against. The sale still goes
    // through, because refusing it would stop the counter over a number the terminal
    // already knows can be wrong (BR-3.2, BR-4.1).
    final sale = await sales.commitSale(
      lines: [CartLine(product: product(), qty: 5, batchId: null)],
      tenantId: tenantId,
      branchId: branchId,
      cashierId: cashierId,
      terminalId: terminalId,
    );

    expect(sale.totalSantim, 7500);
    expect(await outbox.depth(), 1);
  });
}
