import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/contracts/contracts.dart';
import 'package:pharmaet_mobile/data/catalog_repository.dart';
import 'package:pharmaet_mobile/data/inventory_repository.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/data/outbox.dart';
import 'package:pharmaet_mobile/data/sale_repository.dart';
import 'package:pharmaet_mobile/data/shift_repository.dart';
import 'package:pharmaet_mobile/sync/sync_client.dart';
import 'package:pharmaet_mobile/sync/sync_service.dart';
import 'package:pharmaet_mobile/ui/pos_screen.dart';

import '../support/pump.dart';
import '../support/test_db.dart';

/// T3 — the counter (docs/05-qa §3; FR-4, E-4.2, BR-2.3).
///
/// Four rules meet on this one screen, and each is enforced by what is or is not rendered —
/// which is only visible here. The matrix decides which controls exist at all; the offline
/// ceiling withdraws some of them without touching the sale; a controlled substance is
/// refused outright until Phase 2; and expired stock is warned about rather than hidden.
void main() {
  late LocalDb db;
  late Directory dir;
  late _StubCatalog catalog;
  late SaleRepository sales;
  late InventoryRepository inventory;
  late ShiftRepository shifts;
  late _StubSync syncService;

  void addProduct(String id, String name,
          {bool controlled = false, int price = 1500}) =>
      catalog.products_.add(LocalProduct(
        id: id,
        name: name,
        unit: 'tablet',
        isControlled: controlled,
        priceSantim: price,
      ));

  /// The only expired lot for [productId] — what `expiredFallbackBatch` would return.
  void addExpiredBatch(String id, String productId) =>
      catalog.expired_[productId] = LocalBatch(
        id: id,
        productId: productId,
        lotNo: 'LOT-$id',
        expiryDate: '2026-01-31',
        qtyOnHand: 10,
      );

  /// An in-date lot — what FEFO would select.
  void addGoodBatch(String id, String productId) =>
      catalog.fefo_[productId] = LocalBatch(
        id: id,
        productId: productId,
        lotNo: 'LOT-$id',
        expiryDate: '2030-06-30',
        qtyOnHand: 10,
      );

  setUp(() async {
    final opened = await openTestDb();
    db = opened.db;
    dir = opened.dir;
    // Everything the screen loads is stubbed. A widget test runs in a fake-async zone where
    // real file I/O never completes, so a DB-backed load would leave the screen on its
    // spinner forever — and the real SyncClient would spend its HTTP timeout per test, which
    // is what turned the first version of this file into a ten-minute run. The data layer is
    // covered at T1/T2; this tier is about what ends up on screen.
    final outbox = Outbox(db);
    catalog = _StubCatalog(db);
    sales = SaleRepository(db, outbox, catalog);
    inventory = InventoryRepository(db, outbox, catalog);
    shifts = _StubShifts(db, outbox);
    syncService = _StubSync(
      db: db,
      outbox: outbox,
      client: SyncClient(baseUrl: 'http://stub.invalid'),
      catalog: catalog,
      sales: sales,
      inventory: inventory,
    );
  });

  tearDown(() async {
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> open(WidgetTester tester,
          {required String role, DateTime? until}) =>
      pumpScreen(
        tester,
        PosScreen(
          session: sessionFor(role, offlineValidUntil: until),
          catalog: catalog,
          sales: sales,
          shifts: shifts,
          inventory: inventory,
          syncService: syncService,
          terminalId: '01930000-0000-7000-8000-000000000004',
          onSignOut: () {},
          onSessionRenewed: (_) async {},
        ),
      );

  group('what the matrix decides is on screen', () {
    testWidgets(
        'every counter role can reach the stock menu, including a cashier',
        (tester) async {
      // Surprising until you read the SRS FR-2 table, which grants `goods.receive` to a
      // cashier at branch reach — "Receive goods (FR-7) | — | ✓ | B | B". In a small pharmacy
      // the person at the counter is the person who signs for the wholesaler's van, and a
      // system that made them fetch the owner would be worked around within a week.
      //
      // Pinned because it looks like a mistake, and the next person to "fix" it should have
      // to change a test that explains why it is not. The denial worth having on this screen
      // is `expiry.override`, exercised below.
      //
      // By tooltip, not by icon: the same icon doubles as the empty-catalogue illustration,
      // so `byIcon` matches whether or not the control exists.
      for (final role in ['owner', 'branch_manager', 'cashier']) {
        await open(tester, role: role);
        expect(find.byTooltip('Stock'), findsOneWidget,
            reason: '$role should be able to receive stock');
      }
    });
  });

  group('past the offline ceiling (BR-2.3)', () {
    testWidgets('the terminal says so, and withdraws management actions',
        (tester) async {
      await open(
        tester,
        role: 'branch_manager',
        until: DateTime.now().subtract(const Duration(days: 1)),
      );

      // Said out loud rather than left as a silently missing button: the user holds the
      // capability, and a control that vanishes without explanation reads as a broken app.
      expect(find.textContaining('offline too long'), findsOneWidget);
      expect(find.byTooltip('Stock'), findsNothing);
    });

    testWidgets('but selling is untouched', (tester) async {
      addProduct('p1', 'Paracetamol');
      await open(
        tester,
        role: 'cashier',
        until: DateTime.now().subtract(const Duration(days: 30)),
      );

      // NFR-1.2. Whatever the clock says, the counter takes money — so the product list is
      // still there to tap.
      expect(find.text('Paracetamol'), findsOneWidget);
    });
  });

  group('sync is the system\'s job, not the cashier\'s (FR-9)', () {
    // Found on a real phone, not by a test: every trigger was a screen transition or a
    // button, so a cashier who never pressed "Sync now" kept the day's sales on the device
    // until the app happened to restart. FR-9 names the actor "system (background)".
    testWidgets('it tries again on an interval, untouched', (tester) async {
      await open(tester, role: 'cashier');
      final atOpen = syncService.calls;

      await tester.pump(PosScreen.syncInterval);
      await tester.pump();

      expect(syncService.calls, atOpen + 1);
    });

    testWidgets('a committed sale is pushed without anyone asking',
        (tester) async {
      addProduct('p1', 'Paracetamol', price: 150);
      await open(tester, role: 'cashier');
      final atOpen = syncService.calls;

      await tester.tap(find.text('Paracetamol'));
      await tester.pump();
      // The commit is a real SQLite transaction; let it complete outside fake async.
      await tester.runAsync(() async {
        await tester.tap(find.text('Take cash & commit'));
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      await tester.pump();

      expect(find.textContaining('Sale committed'), findsOneWidget);
      expect(syncService.calls, atOpen + 1);

      // And the confirmation gets out of the way of the next customer's sale.
      // Entrance animation, then the display timer, then the exit animation.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(find.textContaining('Sale committed'), findsNothing);
    });

    testWidgets('and the moment the app comes back to the foreground',
        (tester) async {
      await open(tester, role: 'cashier');
      final atOpen = syncService.calls;

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(syncService.calls, atOpen + 1);
    });
  });

  group('a controlled substance', () {
    testWidgets('is refused, and says why rather than failing quietly',
        (tester) async {
      addProduct('p2', 'Diazepam', controlled: true);
      await open(tester, role: 'owner');

      await tester.tap(find.text('Diazepam'));
      await tester.pump();

      // Selling one through the standard path would put an unauditable record in a system
      // whose ledger does not exist yet (ADR-015). Refusing and saying so is the honest act.
      expect(find.textContaining('compliance phase'), findsOneWidget);
    });
  });

  group('expired stock (E-4.2, ADR-020)', () {
    testWidgets('warns instead of showing an empty shelf', (tester) async {
      addProduct('p3', 'Amoxicillin');
      addExpiredBatch('b1', 'p3');
      await open(tester, role: 'branch_manager');

      await tester.tap(find.text('Amoxicillin'));
      await tester.pump();

      // Hiding it read as "there is no stock" rather than "the only stock here is expired",
      // which removed exactly what the person reaching for the box needed to know.
      expect(find.text('This stock has expired'), findsOneWidget);
      expect(find.textContaining('LOT-b1'), findsOneWidget);
    });

    testWidgets('offers the override to a manager', (tester) async {
      addProduct('p3', 'Amoxicillin');
      addExpiredBatch('b1', 'p3');
      await open(tester, role: 'branch_manager');

      await tester.tap(find.text('Amoxicillin'));
      await tester.pump();

      expect(find.text('Authorise — dispense it'), findsOneWidget);
    });

    testWidgets('and never to a cashier, who is still told and can still sell',
        (tester) async {
      addProduct('p3', 'Amoxicillin');
      addExpiredBatch('b1', 'p3');
      await open(tester, role: 'cashier');

      await tester.tap(find.text('Amoxicillin'));
      await tester.pump();

      // The warning is for everyone; the authority is not. A cashier sees no button, is told
      // who to ask, and the sale still completes unattributed rather than being blocked.
      expect(find.text('This stock has expired'), findsOneWidget);
      expect(find.text('Authorise — dispense it'), findsNothing);
      expect(find.textContaining('cannot authorise'), findsOneWidget);
    });

    testWidgets('says nothing at all when the stock is in date',
        (tester) async {
      addProduct('p3', 'Amoxicillin');
      addGoodBatch('b1', 'p3');
      await open(tester, role: 'branch_manager');

      await tester.tap(find.text('Amoxicillin'));
      await tester.pump();

      // A warning that fires on ordinary stock is one nobody reads.
      expect(find.text('This stock has expired'), findsNothing);
    });
  });
}

/// No file I/O: a widget test's fake-async zone never completes it.
class _StubCatalog extends CatalogRepository {
  _StubCatalog(super.db);

  final products_ = <LocalProduct>[];
  final fefo_ = <String, LocalBatch>{};
  final expired_ = <String, LocalBatch>{};

  @override
  Future<List<LocalProduct>> products() async => products_;

  @override
  Future<LocalBatch?> fefoBatch(String productId, String branchId) async =>
      fefo_[productId];

  @override
  Future<LocalBatch?> expiredFallbackBatch(
          String productId, String branchId) async =>
      expired_[productId];
}

class _StubShifts extends ShiftRepository {
  _StubShifts(super.db, super.outbox);

  @override
  Future<ActiveShift?> activeShift(String userId) async => null;
}

/// Never touches the network. The first version of this file used the real client against an
/// unroutable host and paid its connect timeout on every single test.
class _StubSync extends SyncService {
  _StubSync({
    required super.db,
    required super.outbox,
    required super.client,
    required super.catalog,
    required super.sales,
    required super.inventory,
  });

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

  int calls = 0;
}
