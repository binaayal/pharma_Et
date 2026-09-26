import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pharmaet_mobile/api/tenant_api.dart';
import 'package:pharmaet_mobile/contracts/contracts.dart';
import 'package:pharmaet_mobile/core/theme.dart';
import 'package:pharmaet_mobile/data/catalog_repository.dart';
import 'package:pharmaet_mobile/data/controlled_repository.dart';
import 'package:pharmaet_mobile/data/inventory_repository.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/data/outbox.dart';
import 'package:pharmaet_mobile/data/sale_repository.dart';
import 'package:pharmaet_mobile/data/shift_repository.dart';
import 'package:pharmaet_mobile/l10n/locale_store.dart';
import 'package:pharmaet_mobile/l10n/strings.dart';
import 'package:pharmaet_mobile/sync/sync_client.dart';
import 'package:pharmaet_mobile/sync/sync_service.dart';
import 'package:pharmaet_mobile/ui/terminal.dart';

import 'pump.dart';

/// A [Terminal] over stubbed repositories, for the T3 screen suites.
///
/// Everything a screen loads is stubbed: a widget test runs in a fake-async zone where real
/// file I/O never completes, so a DB-backed load would leave a screen on its spinner forever,
/// and a real HTTP client would spend its timeout per test. The data layer is covered at
/// T1/T2; this tier is about what ends up on screen.
class TestTerminal {
  TestTerminal._(this.terminal, this.catalog, this.shifts, this.inventory,
      this.sync, this.sales);

  final Terminal terminal;
  final StubCatalog catalog;
  final StubShifts shifts;
  final StubInventory inventory;
  final StubSync sync;
  final SaleRepository sales;

  static TestTerminal build(
    LocalDb db, {
    String role = 'cashier',
    DateTime? offlineValidUntil,
    http.Client? api,
  }) {
    final outbox = Outbox(db);
    final catalog = StubCatalog(db);
    final sales = SaleRepository(db, outbox, catalog);
    final shifts = StubShifts(db, outbox);
    final inventory = StubInventory(db, outbox, catalog);
    final client = SyncClient(baseUrl: 'http://stub.invalid');
    final sync = StubSync(
      db: db,
      outbox: outbox,
      client: client,
      catalog: catalog,
      sales: sales,
      inventory: inventory,
    );
    final terminal = Terminal(
      session: sessionFor(role, offlineValidUntil: offlineValidUntil),
      terminalId: '01930000-0000-7000-8000-000000000004',
      catalog: catalog,
      sales: sales,
      shifts: shifts,
      inventory: inventory,
      controlled: StubControlled(db, outbox),
      syncService: sync,
      api: TenantApi(
          baseUrl: 'http://stub.invalid',
          client: api ?? MockClient((_) async => http.Response('{}', 503))),
      client: client,
      onSessionRenewed: (_) async {},
      onSignOut: () {},
      branchName: 'Bole',
    );
    return TestTerminal._(terminal, catalog, shifts, inventory, sync, sales);
  }

  void addProduct(String id, String name,
          {bool controlled = false, int price = 1500}) =>
      catalog.products_.add(LocalProduct(
        id: id,
        name: name,
        unit: 'tablet',
        isControlled: controlled,
        priceSantim: price,
      ));
}

/// Pumps [screen] the way the app does: the terminal above the Navigator, so pushed
/// routes see it too.
Future<void> pumpTerminalScreen(
  WidgetTester tester,
  Terminal terminal,
  Widget screen, {
  String locale = 'en',
}) async {
  await terminal.refresh();
  await tester.pumpWidget(
    L10n(
      strings: Strings.of(locale),
      onChange: (_) {},
      child: MaterialApp(
        theme: buildTheme(),
        builder: (context, child) =>
            TerminalScope(terminal: terminal, child: child!),
        home: screen,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

class StubCatalog extends CatalogRepository {
  StubCatalog(super.db);

  final products_ = <LocalProduct>[];
  final fefo_ = <String, LocalBatch>{};
  final expired_ = <String, LocalBatch>{};
  final onHand_ = <String, int>{};
  final stock_ = <ProductStock>[];
  final batches_ = <String, List<LocalBatch>>{};

  @override
  Future<List<LocalProduct>> products() async => products_;

  @override
  Future<LocalBatch?> fefoBatch(String productId, String branchId) async =>
      fefo_[productId];

  @override
  Future<LocalBatch?> expiredFallbackBatch(
          String productId, String branchId) async =>
      expired_[productId];

  @override
  Future<int> onHand(String productId, String branchId) async =>
      onHand_[productId] ?? 100;

  @override
  Future<List<ProductStock>> stockByProduct(String branchId) async => stock_;

  @override
  Future<List<LocalBatch>> batchesFor(
          String productId, String branchId) async =>
      batches_[productId] ?? const [];

  @override
  Future<List<StockMovement>> movements(String productId, String branchId,
          {int limit = 12}) async =>
      const [];

  @override
  Future<({int expiring, int negative})> attention(String branchId,
          {int days = 60, DateTime? today}) async =>
      (expiring: 0, negative: 0);
}

class StubShifts extends ShiftRepository {
  StubShifts(super.db, super.outbox);

  ActiveShift? active;
  int? recordedCount;

  /// Float and takings deliberately different, so "expected" and "float" are two numbers
  /// a test can tell apart.
  ExpectedCash expected = const ExpectedCash(
    openingFloatSantim: 20000,
    cashTakenSantim: 15000,
    saleCount: 6,
    unsyncedSaleCount: 0,
  );

  @override
  Future<ActiveShift?> activeShift(String userId) async => active;

  @override
  Future<ExpectedCash> expectedCash(String shiftId) async => expected;

  @override
  Future<int> closeShiftWithCashUp({
    required ActiveShift shift,
    required int countedSantim,
    String? note,
  }) async {
    recordedCount = countedSantim;
    active = null;
    return countedSantim - expected.expectedSantim;
  }
}

class StubInventory extends InventoryRepository {
  StubInventory(super.db, super.outbox, super.catalog);
}

/// Never touches the network; counts how often the terminal asked it to sync.
class StubSync extends SyncService {
  StubSync({
    required super.db,
    required super.outbox,
    required super.client,
    required super.catalog,
    required super.sales,
    required super.inventory,
  });

  int calls = 0;

  @override
  Future<SyncStatus> status() async =>
      const SyncStatus(state: SyncState.idle, pending: 0, needsAttention: 0);

  @override
  Future<SyncStatus> sync({
    required String token,
    required String tenantId,
    required String branchId,
    required String actorId,
    required String terminalId,
    String refreshToken = '',
    Future<void> Function(LoginResponse renewed)? onRenewed,
  }) async {
    calls++;
    return const SyncStatus(
        state: SyncState.idle, pending: 0, needsAttention: 0);
  }
}

/// The switch in memory — a widget test's fake-async zone never completes real file I/O.
class StubControlled extends ControlledRepository {
  StubControlled(super.db, super.outbox);

  bool on = false;

  @override
  Future<bool> enabled() async => on;

  @override
  Future<void> rememberSwitch(bool value) async => on = value;
}
