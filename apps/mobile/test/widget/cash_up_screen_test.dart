import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/data/shift_repository.dart';
import 'package:pharmaet_mobile/ui/cash_up_screen.dart';
import 'package:pharmaet_mobile/ui/kit.dart';

import '../support/terminal.dart';
import '../support/test_db.dart';

/// T3 — the cash-up screen (prototype screen 15; FR-8, AC-8.1, BR-8.2).
///
/// The owner's anti-shrinkage control. As the prototype designs it, the expected figure is
/// on screen before the count and the variance appears as the cashier types — and whatever
/// it says is recorded. Refusing a discrepancy would teach people to fudge the count until
/// the screen let them through.
void main() {
  late LocalDb db;
  late Directory dir;
  late TestTerminal t;

  setUp(() async {
    final opened = await openTestDb();
    db = opened.db;
    dir = opened.dir;
    t = TestTerminal.build(db);
    t.shifts.active = ActiveShift(
      id: '01930000-0000-7000-8000-0000000000c1',
      userId: '01930000-0000-7000-8000-000000000003',
      branchId: '01930000-0000-7000-8000-000000000002',
      openedAt: DateTime.utc(2026, 9, 24, 8),
      openingFloatSantim: 20000,
    );
  });

  tearDown(() async {
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> open(WidgetTester tester) async {
    await pumpTerminalScreen(tester, t.terminal, const CashUpScreen());
    await tester.pump();
  }

  PButton action(WidgetTester tester) =>
      tester.widget<PButton>(find.byType(PButton));

  testWidgets('shows the float, the cash taken and what the drawer should hold',
      (tester) async {
    await open(tester);

    // 200.00 float + 150.00 cash sales = 350.00 expected.
    expect(find.text('200.00'), findsOneWidget);
    expect(find.text('150.00'), findsOneWidget);
    expect(find.text('350.00'), findsOneWidget);
  });

  testWidgets('a shortage is reported as the count is typed, and recorded',
      (tester) async {
    await open(tester);

    await tester.enterText(find.byType(TextField).first, '300');
    await tester.pump();
    expect(find.textContaining('-50.00 ETB'), findsOneWidget);

    await tester.tap(find.text('Record count & close shift'));
    await tester.pump();
    await tester.pump();

    // Reported, never refused.
    expect(t.shifts.recordedCount, 30000);
    expect(find.textContaining('queued for the office'), findsOneWidget);
  });

  testWidgets('the till is not taken twice', (tester) async {
    await open(tester);

    await tester.enterText(find.byType(TextField).first, '350');
    await tester.pump();
    await tester.tap(find.text('Record count & close shift'));
    await tester.pump();
    await tester.pump();

    // Once the count is in, the fields are disabled and the button is "Done". A second
    // submission would write a second cash-up against a shift that is already closed.
    expect(find.text('Record count & close shift'), findsNothing);
    final fields = tester.widgetList<TextField>(find.byType(TextField));
    expect(fields.every((f) => f.enabled == false), isTrue);
  });

  testWidgets('it will not accept a count that is not a number',
      (tester) async {
    await open(tester);

    await tester.enterText(find.byType(TextField).first, 'abc');
    await tester.pump();

    // Disabled rather than rejected on submit: money never becomes a float (G4).
    expect(action(tester).onPressed, isNull);
  });
}
