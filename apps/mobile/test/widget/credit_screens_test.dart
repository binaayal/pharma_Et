import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/data/customer_repository.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/data/shift_repository.dart';
import 'package:pharmaet_mobile/ui/customers_screen.dart';
import 'package:pharmaet_mobile/ui/kit.dart';
import 'package:pharmaet_mobile/ui/payment_screen.dart';
import 'package:pharmaet_mobile/ui/settings_screen.dart';

import '../support/terminal.dart';
import '../support/test_db.dart';

/// FR-16 — the debt book on the phone: selling on credit, and collecting.
///
/// The arithmetic is held by the guardian suites on both sides. This is what the person at
/// the counter is shown and stopped from doing: a credit sale with nobody to owe it, a
/// "credit" sale that is really paid in full, and a repayment whose cash no cash-up will
/// expect.
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

  const abebe = LocalCustomer(
      id: 'c1',
      name: 'Abebe Kebede',
      phone: '0911 23 45 67',
      balanceSantim: 12000);
  const clinic =
      LocalCustomer(id: 'c2', name: 'Selam Clinic', balanceSantim: 45000);
  const ahead = LocalCustomer(id: 'c3', name: 'Tigist', balanceSantim: -2000);

  /// What the headline tiles say. A tile draws its value and unit as one rich text, so
  /// the value is read from the widget rather than searched for on screen.
  List<String> tiles(WidgetTester tester) =>
      tester.widgetList<PTile>(find.byType(PTile)).map((t) => t.value).toList();

  PButton button(WidgetTester tester, String label) =>
      tester.widget<PButton>(find.widgetWithText(PButton, label));

  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 3600);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  group('taking payment on credit', () {
    /// A cart worth 45.00, at the payment screen.
    Future<TestTerminal> atPayment(WidgetTester tester) async {
      tall(tester);
      final t = TestTerminal.build(db);
      t.addProduct('p1', 'Paracetamol', price: 1500);
      t.customers.all.addAll(const [abebe, clinic]);
      await t.terminal.refresh();
      t.terminal.addLine(t.terminal.products.single, onHand: 100);
      t.terminal.setQty(0, 3);
      await pumpTerminalScreen(tester, t.terminal, const PaymentScreen());
      return t;
    }

    testWidgets('is offered beside cash', (tester) async {
      await atPayment(tester);
      expect(find.text('On credit'), findsOneWidget);
    });

    testWidgets('cannot be completed until someone owes it', (tester) async {
      await atPayment(tester);
      await tester.tap(find.text('On credit'));
      await tester.pump();

      expect(find.text('Choose a customer'), findsOneWidget);
      expect(button(tester, 'Complete sale').onPressed, isNull);
    });

    testWidgets('picking a customer shows what they already owe',
        (tester) async {
      await atPayment(tester);
      await tester.tap(find.text('On credit'));
      await tester.pump();
      await tester.tap(find.text('Choose a customer'));
      await tester.pumpAndSettle();

      // Who owes most is listed first.
      expect(find.text('Selam Clinic'), findsOneWidget);
      await tester.tap(find.text('Abebe Kebede'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Already owes 120.00'), findsOneWidget);
      // Nothing paid today: the whole 45.00 goes on the account.
      expect(find.text('45.00'), findsWidgets);
      expect(button(tester, 'Complete sale').onPressed, isNotNull);
    });

    testWidgets('part paid now leaves only the rest on the account',
        (tester) async {
      await atPayment(tester);
      await tester.tap(find.text('On credit'));
      await tester.pump();
      await tester.tap(find.text('Choose a customer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Abebe Kebede'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '20');
      await tester.pump();

      expect(find.text('Goes on their account'), findsOneWidget);
      expect(find.text('25.00'), findsOneWidget);
      expect(button(tester, 'Complete sale').onPressed, isNotNull);
    });

    testWidgets('paying all of it now is not a credit sale, and says so',
        (tester) async {
      await atPayment(tester);
      await tester.tap(find.text('On credit'));
      await tester.pump();
      await tester.tap(find.text('Choose a customer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Abebe Kebede'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '45');
      await tester.pump();

      expect(find.textContaining('Choose Cash instead'), findsOneWidget);
      expect(button(tester, 'Complete sale').onPressed, isNull);
    });

    testWidgets('a new customer can be opened without leaving the sale',
        (tester) async {
      final t = await atPayment(tester);
      await tester.tap(find.text('On credit'));
      await tester.pump();
      await tester.tap(find.text('Choose a customer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New customer'));
      await tester.pumpAndSettle();

      expect(button(tester, 'Save customer').onPressed, isNull);
      // The form's own fields come after the picker's search box.
      await tester.enterText(
          find.byType(TextField).at(2), 'Kebede Pharmacy Staff');
      await tester.pump();
      await tester.tap(find.widgetWithText(PButton, 'Save customer'));
      await tester.pumpAndSettle();

      expect(t.customers.all.map((c) => c.name),
          contains('Kebede Pharmacy Staff'));
      // Back on the payment screen, with them chosen.
      expect(find.text('Kebede Pharmacy Staff'), findsOneWidget);
      expect(button(tester, 'Complete sale').onPressed, isNotNull);
    });

    testWidgets('says what is and is not kept about a customer',
        (tester) async {
      await atPayment(tester);
      await tester.tap(find.text('On credit'));
      await tester.pump();
      await tester.tap(find.text('Choose a customer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New customer'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Nothing about what they are treated for'),
          findsOneWidget);
    });
  });

  group('the debt book', () {
    Future<TestTerminal> book(WidgetTester tester,
        {String role = 'cashier'}) async {
      tall(tester);
      final t = TestTerminal.build(db, role: role);
      t.customers.all.addAll(const [abebe, clinic, ahead]);
      await pumpTerminalScreen(tester, t.terminal, const CustomersScreen());
      await tester.pump();
      return t;
    }

    testWidgets('leads with the total owed, and who owes most', (tester) async {
      await book(tester);

      // 120.00 + 450.00. Tigist's 20.00 in hand does not make it 550.00.
      expect(tiles(tester), ['570', '2']);

      final names = tester
          .widgetList<PRow>(find.byType(PRow))
          .map((r) => r.title)
          .toList();
      expect(names, ['Selam Clinic', 'Abebe Kebede', 'Tigist']);
      expect(find.text('paid ahead'), findsOneWidget);
    });

    testWidgets('an empty book says how the first account gets opened',
        (tester) async {
      tall(tester);
      final t = TestTerminal.build(db);
      await pumpTerminalScreen(tester, t.terminal, const CustomersScreen());
      await tester.pump();
      expect(find.textContaining('Nobody owes anything yet'), findsOneWidget);
    });

    testWidgets('is reached from Settings by anyone who sells', (tester) async {
      tall(tester);
      final t = TestTerminal.build(db, role: 'cashier');
      await pumpTerminalScreen(
          tester, t.terminal, const Scaffold(body: SettingsScreen()));
      expect(find.text('Customers & credit'), findsOneWidget);
    });
  });

  group('taking a repayment', () {
    Future<TestTerminal> atCustomer(WidgetTester tester,
        {bool tillOpen = true}) async {
      tall(tester);
      final t = TestTerminal.build(db);
      t.customers.all.add(abebe);
      if (tillOpen) {
        t.shifts.active = ActiveShift(
            id: 'shift-1',
            userId: 'u',
            branchId: 'b',
            openedAt: DateTime.utc(2026, 10, 7, 6),
            openingFloatSantim: 20000);
      }
      await pumpTerminalScreen(
          tester, t.terminal, const CustomerScreen(customerId: 'c1'));
      await tester.pump();
      return t;
    }

    testWidgets('shows what will still be owed before it is recorded',
        (tester) async {
      await atCustomer(tester);
      await tester.tap(find.text('Take a payment'));
      await tester.pumpAndSettle();

      expect(button(tester, 'Record payment').onPressed, isNull);
      await tester.enterText(find.byType(TextField).first, '50');
      await tester.pump();

      expect(find.text('Will still owe'), findsOneWidget);
      expect(find.text('70.00'), findsOneWidget);
      expect(button(tester, 'Record payment').onPressed, isNotNull);
    });

    testWidgets('records cash into the open till, so the cash-up expects it',
        (tester) async {
      final t = await atCustomer(tester);
      await tester.tap(find.text('Take a payment'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '50');
      await tester.pump();
      await tester.tap(find.widgetWithText(PButton, 'Record payment'));
      await tester.pumpAndSettle();

      final payment = t.customers.payments.single;
      // 50 birr, as integer santim (G4).
      expect(payment.amountSantim, 5000);
      expect(payment.method, 'cash');
      expect(payment.shiftId, 'shift-1');
      // And the screen behind now shows the new balance.
      expect(tiles(tester).first, '70.00');
    });

    testWidgets('more than is owed is accepted, and shown as paid ahead',
        (tester) async {
      await atCustomer(tester);
      await tester.tap(find.text('Take a payment'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '150');
      await tester.pump();

      expect(find.text('Will be ahead by'), findsOneWidget);
      expect(find.text('30.00'), findsOneWidget);
      expect(button(tester, 'Record payment').onPressed, isNotNull);
    });

    testWidgets(
        'warns when cash is taken with no till open — but still takes it',
        (tester) async {
      final t = await atCustomer(tester, tillOpen: false);
      await tester.tap(find.text('Take a payment'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '50');
      await tester.pump();

      expect(find.textContaining('will not be in any cash-up'), findsOneWidget);
      await tester.tap(find.widgetWithText(PButton, 'Record payment'));
      await tester.pumpAndSettle();
      // A repayment is never turned away for want of a shift.
      expect(t.customers.payments.single.shiftId, isNull);
    });

    testWidgets('by Telebirr is recorded as such, and needs no till',
        (tester) async {
      final t = await atCustomer(tester, tillOpen: false);
      await tester.tap(find.text('Take a payment'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '50');
      await tester.tap(find.text('Other'));
      await tester.pump();

      expect(find.textContaining('will not be in any cash-up'), findsNothing);
      await tester.tap(find.widgetWithText(PButton, 'Record payment'));
      await tester.pumpAndSettle();
      expect(t.customers.payments.single.method, 'other_recorded');
    });
  });

  testWidgets('in Amharic (AC-10.1)', (tester) async {
    tall(tester);
    final t = TestTerminal.build(db);
    t.customers.all.add(abebe);
    await pumpTerminalScreen(tester, t.terminal, const CustomersScreen(),
        locale: 'am');
    await tester.pump();
    expect(find.text('ደንበኞችና ዱቤ'), findsOneWidget);
    expect(find.text('Customers & credit'), findsNothing);
    expect(find.text('ዕዳ አለበት'), findsOneWidget);
  });
}
