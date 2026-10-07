import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pharmaet_mobile/data/catalog_repository.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/ui/receive_screen.dart';
import 'package:pharmaet_mobile/ui/scan_screen.dart';
import 'package:pharmaet_mobile/ui/stock_screen.dart';

import '../support/terminal.dart';
import '../support/test_db.dart';

/// FR-13 — the two places besides the till where a scan does work: reading a delivery box,
/// and telling the app which product a barcode is.
///
/// The camera itself is replaced by a script (`BarcodeScanner.debugScans`); what is under
/// test is what each screen does with the code it is handed.
void main() {
  late LocalDb db;
  late Directory dir;

  setUp(() async {
    final opened = await openTestDb();
    db = opened.db;
    dir = opened.dir;
  });

  tearDown(() async {
    BarcodeScanner.debugScans = null;
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  const paracetamol = LocalProduct(
      id: 'p1',
      name: 'Paracetamol 500mg tablet',
      unit: 'tablet',
      isControlled: false,
      priceSantim: 500,
      barcodes: ['06291100080014']);
  const amoxicillin = LocalProduct(
      id: 'p2',
      name: 'Amoxicillin 500mg capsule',
      unit: 'capsule',
      isControlled: false,
      priceSantim: 400);

  String field(WidgetTester tester, int i) =>
      tester.widget<TextField>(find.byType(TextField).at(i)).controller!.text;

  group('receiving a delivery', () {
    Future<void> openLine(WidgetTester tester, TestTerminal t) async {
      t.catalog.products_.addAll(const [paracetamol, amoxicillin]);
      await pumpTerminalScreen(tester, t.terminal, const ReceiveScreen());
      await tester.tap(find.textContaining('Add item'));
      await tester.pumpAndSettle();
    }

    Future<void> scan(WidgetTester tester, String code) async {
      BarcodeScanner.debugScans = [code];
      await tester.tap(find.text('Scan the box'));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('a DataMatrix fills the product, the lot and the expiry',
        (tester) async {
      final t = TestTerminal.build(db, role: 'branch_manager');
      await openLine(tester, t);
      await scan(tester, '010629110008001417301231${'10'}LOT42A');

      expect(find.text('Paracetamol 500mg tablet'), findsOneWidget);
      // Field 0 is the supplier on the screen behind; the lot is the sheet's first.
      expect(field(tester, 1), 'LOT42A');
      // Shown as the Gregorian date on the box, for checking against it.
      expect(find.textContaining('2030-12-31'), findsOneWidget);
      // Read into the fields, not saved: the quantity is still the person's to enter.
      expect(find.widgetWithText(GestureDetector, 'Add line'), findsWidgets);
    });

    testWidgets('a plain barcode picks the product and leaves the rest alone',
        (tester) async {
      final t = TestTerminal.build(db, role: 'branch_manager');
      await openLine(tester, t);
      await scan(tester, '6291100080014');

      expect(find.text('Paracetamol 500mg tablet'), findsOneWidget);
      expect(field(tester, 1), isEmpty);
      expect(find.textContaining('2030-'), findsNothing);
    });

    testWidgets(
        'an unlinked box still gives up its lot and expiry, and says so',
        (tester) async {
      final t = TestTerminal.build(db, role: 'branch_manager');
      await openLine(tester, t);
      // A GTIN no product carries.
      await scan(tester, '010629110099999117301231${'10'}B7');

      expect(find.text('No product has this barcode yet.'), findsOneWidget);
      expect(field(tester, 1), 'B7');
      expect(find.textContaining('2030-12-31'), findsOneWidget);
      // No product was guessed.
      expect(find.text('Paracetamol 500mg tablet'), findsNothing);
    });
  });

  group('linking a barcode to a product', () {
    /// Opens the product screen the way the app does — pushed — because a successful
    /// save closes it.
    Future<void> openProduct(
        WidgetTester tester, TestTerminal t, LocalProduct product) async {
      t.catalog.products_.addAll(const [paracetamol, amoxicillin]);
      await pumpTerminalScreen(
          tester,
          t.terminal,
          Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) => ProductScreen(
                                stock: ProductStock(
                              product: product,
                              onHand: 0,
                              batchCount: 0,
                              nearestExpiry: null,
                              oversold: false,
                            )))),
                child: const Text('open'),
              ),
            ),
          ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    MockClient recording(List<Map<String, dynamic>> posted,
            {int status = 201}) =>
        MockClient((request) async {
          if (request.method == 'POST' &&
              request.url.path.endsWith('/barcodes')) {
            posted.add({
              'path': request.url.path,
              ...jsonDecode(request.body) as Map<String, dynamic>,
            });
            return http.Response(
                status == 201
                    ? '{"id":"p2","barcodes":[]}'
                    : '{"message":"barcode 06291100090013 already belongs to \\"Other\\""}',
                status);
          }
          return http.Response('{}', 503);
        });

    testWidgets('an owner scans a box and it is sent in canonical form',
        (tester) async {
      final posted = <Map<String, dynamic>>[];
      final t = TestTerminal.build(db, role: 'owner', api: recording(posted));
      await openProduct(tester, t, amoxicillin);

      BarcodeScanner.debugScans = ['6291100090013'];
      await tester.ensureVisible(find.text('Scan a barcode to link'));
      await tester.tap(find.text('Scan a barcode to link'));
      await tester.pumpAndSettle();

      expect(posted.single['path'], '/products/p2/barcodes');
      expect(posted.single['barcodes'], ['06291100090013']);
    });

    testWidgets('a box that is already another product is refused by name',
        (tester) async {
      final posted = <Map<String, dynamic>>[];
      final t = TestTerminal.build(db, role: 'owner', api: recording(posted));
      await openProduct(tester, t, amoxicillin);

      // Paracetamol's barcode, scanned while linking Amoxicillin.
      BarcodeScanner.debugScans = ['6291100080014'];
      await tester.ensureVisible(find.text('Scan a barcode to link'));
      await tester.tap(find.text('Scan a barcode to link'));
      await tester.pump();
      await tester.pump();

      expect(
          find.text(
              'This barcode already belongs to Paracetamol 500mg tablet.'),
          findsOneWidget);
      // Caught on the phone: nothing was sent.
      expect(posted, isEmpty);
    });

    testWidgets('what the server refuses is said, and nothing changes',
        (tester) async {
      final posted = <Map<String, dynamic>>[];
      final t = TestTerminal.build(db,
          role: 'owner', api: recording(posted, status: 409));
      await openProduct(tester, t, amoxicillin);

      BarcodeScanner.debugScans = ['6291100090013'];
      await tester.ensureVisible(find.text('Scan a barcode to link'));
      await tester.tap(find.text('Scan a barcode to link'));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('already belongs to "Other"'), findsOneWidget);
      // Still on the product screen.
      expect(find.text('Scan a barcode to link'), findsOneWidget);
    });

    testWidgets(
        'a cashier sees the barcodes and is offered no way to change them',
        (tester) async {
      final t = TestTerminal.build(db, role: 'cashier');
      await openProduct(tester, t, paracetamol);

      expect(find.text('06291100080014'), findsOneWidget);
      expect(find.text('Scan a barcode to link'), findsNothing);
      expect(find.byTooltip('Unlink this barcode'), findsNothing);
    });

    testWidgets('unlinking sends the list without that barcode',
        (tester) async {
      final posted = <Map<String, dynamic>>[];
      final t = TestTerminal.build(db, role: 'owner', api: recording(posted));
      await openProduct(tester, t, paracetamol);

      await tester.ensureVisible(find.byTooltip('Unlink this barcode'));
      await tester.tap(find.byTooltip('Unlink this barcode'));
      await tester.pumpAndSettle();

      expect(posted.single['path'], '/products/p1/barcodes');
      expect(posted.single['barcodes'], isEmpty);
    });
  });
}
