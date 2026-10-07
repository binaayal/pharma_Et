import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/contracts/contracts.dart';
import 'package:pharmaet_mobile/data/catalog_repository.dart';
import 'package:pharmaet_mobile/data/insights_repository.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/ui/insights_screen.dart';
import 'package:pharmaet_mobile/ui/kit.dart';

import '../support/terminal.dart';
import '../support/test_db.dart';

/// FR-7a, FR-8a — what the owner is told about their stock.
///
/// The arithmetic is held by `g4_insights_test.dart`. This is the wording and the honesty:
/// profit that is an estimate is called one, products with no known cost are said to be
/// left out rather than counted as pure profit, and every tab says these are this phone's
/// figures.
void main() {
  late LocalDb db;
  late Directory dir;

  setUp(() async {
    final opened = await openTestDb();
    db = opened.db;
    dir = opened.dir;
  });

  tearDown(() async {
    debugShareInsight = null;
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  const box = ProductPack(name: 'box', size: 30, priceSantim: 10000);

  ProductInsight insight(
    String name, {
    int onHand = 0,
    int sold = 0,
    int revenue = 0,
    int? cost,
    int? lastSale,
    int? firstReceipt,
    List<ProductPack> packs = const [],
    int price = 400,
  }) =>
      ProductInsight(
        product: LocalProduct(
            id: name,
            name: name,
            unit: 'capsule',
            isControlled: false,
            priceSantim: price,
            packs: packs),
        onHand: onHand,
        unitsSold: sold,
        revenueSantim: revenue,
        costOfSalesSantim: cost,
        daysSinceLastSale: lastSale,
        daysSinceFirstReceipt: firstReceipt,
        windowDays: 30,
      );

  Future<TestTerminal> open(WidgetTester tester,
      {List<ProductInsight> products = const [],
      List<SupplierReturns> returns = const [],
      String locale = 'en'}) async {
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final t = TestTerminal.build(db, role: 'owner');
    t.insights.all.addAll(products);
    t.insights.returnGroups.addAll(returns);
    await pumpTerminalScreen(tester, t.terminal, const InsightsScreen(),
        locale: locale);
    await tester.pumpAndSettle();
    return t;
  }

  List<String> titles(WidgetTester tester) =>
      tester.widgetList<PRow>(find.byType(PRow)).map((r) => r.title).toList();

  group('what to buy', () {
    testWidgets('says what is left, how long it lasts, and how many boxes',
        (tester) async {
      await open(tester, products: [
        insight('Amoxicillin 500mg', onHand: 10, sold: 290, packs: const [box]),
        insight('Slow mover', onHand: 500, sold: 3),
      ]);

      expect(titles(tester), ['Amoxicillin 500mg']);
      expect(find.text('10 capsule left — about 1 days. Sold 290 in 30 days.'),
          findsOneWidget);
      expect(find.text('10 box'), findsOneWidget);
    });

    testWidgets('with nothing running out, says so', (tester) async {
      await open(tester, products: [insight('Plenty', onHand: 900, sold: 30)]);
      expect(find.text('Nothing that is selling is about to run out.'),
          findsOneWidget);
    });

    testWidgets('the list can be sent to whoever does the buying',
        (tester) async {
      String? shared;
      debugShareInsight = (text) async => shared = text;
      await open(tester, products: [
        insight('Amoxicillin 500mg', onHand: 10, sold: 290, packs: const [box]),
        insight('Paracetamol', onHand: 0, sold: 60),
      ]);

      await tester.tap(find.text('Share this buying list'));
      await tester.pump();

      expect(shared, contains('Bole — Buy'));
      expect(shared, contains('• Paracetamol: 60 capsule'));
      expect(shared, contains('• Amoxicillin 500mg: 10 box'));
    });
  });

  group('what is earning', () {
    Future<void> earning(WidgetTester tester, List<ProductInsight> p) async {
      await open(tester, products: p);
      await tester.tap(find.text('Earning'));
      await tester.pump();
    }

    testWidgets('totals what was sold and the profit on it, called an estimate',
        (tester) async {
      await earning(tester, [
        insight('Amoxicillin', sold: 65, revenue: 22000, cost: 19500),
        insight('Paracetamol', sold: 10, revenue: 5000, cost: 3000),
      ]);

      final tiles =
          tester.widgetList<PTile>(find.byType(PTile)).map((t) => t.value);
      expect(tiles, ['270', '45']);
      expect(find.text('Profit, estimated'), findsOneWidget);
      expect(find.textContaining('Profit is an estimate'), findsOneWidget);
      // Ordered by what it brought in.
      expect(titles(tester), ['Amoxicillin', 'Paracetamol']);
      expect(find.text('65 capsule · profit about 25.00'), findsOneWidget);
    });

    testWidgets(
        'a product with no known cost is left out of profit, and said to be',
        (tester) async {
      await earning(tester, [
        insight('Costed', sold: 10, revenue: 5000, cost: 3000),
        // Sold, never received on this phone: revenue is not profit.
        insight('Uncosted', sold: 10, revenue: 9000),
      ]);

      final tiles = tester
          .widgetList<PTile>(find.byType(PTile))
          .map((t) => t.value)
          .toList();
      expect(tiles.first, '140');
      // 20.00, not 110.00.
      expect(tiles.last, '20');
      expect(find.text('10 capsule · cost not known'), findsOneWidget);
      expect(
          find.textContaining('left out of the profit above'), findsOneWidget);
    });

    testWidgets('with no cost for anything, shows no profit figure at all',
        (tester) async {
      await earning(tester, [insight('Uncosted', sold: 10, revenue: 9000)]);
      final tiles = tester
          .widgetList<PTile>(find.byType(PTile))
          .map((t) => t.value)
          .toList();
      expect(tiles.last, '—');
    });

    testWidgets('a product sold at a loss is shown as one', (tester) async {
      await earning(
          tester, [insight('Loss', sold: 10, revenue: 3000, cost: 5000)]);
      expect(find.text('10 capsule · profit about -20.00'), findsOneWidget);
    });
  });

  group('what is sitting', () {
    testWidgets('lists dead stock with what is tied up in it', (tester) async {
      await open(tester, products: [
        insight('Old stock',
            onHand: 74, lastSale: 90, packs: const [box], price: 400),
        insight('Never moved', onHand: 10, firstReceipt: 80, price: 500),
        insight('Fresh', onHand: 50, firstReceipt: 5),
        insight('Selling', onHand: 50, lastSale: 2),
      ]);
      await tester.tap(find.text('Sitting'));
      await tester.pump();

      expect(titles(tester), ['Old stock', 'Never moved']);
      expect(find.text('Not sold for 90 days'), findsOneWidget);
      expect(find.text('Never sold on this phone'), findsOneWidget);
      // Counted the way the shelf is counted.
      expect(find.text('2 box + 14'), findsOneWidget);
      // 74 × 4.00 + 10 × 5.00.
      expect(tester.widgetList<PTile>(find.byType(PTile)).first.value, '346');
    });
  });

  group('what to send back', () {
    const epss = SupplierReturns(supplier: 'EPSS', batches: [
      ReturnCandidate(
          productName: 'Paracetamol',
          unit: 'tablet',
          lotNo: 'P1',
          expiryDate: '2026-11-01',
          qty: 100,
          daysLeft: 20,
          valueSantim: 30000),
      ReturnCandidate(
          productName: 'Amoxicillin',
          unit: 'capsule',
          lotNo: 'A9',
          expiryDate: '2026-10-01',
          qty: 30,
          daysLeft: -6,
          valueSantim: 9000),
    ]);
    const unknown = SupplierReturns(supplier: null, batches: [
      ReturnCandidate(
          productName: 'ORS',
          unit: 'sachet',
          lotNo: 'X',
          expiryDate: '2026-10-20',
          qty: 40,
          daysLeft: 8),
    ]);

    testWidgets('groups by supplier, and marks what has already expired',
        (tester) async {
      await open(tester, returns: [epss, unknown]);
      await tester.tap(find.text('Return'));
      await tester.pump();

      expect(find.text('EPSS'), findsOneWidget);
      expect(find.textContaining('20 days left'), findsOneWidget);
      expect(find.textContaining('expired 6 days ago'), findsOneWidget);
      // Not guessed at, and nothing to send to nobody.
      expect(find.text('SUPPLIER NOT KNOWN ON THIS PHONE'), findsOneWidget);
      expect(find.text('Share the list for EPSS'), findsOneWidget);
      expect(find.textContaining('Share the list for'), findsOneWidget);
    });

    testWidgets(
        'one supplier\'s list can be sent to them, with lots and a total',
        (tester) async {
      String? shared;
      debugShareInsight = (text) async => shared = text;
      await open(tester, returns: [epss]);
      await tester.tap(find.text('Return'));
      await tester.pump();
      await tester.tap(find.text('Share the list for EPSS'));
      await tester.pump();

      expect(shared, contains('Bole — stock to return to EPSS'));
      expect(
          shared,
          contains(
              '• Paracetamol — Lot P1, exp 2026-11-01: 100 tablet (300.00)'));
      expect(shared, contains('Total at cost: 390.00 ETB'));
    });
  });

  testWidgets('every tab says whose figures these are', (tester) async {
    await open(tester);
    for (final tab in ['Buy', 'Earning', 'Sitting', 'Return']) {
      await tester.tap(find.text(tab));
      await tester.pump();
      expect(find.textContaining('Another phone in the shop has its own'),
          findsOneWidget,
          reason: tab);
    }
  });

  testWidgets('in Amharic (AC-10.1)', (tester) async {
    await open(tester, locale: 'am');
    expect(find.text('ገንዘቡ የት እንዳለ'), findsOneWidget);
    expect(find.text('Where the money is'), findsNothing);
  });
}
