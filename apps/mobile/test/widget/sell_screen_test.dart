import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/data/catalog_repository.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
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
      await pumpTerminalScreen(tester, t.terminal, const SellScreen());
      await t.terminal.start();
      final atStart = t.sync.calls;

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

      expect(find.textContaining('compliance phase'), findsOneWidget);
      expect(t.terminal.cart, isEmpty);
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

    testWidgets('an empty cart cannot be charged', (tester) async {
      final t = TestTerminal.build(db);
      t.addProduct('p1', 'Paracetamol');
      await pumpTerminalScreen(tester, t.terminal, const SellScreen());

      final charge = tester.widget<PButton>(find.byType(PButton));
      expect(charge.onPressed, isNull);
    });
  });
}
