import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/data/catalog_repository.dart';
import 'package:pharmaet_mobile/data/inventory_repository.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
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
