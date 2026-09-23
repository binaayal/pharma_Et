import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/contracts/contracts.dart';
import 'package:pharmaet_mobile/data/catalog_repository.dart';
import 'package:pharmaet_mobile/data/inventory_repository.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/data/outbox.dart';
import 'package:pharmaet_mobile/data/sale_repository.dart';

import '../support/test_db.dart';

/// G5 — RECEIVING AND RECONCILING STOCK, device half (FR-7, FR-3, BR-3.2).
///
/// Both happen at the counter and both must work with no network: stock arrives when the
/// wholesaler's van arrives, and a shelf gets counted when somebody notices the number is
/// wrong. An app that made either wait for connectivity would simply not be used for them,
/// and the stock figures would rot.
void main() {
  late LocalDb db;
  late Directory dir;
  late Outbox outbox;
  late CatalogRepository catalog;
  late InventoryRepository inventory;
  late SaleRepository sales;

  const branchId = '01930000-0000-7000-8000-000000000002';
  const tenantId = '01930000-0000-7000-8000-000000000001';
  const cashierId = '01930000-0000-7000-8000-000000000003';
  const terminalId = '01930000-0000-7000-8000-000000000004';

  const product = LocalProduct(
    id: '01930000-0000-7000-8000-00000000000a',
    name: 'Paracetamol 500mg',
    unit: 'tablet',
    isControlled: false,
    priceSantim: 1500,
  );

  Future<void> wire() async {
    outbox = Outbox(db);
    catalog = CatalogRepository(db);
    inventory = InventoryRepository(db, outbox, catalog);
    sales = SaleRepository(db, outbox, catalog);
  }

  setUp(() async {
    final opened = await openTestDb();
    db = opened.db;
    dir = opened.dir;
    await wire();
  });

  tearDown(() async {
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<String> receive({int qty = 50, String lot = 'LOT-1'}) =>
      inventory.commitReceipt(
        lines: [
          ReceiptLine(
            product: product,
            lotNo: lot,
            expiryDate: '2027-12-31',
            qty: qty,
            costSantim: 800,
          ),
        ],
        supplierName: 'Test Wholesaler',
        branchId: branchId,
      );

  group('receiving stock', () {
    test('credits the shelf immediately, with no network', () async {
      await receive(qty: 50);
      // Available to sell at once. Waiting for a round trip would mean a delivery could not
      // be sold during an outage, which is when deliveries most often arrive.
      expect(await catalog.onHand(product.id, branchId), 50);
    });

    test('queues the receipt for sync', () async {
      await receive();
      final entry = (await outbox.pending()).single;
      expect(entry.entityType, 'goods_receipt');
      expect(entry.payload['supplierName'], 'Test Wholesaler');
      expect((entry.payload['lines'] as List).length, 1);
    });

    test(
        'the line id doubles as the batch id, so the batch is addressable offline',
        () async {
      // ADR-006: the client mints the id, so the batch exists fully before the server has
      // ever seen it — which is what lets FEFO pick it in the very next sale.
      await receive();
      final entry = (await outbox.pending()).single;
      final lines =
          (entry.payload['lines'] as List).cast<Map<String, dynamic>>();
      final lineId = lines.first['id'] as String;
      final batch = await catalog.fefoBatch(product.id, branchId);
      expect(batch?.id, lineId);
    });

    test('a second delivery of the same lot adds to it rather than duplicating',
        () async {
      await receive(qty: 30, lot: 'LOT-A');
      await receive(qty: 20, lot: 'LOT-A');
      expect(await catalog.onHand(product.id, branchId), 50);
      expect((await inventory.batchesNeedingAttention(branchId)).length, 1);
    });

    test('survives the app being killed', () async {
      await receive(qty: 40);
      await db.close();
      final reopened = await openTestDb(reuse: dir);
      db = reopened.db;
      await wire();

      expect(await outbox.depth(), 1);
      expect(await catalog.onHand(product.id, branchId), 40);
    });

    test('builds a valid envelope from the generated contract types', () async {
      await receive();
      final entry = (await outbox.pending()).single;
      final op = inventory.toOperation(
        entry,
        tenantId: tenantId,
        branchId: branchId,
        actorId: cashierId,
        terminalId: terminalId,
      );
      final reparsed = Operation.fromJson(op.toJson());
      expect(reparsed, isA<OperationGoodsReceipt>());
    });
  });

  group('reconciling a count', () {
    test('the shelf wins: what was counted becomes the count', () async {
      await receive(qty: 50);
      final batch = (await inventory.batchesNeedingAttention(branchId)).single;

      final delta = await inventory.adjustStock(
        batch: batch,
        branchId: branchId,
        countedQty: 47,
        reason: AdjustmentReason.recount,
      );

      expect(delta, -3);
      expect(await catalog.onHand(product.id, branchId), 47);
    });

    test('resolves an oversell — the case BR-3.2 promises can be fixed',
        () async {
      await receive(qty: 5);
      final batch = (await inventory.batchesNeedingAttention(branchId)).single;
      await sales.commitSale(
        lines: [CartLine(product: product, qty: 9, batchId: batch.id)],
        tenantId: tenantId,
        branchId: branchId,
        cashierId: cashierId,
        terminalId: terminalId,
      );
      expect(await catalog.onHand(product.id, branchId), -4);

      final reloaded =
          (await inventory.batchesNeedingAttention(branchId)).single;
      await inventory.adjustStock(
        batch: reloaded,
        branchId: branchId,
        countedQty: 2,
        reason: AdjustmentReason.recount,
      );

      expect(await catalog.onHand(product.id, branchId), 2);
    });

    test('sends a delta, never an absolute', () async {
      // The server may already know about sales this terminal has not sent. A delta
      // composes with them; "set it to 47" would silently discard them.
      await receive(qty: 50);
      final batch = (await inventory.batchesNeedingAttention(branchId)).single;
      await inventory.adjustStock(
        batch: batch,
        branchId: branchId,
        countedQty: 47,
        reason: AdjustmentReason.recount,
      );

      final entry = (await outbox.pending())
          .firstWhere((e) => e.entityType == 'stock_adjustment');
      expect(entry.payload['delta'], -3);
      expect(entry.payload['previousQtyOnHand'], 50);
      expect(entry.payload.containsKey('qtyOnHand'), isFalse);
    });

    test('refuses a reason that needs a note without one', () async {
      await receive(qty: 50);
      final batch = (await inventory.batchesNeedingAttention(branchId)).single;
      expect(
        () => inventory.adjustStock(
          batch: batch,
          branchId: branchId,
          countedQty: 45,
          reason: AdjustmentReason.theftOrLoss,
        ),
        throwsArgumentError,
      );
      // And nothing was written — a refused correction must not half-apply.
      expect(await catalog.onHand(product.id, branchId), 50);
      expect(await outbox.depth(), 1);
    });

    test('refuses a no-op count', () async {
      await receive(qty: 50);
      final batch = (await inventory.batchesNeedingAttention(branchId)).single;
      expect(
        () => inventory.adjustStock(
          batch: batch,
          branchId: branchId,
          countedQty: 50,
          reason: AdjustmentReason.recount,
        ),
        throwsArgumentError,
      );
    });

    test('lists oversold batches first, because the count itself is in doubt',
        () async {
      await receive(qty: 5, lot: 'LOT-NEG');
      await receive(qty: 50, lot: 'LOT-OK');
      final negative = (await inventory.batchesNeedingAttention(branchId))
          .firstWhere((b) => b.lotNo == 'LOT-NEG');
      await sales.commitSale(
        lines: [CartLine(product: product, qty: 8, batchId: negative.id)],
        tenantId: tenantId,
        branchId: branchId,
        cashierId: cashierId,
        terminalId: terminalId,
      );

      final ordered = await inventory.batchesNeedingAttention(branchId);
      expect(ordered.first.qtyOnHand, lessThan(0));
    });

    test('the correction survives the app being killed', () async {
      await receive(qty: 50);
      final batch = (await inventory.batchesNeedingAttention(branchId)).single;
      await inventory.adjustStock(
        batch: batch,
        branchId: branchId,
        countedQty: 44,
        reason: AdjustmentReason.damage,
        note: 'crushed in transit',
      );

      await db.close();
      final reopened = await openTestDb(reuse: dir);
      db = reopened.db;
      await wire();

      expect(await catalog.onHand(product.id, branchId), 44);
      final entry = (await outbox.pending())
          .firstWhere((e) => e.entityType == 'stock_adjustment');
      expect(entry.payload['note'], 'crushed in transit');
    });
  });
}
