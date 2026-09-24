import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/data/catalog_repository.dart';
import 'package:pharmaet_mobile/data/inventory_repository.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/data/outbox.dart';
import 'package:pharmaet_mobile/ui/receive_screen.dart';
import 'package:pharmaet_mobile/ui/reconcile_screen.dart';

import '../support/pump.dart';
import '../support/test_db.dart';

/// T3 — receiving stock and correcting a count (docs/05-qa §3; FR-7, FR-3/BR-3.2).
///
/// Both screens guard the same class of mistake: a number entered at a counter that the
/// system cannot afterwards tell apart from a deliberate one. The guards live in what the
/// form will and will not let you submit, which is only observable here.
void main() {
  late LocalDb db;
  late Directory dir;
  late _StubCatalog catalog;
  late InventoryRepository inventory;

  const branchId = '01930000-0000-7000-8000-000000000002';

  setUp(() async {
    final opened = await openTestDb();
    db = opened.db;
    dir = opened.dir;
    final outbox = Outbox(db);
    catalog = _StubCatalog(db);
    inventory = _StubInventory(db, outbox, catalog);
  });

  tearDown(() async {
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('receiving a delivery (FR-7)', () {
    Future<void> open(WidgetTester tester) => pumpScreen(
          tester,
          ReceiveScreen(
              catalog: catalog, inventory: inventory, branchId: branchId),
        );

    testWidgets('will not record a receipt with no supplier and no lines',
        (tester) async {
      catalog.products_.add(const LocalProduct(
        id: 'p1',
        name: 'Paracetamol',
        unit: 'tablet',
        isControlled: false,
        priceSantim: 1500,
      ));
      await open(tester);

      // An empty receipt is indistinguishable from a mis-tap, and it would credit nothing
      // while looking like a delivery was logged.
      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull);
    });

    testWidgets('says plainly that it works without a network', (tester) async {
      await open(tester);

      // Stock arrives when the wholesaler's van arrives, which in this market is not when
      // the network is up. The screen promises that out loud because a counter assistant has
      // no other way to know it is safe to carry on.
      expect(find.textContaining('whether or not there is a network'),
          findsOneWidget);
    });

    testWidgets('offers no controlled substances', (tester) async {
      catalog.products_.addAll(const [
        LocalProduct(
            id: 'p1',
            name: 'Paracetamol',
            unit: 'tablet',
            isControlled: false,
            priceSantim: 1500),
        LocalProduct(
            id: 'p2',
            name: 'Diazepam',
            unit: 'tablet',
            isControlled: true,
            priceSantim: 4000),
      ]);
      await open(tester);
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      // The sheet's product list is a dropdown, so the names exist only once it is open.
      await tester.tap(find.byType(DropdownButtonFormField<LocalProduct>));
      await tester.pumpAndSettle();

      // Controlled stock arrives as ledger events in Phase 2 (ADR-015). Receiving one through
      // the standard path would put an unauditable batch on the shelf.
      expect(find.text('Paracetamol'), findsWidgets);
      expect(find.text('Diazepam'), findsNothing);
    });
  });

  group('in Amharic (AC-10.1: "any core screen")', () {
    // Both stock screens shipped with every label hardcoded in English, under an RTM row
    // that called FR-10 done — the strings were tested, the screens were not. Found by
    // switching a real phone to Amharic and opening the stock menu.
    testWidgets('receiving a delivery', (tester) async {
      await pumpScreen(
        tester,
        ReceiveScreen(
            catalog: catalog, inventory: inventory, branchId: branchId),
        locale: 'am',
      );
      expect(find.text('ዕቃ መረከብ'), findsOneWidget);
      expect(find.text('Receive stock'), findsNothing);
      expect(find.text('Supplier'), findsNothing);
    });

    testWidgets('counting the shelf', (tester) async {
      (inventory as _StubInventory).attention.add(const LocalBatch(
            id: 'b1',
            productId: 'p1',
            lotNo: 'LOT-1',
            expiryDate: '2030-01-01',
            qtyOnHand: -3,
          ));
      await pumpScreen(
        tester,
        ReconcileScreen(
            catalog: catalog, inventory: inventory, branchId: branchId),
        locale: 'am',
      );
      expect(find.text('ክምችት መቁጠር'), findsOneWidget);
      expect(find.textContaining('ሎት LOT-1'), findsOneWidget);
      expect(find.textContaining('show less than zero'), findsNothing);
    });
  });

  group('correcting a count (BR-3.2)', () {
    Future<void> open(WidgetTester tester) => pumpScreen(
          tester,
          ReconcileScreen(
              catalog: catalog, inventory: inventory, branchId: branchId),
        );

    testWidgets('a write-off cannot go unexplained', (tester) async {
      (inventory as _StubInventory).attention.add(const LocalBatch(
            id: 'b1',
            productId: 'p1',
            lotNo: 'LOT-1',
            expiryDate: '2030-01-01',
            qtyOnHand: -3,
          ));
      await open(tester);
      await tester.tap(find.textContaining('Lot LOT-1'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '0');
      await tester.pump();

      // A recount may go unexplained; anything else may not. An unexplained write-off is
      // indistinguishable from a covered-up one, and the server refuses it regardless — so a
      // form that let it through would only produce a rejection nobody sees.
      await tester.tap(find.byType(DropdownButtonFormField<AdjustmentReason>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Damaged').last);
      await tester.pumpAndSettle();

      final button =
          tester.widget<FilledButton>(find.byType(FilledButton).last);
      expect(button.onPressed, isNull);
    });

    testWidgets('shows what needs attention rather than the whole shelf',
        (tester) async {
      (inventory as _StubInventory).attention.add(const LocalBatch(
            id: 'b1',
            productId: 'p1',
            lotNo: 'LOT-NEG',
            expiryDate: '2030-01-01',
            qtyOnHand: -3,
          ));
      await open(tester);

      // A negative count is the thing BR-3.2 promised would be "flagged for physical
      // reconciliation". Burying it in a full stock list would be the same as not flagging it.
      expect(find.textContaining('Lot LOT-NEG'), findsOneWidget);
    });
  });
}

class _StubCatalog extends CatalogRepository {
  _StubCatalog(super.db);
  final products_ = <LocalProduct>[];

  @override
  Future<List<LocalProduct>> products() async => products_;
}

class _StubInventory extends InventoryRepository {
  _StubInventory(super.db, super.outbox, super.catalog);
  final attention = <LocalBatch>[];

  @override
  Future<List<LocalBatch>> batchesNeedingAttention(String branchId) async =>
      attention;
}
