import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/ui/kit.dart';
import 'package:pharmaet_mobile/ui/payment_screen.dart';
import 'package:pharmaet_mobile/ui/receipt_output.dart';
import 'package:pharmaet_mobile/ui/receipt_screen.dart';

import '../support/terminal.dart';
import '../support/test_db.dart';

/// FR-14 — the receipt leaves the phone (prototype screen 10).
///
/// The share sheet and the print dialog belong to the operating system and are replaced
/// here; what is tested is that the screen hands them the sale that was actually rung up,
/// and that a receipt which cannot be sent never looks like a sale that was not saved.
void main() {
  late LocalDb db;
  late Directory dir;

  setUp(() async {
    final opened = await openTestDb();
    db = opened.db;
    dir = opened.dir;
  });

  tearDown(() async {
    ReceiptOutput.debugShare = null;
    ReceiptOutput.debugPrint = null;
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  const screen = ReceiptScreen(
    saleId: '01930000-0000-7000-8000-00000000a1b2',
    totalSantim: 25000,
    changeSantim: 5000,
    tender: Tender.cash,
    commitMs: 12,
    lines: [
      (
        name: 'Paracetamol 500mg tablet',
        qty: 10,
        packName: null,
        unit: 'tablet',
        unitPriceSantim: 500,
        lineTotalSantim: 5000,
      ),
      (
        name: 'Amoxicillin 500mg capsule',
        qty: 2,
        packName: 'box',
        unit: 'box',
        unitPriceSantim: 10000,
        lineTotalSantim: 20000,
      ),
    ],
  );

  Future<void> open(WidgetTester tester, {String locale = 'en'}) async {
    final t = TestTerminal.build(db);
    await pumpTerminalScreen(tester, t.terminal, screen, locale: locale);
  }

  testWidgets('a wholesale sale says so on the screen, as it does on paper',
      (tester) async {
    // Found on a phone: the printed slip said "Wholesale" and the screen did not.
    final t = TestTerminal.build(db);
    await pumpTerminalScreen(
        tester,
        t.terminal,
        const ReceiptScreen(
          saleId: '01930000-0000-7000-8000-00000000a1b2',
          totalSantim: 17000,
          changeSantim: 0,
          tender: Tender.cash,
          commitMs: 12,
          wholesale: true,
          lines: [
            (
              name: 'Amoxicillin 500mg capsule',
              qty: 2,
              packName: 'box',
              unit: 'box',
              unitPriceSantim: 8500,
              lineTotalSantim: 17000,
            ),
          ],
        ));
    expect(find.textContaining('· Wholesale ·'), findsOneWidget);
  });

  testWidgets('a retail sale says nothing about price lists', (tester) async {
    await open(tester);
    expect(find.textContaining('Wholesale'), findsNothing);
  });

  testWidgets('offers to share, to print, and to get on with the next sale',
      (tester) async {
    await open(tester);
    expect(find.text('Share'), findsOneWidget);
    expect(find.text('Print'), findsOneWidget);
    expect(find.text('New sale'), findsOneWidget);
  });

  testWidgets('shares the sale that was rung up, as text', (tester) async {
    String? shared;
    String? subject;
    ReceiptOutput.debugShare = (text, s) async {
      shared = text;
      subject = s;
    };
    await open(tester);
    await tester.tap(find.text('Share'));
    await tester.pump();

    // The branch the stub terminal stands in, and the tail of the sale id.
    expect(subject, contains('Bole'));
    expect(shared, contains('Sale #BOL-A1B2'));
    expect(shared, contains('10 tablet × 5.00 = 50.00'));
    expect(shared, contains('2 box × 100.00 = 200.00'));
    expect(shared, contains('Total: 250.00 ETB'));
    // 250 due, 50 change: 300 was handed over.
    expect(shared, contains('Cash received: 300.00'));
    expect(shared, contains('Change given: 50.00'));
  });

  testWidgets('shares in Amharic when the till is in Amharic', (tester) async {
    String? shared;
    ReceiptOutput.debugShare = (text, _) async => shared = text;
    await open(tester, locale: 'am');
    await tester.tap(find.text('አጋራ'));
    await tester.pump();

    expect(shared, contains('ጠቅላላ: 250.00 ETB'));
    expect(shared, isNot(contains('Total:')));
  });

  testWidgets('prints a PDF named after the sale', (tester) async {
    Uint8List? printed;
    String? name;
    ReceiptOutput.debugPrint = (pdf, n) async {
      printed = pdf;
      name = n;
    };
    await open(tester);
    await tester.runAsync(() async {
      await tester.tap(find.text('Print'));
      // Rendering reads the bundled font, which is real I/O.
      for (var i = 0; i < 40 && printed == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });

    expect(name, 'receipt-BOL-A1B2');
    expect(printed, isNotNull);
    expect(ascii.decode(printed!.sublist(0, 5)), '%PDF-');
  });

  testWidgets(
      'a receipt that cannot be sent says so — and that the sale is safe',
      (tester) async {
    ReceiptOutput.debugShare =
        (_, __) async => throw Exception('no share sheet');
    await open(tester);
    await tester.tap(find.text('Share'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('The sale itself is saved'), findsOneWidget);
    // Still on the receipt, and the next sale is one tap away.
    final next =
        tester.widget<PButton>(find.widgetWithText(PButton, 'New sale'));
    expect(next.onPressed, isNotNull);
  });
}
