import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/contracts/contracts.dart';
import 'package:pharmaet_mobile/data/catalog_repository.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/ui/dispense_screen.dart';
import 'package:pharmaet_mobile/ui/home_screen.dart';
import 'package:pharmaet_mobile/ui/kit.dart';
import 'package:pharmaet_mobile/ui/sell_screen.dart';
import 'package:pharmaet_mobile/ui/terminal.dart';

import '../support/terminal.dart';
import '../support/test_db.dart';

/// T3 — the counter (prototype screens 08–10; FR-4, FR-9, E-4.2, BR-2.3).
///
/// The rules that meet at the till, each enforced by what is or is not on screen: sync is
/// the system's job, not the cashier's; the offline ceiling withdraws management actions
/// without touching the sale; a controlled substance is refused until Phase 2; expired stock
/// is warned about, and only a manager may authorise it.
void main() {
  late LocalDb db;
  late Directory dir;

  setUp(() async {
    final opened = await openTestDb();
    db = opened.db;
    dir = opened.dir;
  });

  tearDown(() async {
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  LocalBatch expiredBatch(String productId) => LocalBatch(
      id: 'b1',
      productId: productId,
      lotNo: 'LOT-b1',
      expiryDate: '2026-01-31',
      qtyOnHand: 10);

  group('sync is the system\'s job, not the cashier\'s (FR-9)', () {
    // Found on a phone: every trigger was a screen change or a button, so a cashier who
    // never pressed "Sync now" kept the day's sales on the device.
    testWidgets('it tries again on an interval, untouched', (tester) async {
      final t = TestTerminal.build(db);
      // Something waiting: the timer pushes on its next tick.
      t.sync.pendingReported = 1;
      await pumpTerminalScreen(tester, t.terminal, const SellScreen());
      await t.terminal.start();
      final atStart = t.sync.calls;

      await tester.pump(Terminal.syncInterval);
      await tester.pump();

      expect(t.sync.calls, atStart + 1);
      t.terminal.dispose();
    });

    testWidgets(
        'with nothing queued it pulls every two minutes, not every tick',
        (tester) async {
      final t = TestTerminal.build(db);
      await pumpTerminalScreen(tester, t.terminal, const SellScreen());
      await t.terminal.start();
      await tester.pump();
      final atStart = t.sync.calls;

      // Three idle ticks inside the idle window: nothing to push, pull not yet due.
      for (var i = 0; i < 3; i++) {
        await tester.pump(Terminal.syncInterval);
      }
      expect(t.sync.calls, atStart);

      await tester.pump(Terminal.syncInterval);
      await tester.pump();
      expect(t.sync.calls, atStart + 1);
      t.terminal.dispose();
    });

    testWidgets('and the moment the app comes back to the foreground',
        (tester) async {
      final t = TestTerminal.build(db);
      await pumpTerminalScreen(tester, t.terminal, const SellScreen());
      await t.terminal.start();
      await tester.pump();
      final atStart = t.sync.calls;

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(t.sync.calls, atStart + 1);
      t.terminal.dispose();
    });
  });

  group('past the offline ceiling (BR-2.3)', () {
    testWidgets('Home says so, and selling is untouched', (tester) async {
      final t = TestTerminal.build(db,
          role: 'branch_manager',
          offlineValidUntil: DateTime.now().subtract(const Duration(days: 1)));
      t.addProduct('p1', 'Paracetamol');
      await pumpTerminalScreen(tester, t.terminal,
          HomeScreen(onSell: () {}, onStock: () {}, onReports: () {}));

      expect(find.textContaining('offline too long'), findsOneWidget);
      // Receiving stock is a management action; it is withdrawn, not greyed out.
      expect(find.text('Receive'), findsNothing);
      // NFR-1.2: whatever the clock says, the counter takes money.
      expect(find.text('Sell'), findsOneWidget);
    });
  });

  group('a controlled substance', () {
    testWidgets('is refused, and says why rather than failing quietly',
        (tester) async {
      final t = TestTerminal.build(db, role: 'owner');
      t.addProduct('p2', 'Diazepam', controlled: true);
      await pumpTerminalScreen(tester, t.terminal, const SellScreen());

      await tester.tap(find.text('Diazepam'));
      await tester.pump();

      expect(find.textContaining('switched off until EFDA'), findsOneWidget);
      expect(t.terminal.cart, isEmpty);
    });
  });

  group('controlled dispensing, once the switch is on (ADR-024)', () {
    testWidgets('opens the dispense screen instead of the cart',
        (tester) async {
      final t = TestTerminal.build(db, role: 'cashier');
      t.addProduct('p2', 'Diazepam', controlled: true);
      await t.terminal.controlled.rememberSwitch(true);
      await pumpTerminalScreen(tester, t.terminal, const SellScreen());

      await tester.tap(find.text('Diazepam'));
      await tester.pumpAndSettle();

      expect(find.byType(DispenseScreen), findsOneWidget);
      expect(find.text('Controlled dispense'), findsOneWidget);
      expect(t.terminal.cart, isEmpty);
    });

    testWidgets('there is no dispense button until every rule is met (BR-4.2)',
        (tester) async {
      final t = TestTerminal.build(db, role: 'cashier');
      t.addProduct('p2', 'Diazepam', controlled: true);
      await pumpTerminalScreen(tester, t.terminal,
          DispenseScreen(product: t.catalog.products_.single));

      final record = tester.widget<PButton>(find.byType(PButton));
      expect(record.label, 'Dispense & record to ledger');
      expect(record.onPressed, isNull);
      expect(find.textContaining('provisional until EFDA'), findsOneWidget);
    });
  });

  group('expired stock (E-4.2, ADR-020)', () {
    testWidgets(
        'warns instead of showing an empty shelf, and a manager may authorise',
        (tester) async {
      final t = TestTerminal.build(db, role: 'branch_manager');
      t.addProduct('p3', 'Amoxicillin');
      t.catalog.expired_['p3'] = expiredBatch('p3');
      await pumpTerminalScreen(tester, t.terminal, const SellScreen());

      await tester.tap(find.text('Amoxicillin'));
      await tester.pump();

      expect(find.text('This stock has expired'), findsOneWidget);
      expect(find.textContaining('LOT-b1'), findsOneWidget);
      expect(find.text('Authorise — dispense it'), findsOneWidget);
    });

    testWidgets('never to a cashier, who is told and can still sell',
        (tester) async {
      final t = TestTerminal.build(db, role: 'cashier');
      t.addProduct('p3', 'Amoxicillin');
      t.catalog.expired_['p3'] = expiredBatch('p3');
      await pumpTerminalScreen(tester, t.terminal, const SellScreen());

      await tester.tap(find.text('Amoxicillin'));
      await tester.pump();

      expect(find.text('This stock has expired'), findsOneWidget);
      expect(find.text('Authorise — dispense it'), findsNothing);
      expect(find.textContaining('cannot authorise'), findsOneWidget);

      await tester.tap(find.text('Continue'));
      await tester.pump();
      await tester.pump();
      // Unattributed, but sold: refusing would stop the pharmacy, not the box leaving.
      expect(t.terminal.cart.single.batchId, isNull);
    });

    testWidgets('says nothing at all when the stock is in date',
        (tester) async {
      final t = TestTerminal.build(db, role: 'branch_manager');
      t.addProduct('p3', 'Amoxicillin');
      t.catalog.fefo_['p3'] = const LocalBatch(
          id: 'b2',
          productId: 'p3',
          lotNo: 'LOT-b2',
          expiryDate: '2030-06-30',
          qtyOnHand: 10);
      await pumpTerminalScreen(tester, t.terminal, const SellScreen());

      await tester.tap(find.text('Amoxicillin'));
      await tester.pump();
      await tester.pump();

      expect(find.text('This stock has expired'), findsNothing);
      expect(find.textContaining('LOT-b2'), findsOneWidget);
    });
  });

  group('the cart (prototype screen 08)', () {
    testWidgets(
        'selling past zero is allowed, shown and flagged — never blocked',
        (tester) async {
      final t = TestTerminal.build(db);
      t.addProduct('p4', 'Cetirizine', price: 500);
      t.catalog.onHand_['p4'] = 0;
      await pumpTerminalScreen(tester, t.terminal, const SellScreen());

      await tester.tap(find.text('Cetirizine'));
      await tester.pump();
      await tester.pump();

      expect(
          find.textContaining('flags it for reconciliation'), findsOneWidget);
      final charge = tester.widget<PButton>(find.byType(PButton));
      expect(charge.onPressed, isNotNull);
      expect(charge.label, contains('ETB 5'));
    });

    // FR-11 — break-bulk. The unit is a tap on the line, never arithmetic at the counter.
    const strip = ProductPack(name: 'strip', size: 10, priceSantim: 3600);
    const box = ProductPack(name: 'box', size: 30, priceSantim: 10000);

    testWidgets('a product with packs offers each unit, with its own price',
        (tester) async {
      final t = TestTerminal.build(db);
      t.addProduct('p5', 'Amoxicillin', price: 400, packs: const [strip, box]);
      t.catalog.onHand_['p5'] = 500;
      await pumpTerminalScreen(tester, t.terminal, const SellScreen());

      await tester.tap(find.text('Amoxicillin'));
      await tester.pump();
      await tester.pump();

      expect(find.text('tablet · 4.00'), findsOneWidget);
      expect(find.text('strip · 36.00'), findsOneWidget);
      expect(find.text('box · 100.00'), findsOneWidget);
      // Added loose, as every line always was.
      expect(t.terminal.cart.single.pack, isNull);
      expect(t.terminal.cartTotal, 400);
    });

    testWidgets('tapping a pack charges the pack price and keeps the count',
        (tester) async {
      final t = TestTerminal.build(db);
      t.addProduct('p5', 'Amoxicillin', price: 400, packs: const [strip, box]);
      t.catalog.onHand_['p5'] = 500;
      await pumpTerminalScreen(tester, t.terminal, const SellScreen());

      await tester.tap(find.text('Amoxicillin'));
      await tester.pump();
      await tester.pump();
      t.terminal.setQty(0, 2);
      await tester.pump();

      await tester.tap(find.text('box · 100.00'));
      await tester.pump();

      final line = t.terminal.cart.single;
      expect(line.pack?.size, 30);
      expect(line.qty, 2);
      // Two boxes at the box price — not sixty tablets at the tablet price (24,000).
      expect(t.terminal.cartTotal, 20000);
      final charge = tester.widget<PButton>(find.byType(PButton).last);
      expect(charge.label, contains('ETB 200'));

      // And back to loose is one tap too.
      await tester.tap(find.text('tablet · 4.00'));
      await tester.pump();
      expect(t.terminal.cart.single.pack, isNull);
      expect(t.terminal.cartTotal, 800);
    });

    testWidgets('a box that outruns the shelf is flagged, in base units',
        (tester) async {
      final t = TestTerminal.build(db);
      t.addProduct('p5', 'Amoxicillin', price: 400, packs: const [box]);
      // Ten on the shelf: one loose is fine, one box of thirty is twenty short.
      t.catalog.onHand_['p5'] = 10;
      await pumpTerminalScreen(tester, t.terminal, const SellScreen());

      await tester.tap(find.text('Amoxicillin'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('flags it for reconciliation'), findsNothing);

      await tester.tap(find.text('box · 100.00'));
      await tester.pump();

      expect(
          find.textContaining('flags it for reconciliation'), findsOneWidget);
      // Flagged, never blocked (BR-3.2).
      final charge = tester.widget<PButton>(find.byType(PButton).last);
      expect(charge.onPressed, isNotNull);
    });

    testWidgets('a product with no packs shows no unit chips at all',
        (tester) async {
      final t = TestTerminal.build(db);
      t.addProduct('p1', 'Paracetamol', price: 500);
      t.catalog.onHand_['p1'] = 100;
      await pumpTerminalScreen(tester, t.terminal, const SellScreen());

      await tester.tap(find.text('Paracetamol'));
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('tablet · '), findsNothing);
    });

    testWidgets('an empty cart cannot be charged', (tester) async {
      final t = TestTerminal.build(db);
      t.addProduct('p1', 'Paracetamol');
      await pumpTerminalScreen(tester, t.terminal, const SellScreen());

      final charge = tester.widget<PButton>(find.byType(PButton));
      expect(charge.onPressed, isNull);
    });
  });
}
