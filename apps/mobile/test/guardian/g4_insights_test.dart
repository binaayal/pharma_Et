import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/contracts/contracts.dart';
import 'package:pharmaet_mobile/data/catalog_repository.dart';
import 'package:pharmaet_mobile/data/insights_repository.dart';
import 'package:pharmaet_mobile/data/inventory_repository.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/data/outbox.dart';
import 'package:pharmaet_mobile/data/sale_repository.dart';

import '../support/test_db.dart';

/// G4 — WHERE THE MONEY IS (FR-7a, FR-8a, FR-18's return list; ADR-036).
///
/// These reports tell an owner what to buy, what earns, what is sitting dead and what to
/// send back — and they will spend money on the answers. So each figure is held to the
/// sales and receipts it is made from, with packs in play, because that is where a count
/// in boxes and a count in tablets get confused.
///
/// The rules that are easy to get wrong: profit is revenue less what the goods **cost**,
/// not less what they sell for; a product nobody is buying is never suggested for reorder
/// however little there is of it; and stock received last week is new, not dead.
void main() {
  late LocalDb db;
  late Directory dir;
  late Outbox outbox;
  late CatalogRepository catalog;
  late InventoryRepository inventory;
  late SaleRepository sales;
  late InsightsRepository insights;

  const tenantId = '01930000-0000-7000-8000-000000000001';
  const branchId = '01930000-0000-7000-8000-000000000002';
  const cashierId = '01930000-0000-7000-8000-000000000003';
  const terminalId = '01930000-0000-7000-8000-000000000004';

  const box = ProductPack(name: 'box', size: 30, priceSantim: 10000);
  const amox = LocalProduct(
      id: '01930000-0000-7000-8000-00000000000a',
      name: 'Amoxicillin 500mg capsule',
      unit: 'capsule',
      isControlled: false,
      priceSantim: 400,
      packs: [box]);
  const para = LocalProduct(
      id: '01930000-0000-7000-8000-00000000000b',
      name: 'Paracetamol 500mg tablet',
      unit: 'tablet',
      isControlled: false,
      priceSantim: 500);

  setUp(() async {
    final opened = await openTestDb();
    db = opened.db;
    dir = opened.dir;
    outbox = Outbox(db);
    catalog = CatalogRepository(db);
    inventory = InventoryRepository(db, outbox, catalog);
    sales = SaleRepository(db, outbox, catalog);
    insights = InsightsRepository(db);
    for (final p in [amox, para]) {
      await db.db.insert('product', {
        'id': p.id,
        'name': p.name,
        'unit': p.unit,
        'is_controlled': 0,
        'price_santim': p.priceSantim,
        'packs_json': jsonEncode(p.packs.map((k) => k.toJson()).toList()),
      });
    }
  });

  tearDown(() async {
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> receive(LocalProduct p, int qty, int cost,
          {ProductPack? pack,
          String supplier = 'EPSS',
          String lot = 'L1',
          String expiry = '2035-01-31'}) =>
      inventory.commitReceipt(
        lines: [
          ReceiptLine(
              product: p,
              lotNo: lot,
              expiryDate: expiry,
              qty: qty,
              costSantim: cost,
              pack: pack),
        ],
        supplierName: supplier,
        branchId: branchId,
      );

  Future<void> sell(LocalProduct p, int qty, {ProductPack? pack}) async {
    final batch = await catalog.fefoBatch(p.id, branchId);
    await sales.commitSale(
      lines: [CartLine(product: p, qty: qty, batchId: batch?.id, pack: pack)],
      tenantId: tenantId,
      branchId: branchId,
      cashierId: cashierId,
      terminalId: terminalId,
    );
  }

  /// Moves every sale and receipt [days] into the past, as if they had happened then.
  Future<void> age(int days) async {
    final at =
        DateTime.now().toUtc().subtract(Duration(days: days)).toIso8601String();
    await db.db.update('sale', {'sold_at': at});
    await db.db.update('goods_receipt', {'received_at': at});
  }

  Future<ProductInsight> of(LocalProduct p) async =>
      (await insights.products(branchId))
          .firstWhere((i) => i.product.id == p.id);

  group('profit', () {
    test('is what was taken, less what the goods cost — to the santim',
        () async {
      // Ten boxes of 30 at 90.00 a box: 300 capsules for 900.00, so 3.00 each.
      await receive(amox, 10, 9000, pack: box);
      // Two boxes at 100.00, and five loose at 4.00.
      await sell(amox, 2, pack: box);
      await sell(amox, 5);

      final i = await of(amox);
      expect(i.unitsSold, 65);
      expect(i.revenueSantim, 20000 + 2000);
      // 65 capsules at 3.00.
      expect(i.costOfSalesSantim, 19500);
      expect(i.profitSantim, 2500);
      expect(i.onHand, 235);
    });

    test('a cost that does not divide evenly is rounded once, at the end',
        () async {
      // 100.00 for 30: 3.333… each. Seven sold cost 23.33, not 7 × 3.33 = 23.31.
      await receive(amox, 1, 10000, pack: box);
      await sell(amox, 7);
      expect((await of(amox)).costOfSalesSantim, 2333);
      expect(InsightsRepository.estimateCost(7, 10000, 30), 2333);
      expect(InsightsRepository.estimateCost(30, 10000, 30), 10000);
    });

    test('averages over every delivery, weighted by how much came', () async {
      await receive(para, 100, 200, lot: 'A'); // 100 at 2.00
      await receive(para, 300, 400, lot: 'B'); // 300 at 4.00
      await sell(para, 40);
      // 1400.00 for 400 = 3.50 each.
      expect((await of(para)).costOfSalesSantim, 14000);
    });

    test('says it does not know, rather than claiming everything was profit',
        () async {
      // Sold without ever being received on this phone: no cost to go on.
      await sell(para, 3);
      final i = await of(para);
      expect(i.revenueSantim, 1500);
      expect(i.costOfSalesSantim, isNull);
      expect(i.profitSantim, isNull);
    });

    test('counts only the last thirty days of sales', () async {
      await receive(para, 500, 300);
      await sell(para, 10);
      await age(45);
      await sell(para, 4);

      final i = await of(para);
      expect(i.unitsSold, 4);
      expect(i.revenueSantim, 2000);
    });

    test('best sellers are ordered by what they brought in', () async {
      await receive(para, 500, 300);
      await receive(amox, 10, 9000, pack: box);
      await sell(para, 10); // 50.00
      await sell(amox, 1, pack: box); // 100.00

      final best =
          InsightsRepository.bestSellers(await insights.products(branchId));
      expect(best.map((i) => i.product.name).toList(),
          ['Amoxicillin 500mg capsule', 'Paracetamol 500mg tablet']);
    });
  });

  group('what to reorder', () {
    test('suggests a fast seller that is running out, in whole boxes',
        () async {
      await receive(amox, 10, 9000, pack: box); // 300
      // 290 sold in the window: about ten a day, ten left — one day of cover.
      await sell(amox, 290);

      final list =
          InsightsRepository.reorder(await insights.products(branchId));
      final s = list.single;
      expect(s.insight.onHand, 10);
      expect(s.insight.daysOfCover, 1);
      // Thirty days at that rate is 290; ten are there; 280 needed — ten boxes, since
      // nine and a third is not something a wholesaler sells.
      expect(s.suggestedBaseQty, 280);
      expect(s.pack?.name, 'box');
      expect(s.packs, 10);
    });

    test('includes what has already run out — that is the one losing sales',
        () async {
      await receive(para, 20, 300);
      await sell(para, 25); // oversold

      final s =
          InsightsRepository.reorder(await insights.products(branchId)).single;
      expect(s.insight.onHand, -5);
      // The shortfall is not ordered twice: it suggests the thirty days' worth.
      expect(s.suggestedBaseQty, 25);
      expect(s.pack, isNull);
    });

    test('leaves alone what has plenty', () async {
      await receive(para, 1000, 300);
      await sell(para, 30);
      expect(InsightsRepository.reorder(await insights.products(branchId)),
          isEmpty);
    });

    test('never suggests buying more of what nobody is buying', () async {
      // Two left and none sold: low, and not worth reordering.
      await receive(para, 2, 300);
      expect(InsightsRepository.reorder(await insights.products(branchId)),
          isEmpty);
    });

    test('puts the most urgent first', () async {
      await receive(para, 100, 300);
      await receive(amox, 10, 9000, pack: box);
      await sell(para, 90); // 10 left of 90/30d: 3 days
      await sell(amox, 299); // 1 left: 0 days

      final names =
          InsightsRepository.reorder(await insights.products(branchId))
              .map((s) => s.insight.product.name)
              .toList();
      expect(names, ['Amoxicillin 500mg capsule', 'Paracetamol 500mg tablet']);
    });
  });

  group('dead stock', () {
    test('is on the shelf and unsold for sixty days', () async {
      await receive(para, 100, 300);
      await sell(para, 5);
      await age(70);

      final dead =
          InsightsRepository.deadStock(await insights.products(branchId));
      expect(dead.single.product.name, 'Paracetamol 500mg tablet');
      expect(dead.single.daysSinceLastSale, greaterThanOrEqualTo(69));
    });

    test('stock received last week and not yet sold is new, not dead',
        () async {
      await receive(para, 100, 300);
      await age(7);
      expect(InsightsRepository.deadStock(await insights.products(branchId)),
          isEmpty);
    });

    test('never sold, and on the books for sixty days, is dead', () async {
      await receive(para, 100, 300);
      await age(61);
      expect(
          InsightsRepository.deadStock(await insights.products(branchId))
              .length,
          1);
    });

    test('something that sold out is not dead stock, whatever its history',
        () async {
      await receive(para, 5, 300);
      await sell(para, 5);
      await age(90);
      expect(InsightsRepository.deadStock(await insights.products(branchId)),
          isEmpty);
    });

    test('most money tied up first', () async {
      await receive(para, 10, 300); // 10 × 5.00
      await receive(amox, 10, 9000, pack: box); // 300 × 4.00
      await age(61);
      final dead =
          InsightsRepository.deadStock(await insights.products(branchId));
      expect(dead.first.product.name, 'Amoxicillin 500mg capsule');
    });
  });

  group('what to send back', () {
    String inDays(int n) {
      final d = DateTime.now().add(Duration(days: n));
      return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    }

    test('groups batches near expiry under the supplier they came from',
        () async {
      await receive(para, 100, 300,
          supplier: 'EPSS', lot: 'P1', expiry: inDays(20));
      await receive(amox, 2, 9000,
          pack: box, supplier: 'Zaf Pharma', lot: 'A1', expiry: inDays(40));
      // Far from expiry: not on the list.
      await receive(para, 50, 300,
          supplier: 'EPSS', lot: 'P2', expiry: inDays(400));

      final list = await insights.returns(branchId);
      expect(list.map((s) => s.supplier).toSet(), {'EPSS', 'Zaf Pharma'});

      final epss = list.firstWhere((s) => s.supplier == 'EPSS');
      expect(epss.batches.single.lotNo, 'P1');
      expect(epss.batches.single.qty, 100);
      expect(epss.batches.single.daysLeft, 20);
      // 100 tablets at 3.00.
      expect(epss.valueSantim, 30000);

      final zaf = list.firstWhere((s) => s.supplier == 'Zaf Pharma');
      // Two boxes at 90.00, counted as the 60 capsules on the shelf.
      expect(zaf.batches.single.qty, 60);
      expect(zaf.valueSantim, 18000);
    });

    test('values what is left, not what was delivered', () async {
      await receive(amox, 2, 9000, pack: box, lot: 'A1', expiry: inDays(30));
      await sell(amox, 1, pack: box);

      final batch = (await insights.returns(branchId)).single.batches.single;
      expect(batch.qty, 30);
      expect(batch.valueSantim, 9000);
    });

    test('keeps what has already expired, and marks it', () async {
      await receive(para, 10, 300, lot: 'OLD', expiry: inDays(400));
      // Receiving refuses a past date, so the batch is aged where it sits.
      await db.db.update('stock_batch', {'expiry_date': inDays(-3)});

      final batch = (await insights.returns(branchId)).single.batches.single;
      expect(batch.daysLeft, -3);
    });

    test('leaves out a batch that has sold through', () async {
      await receive(para, 10, 300, expiry: inDays(20));
      await sell(para, 10);
      expect(await insights.returns(branchId), isEmpty);
    });

    test('a batch this phone did not receive has no supplier it can name',
        () async {
      // Pulled from the server: received on another phone.
      await db.db.insert('stock_batch', {
        'id': 'other-phone-batch',
        'branch_id': branchId,
        'product_id': para.id,
        'lot_no': 'X9',
        'expiry_date': inDays(10),
        'qty_on_hand': 40,
      });
      await receive(amox, 1, 9000,
          pack: box, supplier: 'EPSS', expiry: inDays(30));

      final list = await insights.returns(branchId);
      // Named suppliers first; the unknown last, and not guessed at.
      expect(list.first.supplier, 'EPSS');
      expect(list.last.supplier, isNull);
      expect(list.last.batches.single.valueSantim, isNull);
      expect(list.last.valueSantim, 0);
    });
  });

  test('controlled substances are in none of it — their stock is the ledger\'s',
      () async {
    await db.db.insert('product', {
      'id': 'controlled-1',
      'name': 'Diazepam 5mg',
      'unit': 'tablet',
      'is_controlled': 1,
      'price_santim': 4000,
    });
    final all = await insights.products(branchId);
    expect(all.map((i) => i.product.name), isNot(contains('Diazepam 5mg')));
  });
}
