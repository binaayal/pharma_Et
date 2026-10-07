import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/data/catalog_repository.dart';
import 'package:pharmaet_mobile/data/inventory_repository.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/data/shift_repository.dart';
import 'package:pharmaet_mobile/data/supplier_repository.dart';
import 'package:pharmaet_mobile/ui/cash_up_screen.dart';
import 'package:pharmaet_mobile/ui/kit.dart';
import 'package:pharmaet_mobile/ui/receive_screen.dart';
import 'package:pharmaet_mobile/ui/settings_screen.dart';
import 'package:pharmaet_mobile/ui/suppliers_screen.dart';

import '../support/terminal.dart';
import '../support/test_db.dart';

/// FR-18 — suppliers and what is owed to them, as the person holding the phone meets it.
///
/// The arithmetic is held by the guardian suites on both sides. This is what the screens
/// show and stop: a delivery marked "not paid" that leaves a nonsense figure owing, money
/// taken out of a till without anyone choosing that, and a cashier offered a button to pay
/// money out of the business.
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

  const epss = LocalSupplier(
      id: 's1', name: 'EPSS', phone: '0911 00 00 00', balanceSantim: 45000);
  const addis =
      LocalSupplier(id: 's2', name: 'Addis Pharma', balanceSantim: 120000);
  const ahead = LocalSupplier(id: 's3', name: 'Kenema', balanceSantim: -5000);

  List<String> tiles(WidgetTester tester) =>
      tester.widgetList<PTile>(find.byType(PTile)).map((t) => t.value).toList();

  PButton button(WidgetTester tester, String label) =>
      tester.widget<PButton>(find.widgetWithText(PButton, label));

  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 3600);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  ActiveShift till() => ActiveShift(
      id: 'shift-1',
      userId: 'u',
      branchId: 'b',
      openedAt: DateTime.utc(2026, 10, 7, 6),
      openingFloatSantim: 20000);

  group('the list', () {
    testWidgets('leads with the total owed, and who is owed most',
        (tester) async {
      tall(tester);
      final t = TestTerminal.build(db, role: 'owner');
      t.suppliers.all.addAll(const [epss, addis, ahead]);
      await pumpTerminalScreen(tester, t.terminal, const SuppliersScreen());
      await tester.pump();

      // 450.00 + 1,200.00. The 50.00 Kenema holds does not make it 1,600.00.
      expect(tiles(tester), ['1,650', '2']);
      final names = tester
          .widgetList<PRow>(find.byType(PRow))
          .map((r) => r.title)
          .toList();
      expect(names, ['Addis Pharma', 'EPSS', 'Kenema']);
      expect(find.text('paid ahead'), findsOneWidget);
    });

    testWidgets('empty, says that suppliers add themselves from deliveries',
        (tester) async {
      tall(tester);
      final t = TestTerminal.build(db, role: 'owner');
      await pumpTerminalScreen(tester, t.terminal, const SuppliersScreen());
      await tester.pump();
      expect(find.textContaining('added by themselves'), findsOneWidget);
    });

    testWidgets('is reached from Settings by anyone who receives goods',
        (tester) async {
      tall(tester);
      final t = TestTerminal.build(db, role: 'cashier');
      await pumpTerminalScreen(
          tester, t.terminal, const Scaffold(body: SettingsScreen()));
      expect(find.text('Suppliers'), findsOneWidget);
    });

    testWidgets('a second supplier with the same name is not opened',
        (tester) async {
      tall(tester);
      final t = TestTerminal.build(db, role: 'owner');
      t.suppliers.all.add(epss);
      await pumpTerminalScreen(tester, t.terminal, const SuppliersScreen());
      await tester.pump();
      await tester.tap(find.byTooltip('New supplier'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'epss');
      await tester.pump();
      await tester.tap(find.widgetWithText(PButton, 'Save supplier'));
      await tester.pumpAndSettle();

      expect(find.textContaining('already a supplier'), findsOneWidget);
      expect(t.suppliers.all.length, 1);
    });
  });

  group('paying a supplier', () {
    Future<TestTerminal> atSupplier(WidgetTester tester,
        {bool tillOpen = true, String role = 'owner'}) async {
      tall(tester);
      final t = TestTerminal.build(db, role: role);
      t.suppliers.all.add(epss);
      if (tillOpen) t.shifts.active = till();
      await pumpTerminalScreen(
          tester, t.terminal, const SupplierScreen(supplierId: 's1'));
      await tester.pump();
      return t;
    }

    Future<void> openSheet(WidgetTester tester, String amount) async {
      await tester.tap(find.text('Pay this supplier'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, amount);
      await tester.pump();
    }

    testWidgets('a cashier sees what is owed, and is not offered the button',
        (tester) async {
      await atSupplier(tester, role: 'cashier');
      expect(tiles(tester).first, '450.00');
      expect(find.text('Pay this supplier'), findsNothing);
    });

    testWidgets(
        'with a till open, nothing is recorded until someone says where the money came from',
        (tester) async {
      await atSupplier(tester);
      await openSheet(tester, '200');

      // No default that takes cash out of a drawer.
      expect(button(tester, 'Record payment').onPressed, isNull);
      expect(find.text('You will still owe'), findsOneWidget);
      expect(find.text('250.00'), findsOneWidget);
    });

    testWidgets(
        'from the till: tied to that till, and says the cash-up will know',
        (tester) async {
      final t = await atSupplier(tester);
      await openSheet(tester, '200');
      await tester.tap(find.text('Cash from the open till'));
      await tester.pump();

      expect(find.textContaining('leaves the drawer'), findsOneWidget);
      await tester.tap(find.widgetWithText(PButton, 'Record payment'));
      await tester.pumpAndSettle();

      final payment = t.suppliers.payments.single;
      // 200 birr, as integer santim (G4).
      expect(payment.amountSantim, 20000);
      expect(payment.method, 'cash');
      expect(payment.shiftId, 'shift-1');
      // And the screen behind now shows what is left.
      expect(tiles(tester).first, '250.00');
    });

    testWidgets('cash that did not come from the till touches no till',
        (tester) async {
      final t = await atSupplier(tester);
      await openSheet(tester, '200');
      await tester.tap(find.text('Cash, not from the till'));
      await tester.pump();
      expect(find.textContaining('leaves the drawer'), findsNothing);
      await tester.tap(find.widgetWithText(PButton, 'Record payment'));
      await tester.pumpAndSettle();

      expect(t.suppliers.payments.single.method, 'cash');
      expect(t.suppliers.payments.single.shiftId, isNull);
    });

    testWidgets('by bank is recorded as such, with its reference',
        (tester) async {
      final t = await atSupplier(tester);
      await openSheet(tester, '450');
      await tester.tap(find.text('Bank, cheque or Telebirr'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).last, 'CHQ 00123');
      await tester.tap(find.widgetWithText(PButton, 'Record payment'));
      await tester.pumpAndSettle();

      final payment = t.suppliers.payments.single;
      expect(payment.method, 'other_recorded');
      expect(payment.shiftId, isNull);
      expect(payment.note, 'CHQ 00123');
    });

    testWidgets('with no till open, the till is not offered at all',
        (tester) async {
      final t = await atSupplier(tester, tillOpen: false);
      await openSheet(tester, '200');

      expect(find.text('Cash from the open till'), findsNothing);
      await tester.tap(find.widgetWithText(PButton, 'Record payment'));
      await tester.pumpAndSettle();
      expect(t.suppliers.payments.single.shiftId, isNull);
    });

    testWidgets('more than is owed is accepted, and shown as paid ahead',
        (tester) async {
      await atSupplier(tester, tillOpen: false);
      await openSheet(tester, '500');
      expect(find.text('You will be ahead by'), findsOneWidget);
      expect(find.text('50.00'), findsOneWidget);
      expect(button(tester, 'Record payment').onPressed, isNotNull);
    });

    testWidgets('the history says what each delivery cost and left owing',
        (tester) async {
      tall(tester);
      final t = TestTerminal.build(db, role: 'owner');
      t.suppliers.all.add(epss);
      t.suppliers.entries['s1'] = [
        PayableEntry(
            at: DateTime.utc(2026, 10, 7, 9),
            amountSantim: 5000,
            isPayment: true,
            synced: true,
            method: 'cash',
            fromTill: true),
        PayableEntry(
            at: DateTime.utc(2026, 10, 6, 9),
            amountSantim: 20000,
            isPayment: false,
            synced: false,
            costSantim: 45000),
      ];
      await pumpTerminalScreen(
          tester, t.terminal, const SupplierScreen(supplierId: 's1'));
      await tester.pump();

      expect(find.text('Paid from the till'), findsOneWidget);
      expect(find.text('Delivery, part paid'), findsOneWidget);
      expect(find.textContaining('Total cost 450.00'), findsOneWidget);
      expect(find.textContaining('not yet synced'), findsOneWidget);
    });
  });

  group('receiving a delivery', () {
    const product = LocalProduct(
        id: 'p1',
        name: 'Paracetamol',
        unit: 'tablet',
        isControlled: false,
        priceSantim: 500);
    // Ten at 45.00: a delivery that cost 450.00.
    const line = ReceiptLine(
        product: product,
        lotNo: 'L1',
        expiryDate: '2030-12-31',
        qty: 10,
        costSantim: 4500);

    Future<TestTerminal> atReceive(WidgetTester tester) async {
      tall(tester);
      final t = TestTerminal.build(db, role: 'owner');
      t.suppliers.all.addAll(const [epss, addis]);
      await pumpTerminalScreen(
          tester, t.terminal, const ReceiveScreen(debugLines: [line]));
      await tester.pump();
      return t;
    }

    PButton confirm(WidgetTester tester) => tester
        .widgetList<PButton>(find.byType(PButton))
        .firstWhere((b) => b.label.contains('Confirm receipt'));

    Future<void> tapConfirm(WidgetTester tester) async {
      confirm(tester).onPressed!();
      await tester.pumpAndSettle();
    }

    testWidgets('a known supplier is one tap, and the receipt goes to them',
        (tester) async {
      final t = await atReceive(tester);
      await tester.tap(find.widgetWithText(ActionChip, 'EPSS'));
      await tester.pump();
      await tapConfirm(tester);

      final receipt = t.inventory.receipts.single;
      expect(receipt.supplierId, 's1');
      expect(receipt.supplierName, 'EPSS');
      // Paid on delivery unless someone says otherwise.
      expect(receipt.owedSantim, 0);
      expect(t.suppliers.all.length, 2);
    });

    testWidgets('typed in another case is still the same supplier',
        (tester) async {
      final t = await atReceive(tester);
      await tester.enterText(find.byType(TextField).first, ' epss ');
      await tester.pump();
      await tapConfirm(tester);

      expect(t.inventory.receipts.single.supplierId, 's1');
      // Recorded under the supplier's own spelling.
      expect(t.inventory.receipts.single.supplierName, 'EPSS');
      expect(t.suppliers.all.length, 2);
    });

    testWidgets('a name nobody has typed before opens a supplier by itself',
        (tester) async {
      final t = await atReceive(tester);
      await tester.enterText(find.byType(TextField).first, 'Kenema Wholesale');
      await tester.pump();
      await tapConfirm(tester);

      expect(t.suppliers.all.map((s) => s.name), contains('Kenema Wholesale'));
      expect(t.inventory.receipts.single.supplierId, 'supplier-3');
    });

    testWidgets('not paid yet: the whole cost goes on the account',
        (tester) async {
      final t = await atReceive(tester);
      await tester.tap(find.widgetWithText(ActionChip, 'EPSS'));
      await tester.pump();
      await tester.tap(find.text('Not paid yet'));
      await tester.pump();

      expect(find.text('450.00'), findsWidgets);
      await tapConfirm(tester);
      expect(t.inventory.receipts.single.owedSantim, 45000);
    });

    testWidgets('part paid: only the rest goes on the account', (tester) async {
      final t = await atReceive(tester);
      await tester.tap(find.widgetWithText(ActionChip, 'EPSS'));
      await tester.pump();
      await tester.tap(find.text('Not paid yet'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).last, '150');
      await tester.pump();

      expect(find.text('300.00'), findsOneWidget);
      await tapConfirm(tester);
      // 300 birr, as integer santim (G4).
      expect(t.inventory.receipts.single.owedSantim, 30000);
    });

    testWidgets(
        'paying more than it cost, or not a number, cannot be confirmed',
        (tester) async {
      await atReceive(tester);
      await tester.tap(find.widgetWithText(ActionChip, 'EPSS'));
      await tester.pump();
      await tester.tap(find.text('Not paid yet'));
      await tester.pump();

      await tester.enterText(find.byType(TextField).last, '451');
      await tester.pump();
      expect(confirm(tester).onPressed, isNull);

      await tester.enterText(find.byType(TextField).last, '4x');
      await tester.pump();
      expect(confirm(tester).onPressed, isNull);

      await tester.enterText(find.byType(TextField).last, '450');
      await tester.pump();
      expect(confirm(tester).onPressed, isNotNull);
    });
  });

  group('the cash-up', () {
    testWidgets('shows cash paid to suppliers as its own line, taken off',
        (tester) async {
      final t = TestTerminal.build(db);
      t.shifts.active = till();
      t.shifts.expected = const ExpectedCash(
        openingFloatSantim: 20000,
        cashTakenSantim: 15000,
        saleCount: 6,
        unsyncedSaleCount: 0,
        paidOutCashSantim: 5000,
      );
      await pumpTerminalScreen(tester, t.terminal, const CashUpScreen());
      await tester.pump();

      expect(find.text('Paid to suppliers from the till'), findsOneWidget);
      expect(find.text('−50.00'), findsOneWidget);
      // 200.00 + 150.00 − 50.00.
      expect(find.text('300.00'), findsWidgets);
    });

    testWidgets('says nothing about suppliers on a till that paid none',
        (tester) async {
      final t = TestTerminal.build(db);
      t.shifts.active = till();
      await pumpTerminalScreen(tester, t.terminal, const CashUpScreen());
      await tester.pump();
      expect(find.text('Paid to suppliers from the till'), findsNothing);
    });
  });

  testWidgets('in Amharic (AC-10.1)', (tester) async {
    tall(tester);
    final t = TestTerminal.build(db, role: 'owner');
    t.suppliers.all.add(epss);
    await pumpTerminalScreen(tester, t.terminal, const SuppliersScreen(),
        locale: 'am');
    await tester.pump();
    expect(find.text('አቅራቢዎች'), findsOneWidget);
    expect(find.text('Suppliers'), findsNothing);
    expect(find.text('You owe'), findsNothing);
  });
}
