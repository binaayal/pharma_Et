import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pharmaet_mobile/data/catalog_repository.dart';
import 'package:pharmaet_mobile/data/inventory_repository.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/data/medicine_catalogue.dart';
import 'package:pharmaet_mobile/ui/kit.dart';
import 'package:pharmaet_mobile/ui/receive_screen.dart';
import 'package:pharmaet_mobile/ui/reconcile_screen.dart';
import 'package:pharmaet_mobile/ui/stock_screen.dart';

import '../support/terminal.dart';
import '../support/test_db.dart';

/// T3 — inventory, goods receipt and counting (prototype screens 12–14; FR-3, FR-7,
/// BR-3.2).
///
/// Each guards a number entered at a counter that the system cannot afterwards tell apart
/// from a deliberate one. The guards live in what the form will and will not let through.
void main() {
  late LocalDb db;
  late Directory dir;
  late TestTerminal t;

  setUp(() async {
    final opened = await openTestDb();
    db = opened.db;
    dir = opened.dir;
    t = TestTerminal.build(db);
  });

  tearDown(() async {
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  PButton button(WidgetTester tester, String label) => tester
      .widgetList<PButton>(find.byType(PButton))
      .firstWhere((b) => b.label.contains(label));

  group('goods receipt (FR-7)', () {
    testWidgets('will not record a receipt with no supplier and no lines',
        (tester) async {
      t.addProduct('p1', 'Paracetamol');
      await pumpTerminalScreen(tester, t.terminal, const ReceiveScreen());

      // An empty receipt is indistinguishable from a mis-tap.
      expect(button(tester, 'Confirm receipt').onPressed, isNull);
    });

    testWidgets('says plainly that stock is sellable with or without a network',
        (tester) async {
      await pumpTerminalScreen(tester, t.terminal, const ReceiveScreen());
      expect(
          find.textContaining('available to sell immediately'), findsOneWidget);
    });

    testWidgets('offers no controlled substances', (tester) async {
      t.addProduct('p1', 'Paracetamol');
      t.addProduct('p2', 'Diazepam', controlled: true);
      await pumpTerminalScreen(tester, t.terminal, const ReceiveScreen());

      await tester.tap(find.textContaining('Add item'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<LocalProduct>));
      await tester.pumpAndSettle();

      // Controlled receipts are ledger events (ADR-004), which arrive with the compliance
      // phase. Offering one here would put a mutable count where an event belongs.
      expect(find.text('Paracetamol'), findsWidgets);
      expect(find.text('Diazepam'), findsNothing);
    });
  });

  group('counting a batch (BR-3.2)', () {
    const oversold = LocalBatch(
        id: 'b1',
        productId: 'p1',
        lotNo: 'LOT-1',
        expiryDate: '2030-01-01',
        qtyOnHand: -3);

    testWidgets('a write-off cannot go unexplained', (tester) async {
      await pumpTerminalScreen(
          tester,
          t.terminal,
          const Scaffold(
              body: CountSheet(batch: oversold, productName: 'Paracetamol')));

      await tester.enterText(find.byType(TextField).first, '0');
      await tester.pump();
      await tester.tap(find.byType(DropdownButtonFormField<AdjustmentReason>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Damaged').last);
      await tester.pumpAndSettle();

      // A recount may go unexplained; anything else may not — an unexplained write-off is
      // indistinguishable from a covered-up one, and the server refuses it regardless.
      expect(button(tester, 'Record count').onPressed, isNull);
      expect(find.textContaining('3 more than the system thought'),
          findsOneWidget);
    });
  });

  group('the inventory list (prototype screen 12)', () {
    testWidgets('an oversold line is flagged red for a count', (tester) async {
      t.catalog.stock_.add(const ProductStock(
        product: LocalProduct(
            id: 'p1',
            name: 'Cetirizine',
            unit: 'tablet',
            isControlled: false,
            priceSantim: 500),
        onHand: -4,
        batchCount: 1,
        nearestExpiry: null,
        oversold: true,
      ));
      await pumpTerminalScreen(tester, t.terminal, const StockScreen());
      await tester.pump();

      expect(find.textContaining('oversold'), findsOneWidget);
      expect(find.text('-4'), findsOneWidget);
    });
  });

  group('catalog management (FR-3, catalog.manage)', () {
    testWidgets('an owner can add a product; a cashier is not offered it',
        (tester) async {
      final owner = TestTerminal.build(db, role: 'owner');
      await pumpTerminalScreen(tester, owner.terminal, const StockScreen());
      expect(find.byTooltip('Add product'), findsOneWidget);

      final cashier = TestTerminal.build(db, role: 'cashier');
      await pumpTerminalScreen(tester, cashier.terminal, const StockScreen());
      // Not rendered at all: the server refuses it, and a greyed button only teaches people
      // to hunt for a way round.
      expect(find.byTooltip('Add product'), findsNothing);
    });

    testWidgets('a product needs a name, a unit and a price above zero',
        (tester) async {
      final owner = TestTerminal.build(db, role: 'owner');
      await pumpTerminalScreen(tester, owner.terminal, const StockScreen());
      await tester.tap(find.byTooltip('Add product'));
      await tester.pumpAndSettle();

      expect(button(tester, 'Add to catalog').onPressed, isNull);
      await tester.enterText(find.byType(TextField).at(0), 'Metformin 850mg');
      await tester.enterText(find.byType(TextField).at(2), '0');
      await tester.pump();
      expect(button(tester, 'Add to catalog').onPressed, isNull);
      await tester.enterText(find.byType(TextField).at(2), '19.50');
      await tester.pump();
      expect(button(tester, 'Add to catalog').onPressed, isNotNull);
    });
  });

  group('adding from the medicines list (FR-12)', () {
    final list = MedicineCatalogue('test', const [
      MedicineEntry(
          name: 'Amoxicillin 500mg capsule',
          unit: 'capsule',
          category: 'Penicillins'),
      MedicineEntry(name: 'Amoxicillin 250mg capsule', unit: 'capsule'),
      MedicineEntry(name: 'Paracetamol 500mg tablet', unit: 'tablet'),
    ]);

    setUp(() => MedicineCatalogue.debugSet(list));
    tearDown(() => MedicineCatalogue.debugSet(null));

    Future<TestTerminal> openForm(WidgetTester tester,
        {http.Client? api}) async {
      final owner = TestTerminal.build(db, role: 'owner', api: api);
      await pumpTerminalScreen(tester, owner.terminal, const StockScreen());
      await tester.tap(find.byTooltip('Add product'));
      await tester.pumpAndSettle();
      return owner;
    }

    String field(WidgetTester tester, int i) =>
        tester.widget<TextField>(find.byType(TextField).at(i)).controller!.text;

    testWidgets('a few letters and a tap fill the name and the unit',
        (tester) async {
      await openForm(tester);
      await tester.enterText(find.byType(TextField).at(0), 'amox 500');
      await tester.pump();

      expect(find.text('Amoxicillin 500mg capsule'), findsOneWidget);
      expect(find.text('Amoxicillin 250mg capsule'), findsNothing);
      await tester.tap(find.text('Amoxicillin 500mg capsule'));
      await tester.pump();

      expect(field(tester, 0), 'Amoxicillin 500mg capsule');
      expect(field(tester, 1), 'capsule');
      // The price is the owner's to set: the list has none, and the form will not save
      // without one.
      expect(field(tester, 2), isEmpty);
      expect(button(tester, 'Add to catalog').onPressed, isNull);
      // Picked: the suggestions step out of the way.
      expect(find.textContaining('Essential Medicines List'), findsNothing);
    });

    testWidgets('a medicine that is not on the list is typed in as before',
        (tester) async {
      await openForm(tester);
      await tester.enterText(
          find.byType(TextField).at(0), 'Shop own cough mix');
      await tester.enterText(find.byType(TextField).at(2), '45');
      await tester.pump();

      expect(find.textContaining('Essential Medicines List'), findsNothing);
      expect(button(tester, 'Add to catalog').onPressed, isNotNull);
    });

    testWidgets('what the pharmacy already sells is not offered again',
        (tester) async {
      final owner = TestTerminal.build(db, role: 'owner');
      owner.addProduct('p1', 'Paracetamol 500mg tablet');
      await pumpTerminalScreen(tester, owner.terminal, const StockScreen());
      await tester.tap(find.byTooltip('Add product'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(0), 'para');
      await tester.pump();
      expect(find.textContaining('Essential Medicines List'), findsNothing);
    });

    testWidgets('"add another" saves and clears for the next medicine',
        (tester) async {
      final posted = <Map<String, dynamic>>[];
      await openForm(tester, api: MockClient((request) async {
        if (request.method == 'POST' && request.url.path == '/products') {
          posted.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response('{"id":"x"}', 201);
        }
        return http.Response('{}', 503);
      }));

      await tester.enterText(find.byType(TextField).at(0), 'amox 500');
      await tester.pump();
      await tester.tap(find.text('Amoxicillin 500mg capsule'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).at(2), '4');
      await tester.pump();
      await tester.ensureVisible(find.text('Add, then add another'));
      await tester.tap(find.text('Add, then add another'));
      await tester.pumpAndSettle();

      expect(posted.single['name'], 'Amoxicillin 500mg capsule');
      expect(posted.single['unit'], 'capsule');
      // 4 birr, as integer santim (G4).
      expect(posted.single['priceSantim'], 400);
      // Nothing from the list sets this: "controlled" is a regulatory fact, not a name.
      expect(posted.single['isControlled'], isFalse);

      // Still open, empty, and saying how far along the owner is.
      expect(field(tester, 0), isEmpty);
      expect(field(tester, 2), isEmpty);
      expect(find.textContaining('1 added'), findsOneWidget);
    });
  });

  group('in Amharic (AC-10.1: "any core screen")', () {
    testWidgets('goods receipt', (tester) async {
      await pumpTerminalScreen(tester, t.terminal, const ReceiveScreen(),
          locale: 'am');
      expect(find.text('የዕቃ ርክክብ'), findsOneWidget);
      expect(find.text('Goods receipt'), findsNothing);
    });

    testWidgets('counting a batch', (tester) async {
      await pumpTerminalScreen(
          tester,
          t.terminal,
          const Scaffold(
              body: CountSheet(
                  batch: LocalBatch(
                      id: 'b1',
                      productId: 'p1',
                      lotNo: 'LOT-1',
                      expiryDate: '2030-01-01',
                      qtyOnHand: 5),
                  productName: 'Paracetamol')),
          locale: 'am');
      expect(find.textContaining('ሎት LOT-1'), findsOneWidget);
      expect(find.textContaining('system says'), findsNothing);
    });
  });
}
