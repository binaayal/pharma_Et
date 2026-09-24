import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/data/outbox.dart';
import 'package:pharmaet_mobile/data/shift_repository.dart';
import 'package:pharmaet_mobile/ui/cash_up_screen.dart';

import '../support/pump.dart';
import '../support/test_db.dart';

/// T3 — the cash-up screen (docs/05-qa §3; FR-8, AC-8.1).
///
/// This screen is the owner's primary anti-shrinkage control (`01-vision` §2.1.1), and the
/// control lives in the *interface*, not in the arithmetic. Two of its decisions are load-
/// bearing and neither is visible from any other tier of test:
///
///  - **The expected figure is hidden until the count is entered.** A reconciliation that
///    shows the target first is not a count, it is a prompt. That is a property of what is on
///    screen at a moment in time, which is exactly what a widget test can see and a repository
///    test cannot.
///  - **A variance is reported, never blocked.** Refusing a discrepancy would teach people to
///    fudge the count until the screen let them through.
void main() {
  late LocalDb db;
  late Directory dir;
  late ShiftRepository shifts;
  late ActiveShift shift;

  setUp(() async {
    final opened = await openTestDb();
    db = opened.db;
    dir = opened.dir;
    // A stub, because T3 is about what the screen does — the repository's arithmetic is
    // already covered by g4_cash_up_test.dart at T1. Using the real one here would put real
    // file I/O inside a widget test's fake-async zone and test the wrong layer twice.
    shifts = _StubShifts(db, Outbox(db));

    shift = ActiveShift(
      id: '01930000-0000-7000-8000-0000000000s1',
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

  Future<void> open(WidgetTester tester) => pumpScreen(
        tester,
        CashUpScreen(shift: shift, shifts: shifts, onCompleted: (_) {}),
      );

  testWidgets(
      'the expected figure is not on screen before the count is entered',
      (tester) async {
    await open(tester);

    // 350.00 is the expected total (200.00 float + 150.00 taken). If it were rendered
    // anywhere before the cashier committed a count, this screen would be asking them to
    // agree with a number rather than to count a drawer.
    expect(find.textContaining('350.00'), findsNothing);
    expect(find.textContaining('Expected'), findsNothing);

    // The opening float IS shown, and should be: the cashier knows what they started with,
    // and hiding it would be secrecy rather than control.
    expect(find.textContaining('200.00'), findsWidgets);
  });

  testWidgets('it appears only after the count is recorded', (tester) async {
    await open(tester);

    await tester.enterText(find.byType(TextField).first, '350');
    await tester.pump();
    await tester.tap(find.text('Record count & close shift'));
    await tester.pump();

    // Now it is a reconciliation rather than a prompt, so the figure is shown — and with it
    // the difference the cashier is being asked to explain.
    expect(find.textContaining('350.00'), findsWidgets);
  });

  testWidgets('a shortfall is reported, and the shift still closes',
      (tester) async {
    var reported = 0;
    await pumpScreen(
      tester,
      CashUpScreen(
        shift: shift,
        shifts: shifts,
        onCompleted: (variance) => reported = variance,
      ),
    );

    await tester.enterText(find.byType(TextField).first, '300');
    await tester.pump();
    await tester.tap(find.text('Record count & close shift'));
    await tester.pump();

    // 300.00 counted against 350.00 expected: 50.00 short. Reported, never refused —
    // blocking would simply teach the counter to enter whatever the screen accepts.
    expect(reported, -5000);
    expect(find.textContaining('50.00'), findsWidgets);
  });

  testWidgets('the till is not taken twice', (tester) async {
    await open(tester);

    await tester.enterText(find.byType(TextField).first, '350');
    await tester.pump();
    await tester.tap(find.text('Record count & close shift'));
    await tester.pump();

    // Once the count is in, the entry fields and the button are gone. A second submission
    // would write a second cash-up against a shift that is already closed.
    expect(find.text('Record count & close shift'), findsNothing);
    final fields = tester.widgetList<TextField>(find.byType(TextField));
    expect(fields.every((f) => f.enabled == false), isTrue);
  });

  testWidgets('it will not accept a count that is not a number',
      (tester) async {
    await open(tester);

    await tester.enterText(find.byType(TextField).first, 'abc');
    await tester.pump();

    // Disabled rather than rejected-on-submit: money never becomes a float, and a screen that
    // accepted "abc" would have to decide what it meant (G4).
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
  });
}

/// Returns a fixed expectation: 200.00 ETB of float and no sales.
class _StubShifts extends ShiftRepository {
  _StubShifts(super.db, super.outbox);

  @override
  Future<ExpectedCash> expectedCash(String shiftId) async => const ExpectedCash(
        // Float and takings deliberately different, so "expected" and "float" are two
        // distinguishable numbers. With zero sales they coincide, and a test could not tell
        // a screen that leaks the target from one that simply shows the opening float.
        openingFloatSantim: 20000,
        cashTakenSantim: 15000,
        saleCount: 6,
        unsyncedSaleCount: 0,
      );

  @override
  Future<int> closeShiftWithCashUp({
    required ActiveShift shift,
    required int countedSantim,
    String? note,
  }) async =>
      countedSantim - 35000;
}
