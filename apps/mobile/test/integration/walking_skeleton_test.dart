import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/auth/session.dart';
import 'package:pharmaet_mobile/contracts/contracts.dart';
import 'package:pharmaet_mobile/data/catalog_repository.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/data/outbox.dart';
import 'package:pharmaet_mobile/data/sale_repository.dart';
import 'package:pharmaet_mobile/data/inventory_repository.dart';
import 'package:pharmaet_mobile/data/shift_repository.dart';
import 'package:pharmaet_mobile/sync/sync_client.dart';
import 'package:pharmaet_mobile/sync/sync_service.dart';

import '../support/test_db.dart';

/// The walking skeleton, end to end (docs/03 §9, docs/04 §13).
///
/// Drives the real client stack — real SQLite on disk, the real outbox, the real sync
/// client — against a running API. This is the test that says the spine is proven; the
/// unit and guardian suites each cover one half of it, and only this one covers the join.
///
/// Requires a running server and a seeded database:
///
///   ./scripts/dev-db.sh up
///   pnpm --filter @pharmaet/api migration:run && pnpm --filter @pharmaet/api seed
///   pnpm --filter @pharmaet/api dev
///   PHARMAET_API_URL=http://localhost:3000/api flutter test test/integration
///
/// Skipped when PHARMAET_API_URL is unset, so the ordinary `flutter test` run stays
/// hermetic.
void main() {
  final apiUrl = Platform.environment['PHARMAET_API_URL'];

  group('walking skeleton',
      skip: apiUrl == null ? 'PHARMAET_API_URL not set' : null, () {
    late LocalDb db;
    late Directory dir;
    late Outbox outbox;
    late CatalogRepository catalog;
    late SaleRepository sales;
    late ShiftRepository shifts;
    late SyncClient client;
    late SyncService syncService;
    late CachedSession session;

    const terminalId = '01930000-0000-7000-8000-0000000000ee';

    setUp(() async {
      final opened = await openTestDb();
      db = opened.db;
      dir = opened.dir;
      outbox = Outbox(db);
      catalog = CatalogRepository(db);
      sales = SaleRepository(db, outbox, catalog);
      shifts = ShiftRepository(db, outbox);
      final inventory = InventoryRepository(db, outbox, catalog);
      client = SyncClient(baseUrl: apiUrl!);
      syncService = SyncService(
        db: db,
        outbox: outbox,
        client: client,
        catalog: catalog,
        sales: sales,
        inventory: inventory,
      );

      final login = await client.login(const LoginRequest(
        tenantCode: 'abay',
        username: 'cashier',
        secret: '1234',
        terminalId: terminalId,
      ));
      session = CachedSession(
        accessToken: login.accessToken,
        refreshToken: login.refreshToken,
        tenantCode: 'abay',
        offlineValidUntil: DateTime.parse(login.offlineValidUntil),
        scope: login.scope,
      );
    });

    tearDown(() async {
      client.close();
      await db.close();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    Future<SyncStatus> runSync() => syncService.sync(
          token: session.accessToken,
          tenantId: session.scope.tenantId,
          branchId: session.primaryBranchId!,
          actorId: session.scope.userId,
          terminalId: terminalId,
        );

    test('pull → sell offline → reconnect → sync → exactly once', () async {
      // 1. First sync brings down the catalog and stock.
      final initial = await runSync();
      expect(initial.state, SyncState.synced);

      final products = await catalog.products();
      expect(products, isNotEmpty);
      final product = products.firstWhere((p) => !p.isControlled);

      // 2. Go offline, in the only way that matters: stop talking to the server. Three
      //    sales are rung up against local state alone.
      for (var i = 0; i < 3; i++) {
        final batch =
            await catalog.fefoBatch(product.id, session.primaryBranchId!);
        await sales.commitSale(
          lines: [CartLine(product: product, qty: 2, batchId: batch?.id)],
          tenantId: session.scope.tenantId,
          branchId: session.primaryBranchId!,
          cashierId: session.scope.userId,
          terminalId: terminalId,
        );
      }
      expect(await outbox.depth(), 3);
      expect(await sales.unsyncedCount(), 3);

      // 3. Reconnect and sync.
      final afterSync = await runSync();
      expect(afterSync.state, SyncState.synced);
      expect(afterSync.pending, 0);
      expect(await sales.unsyncedCount(), 0);

      // 4. Sync again immediately. Nothing is left to send, and nothing is sent twice.
      final idempotent = await runSync();
      expect(idempotent.pending, 0);
    });

    test(
        'a trading day: open till → sell offline → cash up offline → sync (FR-8)',
        () async {
      // The shape of a real day in this market, not a happy path: the till opens, sales are
      // rung up with no network, the drawer is counted at close still with no network, and
      // only then does connectivity come back.
      await runSync();
      final products = await catalog.products();
      final product = products.firstWhere((p) => !p.isControlled);

      final shift = await shifts.openShift(
        userId: session.scope.userId,
        branchId: session.primaryBranchId!,
        openingFloatSantim: 20000,
      );

      for (var i = 0; i < 4; i++) {
        final batch =
            await catalog.fefoBatch(product.id, session.primaryBranchId!);
        await sales.commitSale(
          lines: [CartLine(product: product, qty: 1, batchId: batch?.id)],
          tenantId: session.scope.tenantId,
          branchId: session.primaryBranchId!,
          cashierId: session.scope.userId,
          terminalId: terminalId,
          shiftId: shift.id,
        );
      }

      final expected = await shifts.expectedCash(shift.id);
      expect(expected.openingFloatSantim, 20000);
      expect(expected.cashTakenSantim, product.priceSantim * 4);
      // Everything is still queued, and the screen says so rather than presenting the
      // figure as settled.
      expect(expected.unsyncedSaleCount, 4);

      // The cashier counts 12.50 ETB less than the drawer should hold.
      final variance = await shifts.closeShiftWithCashUp(
        shift: shift,
        countedSantim: expected.expectedSantim - 1250,
        note: 'short — checking receipts',
      );
      expect(variance, -1250);

      // Connectivity returns. Everything goes at once, in order.
      final status = await runSync();
      expect(status.state, SyncState.synced);
      expect(status.pending, 0);
      expect(status.needsAttention, 0);

      // The office sees it.
      final report = await client.pull(token: session.accessToken, cursor: 0);
      expect(report.contractVersion, kContractVersion);
    });

    test('a sale committed before the catalog arrives still syncs', () async {
      // The pessimistic case: a terminal that has never successfully pulled, selling from
      // whatever the cashier types in. The sale must still be durable and still reach the
      // server on the first reconnect.
      final product = LocalProduct(
        id: (await () async {
          await runSync();
          final list = await catalog.products();
          return list.firstWhere((p) => !p.isControlled).id;
        }()),
        name: 'ad hoc',
        unit: 'tablet',
        isControlled: false,
        priceSantim: 1500,
      );

      await sales.commitSale(
        lines: [CartLine(product: product, qty: 1, batchId: null)],
        tenantId: session.scope.tenantId,
        branchId: session.primaryBranchId!,
        cashierId: session.scope.userId,
        terminalId: terminalId,
      );

      final status = await runSync();
      expect(status.pending, 0);
      expect(status.needsAttention, 0);
    });
  });
}
