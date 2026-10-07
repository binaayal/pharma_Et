import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/contracts/contracts.dart';
import 'package:pharmaet_mobile/data/catalog_repository.dart';
import 'package:pharmaet_mobile/data/inventory_repository.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/data/outbox.dart';
import 'package:pharmaet_mobile/data/sale_repository.dart';
import 'package:pharmaet_mobile/ui/catalog_sheets.dart';

import '../support/test_db.dart';

/// G4 / G5 — SELL UNITS, device half (FR-11, ADR-030; contract 1.5.0).
///
/// A pharmacy buys a box and sells a strip. Once a line can be rung up in a pack, two
/// things have to stay true at the same time, on a phone with no network:
///
///   - **the money is exact in the unit sold** — two boxes at the box price, with no
///     tablet price invented by division (G4);
///   - **the shelf moves in base units** — those two boxes of thirty take sixty off the
///     batch, so the count the owner trusts is still the count of tablets (G5).
///
/// And a sale with no pack must leave the till exactly as it did before packs existed,
/// because that is the only thing an older server has ever been taught to read (ADR-009).
void main() {
  late LocalDb db;
  late Directory dir;
  late Outbox outbox;
  late CatalogRepository catalog;
  late InventoryRepository inventory;
  late SaleRepository sales;

  const tenantId = '01930000-0000-7000-8000-000000000001';
  const branchId = '01930000-0000-7000-8000-000000000002';
  const cashierId = '01930000-0000-7000-8000-000000000003';
  const terminalId = '01930000-0000-7000-8000-000000000004';
  const productId = '01930000-0000-7000-8000-00000000000a';

  const strip = ProductPack(name: 'strip', size: 10, priceSantim: 3600);
  // 100.00 for thirty. No whole number of santim per capsule multiplies to this.
  const box = ProductPack(name: 'box', size: 30, priceSantim: 10000);

  const product = LocalProduct(
    id: productId,
    name: 'Amoxicillin 500mg',
    unit: 'capsule',
    isControlled: false,
    priceSantim: 400,
    packs: [strip, box],
  );

  setUp(() async {
    final opened = await openTestDb();
    db = opened.db;
    dir = opened.dir;
    outbox = Outbox(db);
    catalog = CatalogRepository(db);
    inventory = InventoryRepository(db, outbox, catalog);
    sales = SaleRepository(db, outbox, catalog);
  });

  tearDown(() async {
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<CommittedSale> sell(List<CartLine> lines) => sales.commitSale(
        lines: lines,
        tenantId: tenantId,
        branchId: branchId,
        cashierId: cashierId,
        terminalId: terminalId,
      );

  /// Puts [qty] capsules on the shelf and returns the batch FEFO will pick.
  Future<LocalBatch> stock(int qty) async {
    await inventory.commitReceipt(
      lines: [
        ReceiptLine(
            product: product,
            lotNo: 'LOT-1',
            expiryDate: '2030-12-31',
            qty: qty,
            costSantim: 250),
      ],
      supplierName: 'EPSS',
      branchId: branchId,
    );
    return (await catalog.fefoBatch(productId, branchId))!;
  }

  Future<Map<String, dynamic>> queuedLine(String entityType) async {
    final entry =
        (await outbox.pending()).lastWhere((e) => e.entityType == entityType);
    return (entry.payload['lines'] as List<dynamic>).single
        as Map<String, dynamic>;
  }

  group('a cart line in a pack', () {
    test('is priced at the pack\'s own price, never the base price multiplied',
        () {
      final line = CartLine(product: product, qty: 2, batchId: null, pack: box);
      expect(line.unitPriceSantim, 10000);
      expect(line.lineTotalSantim, 20000);
      // Thirty capsules at the loose price would be 12,000. The box is cheaper, and the
      // till must charge what the owner set, not what arithmetic suggests.
      expect(line.lineTotalSantim, isNot(2 * 30 * product.priceSantim));
      expect(line.baseQty, 60);
      expect(line.unitName, 'box');
    });

    test('without a pack is exactly the line it always was', () {
      final line = CartLine(product: product, qty: 3, batchId: null);
      expect(line.unitPriceSantim, 400);
      expect(line.lineTotalSantim, 1200);
      expect(line.baseQty, 3);
      expect(line.unitName, 'capsule');
    });
  });

  group('committing a sale by the pack', () {
    test('stores the pack count, the pack price and an exact total (G4)',
        () async {
      final sale = await sell(
          [CartLine(product: product, qty: 2, batchId: null, pack: box)]);
      expect(sale.totalSantim, 20000);

      final row = (await db.db.query('sale_line')).single;
      expect(row['qty'], 2);
      expect(row['unit_price_santim'], 10000);
      expect(row['line_total_santim'], 20000);
      expect(row['pack_size'], 30);
      expect(row['pack_name'], 'box');
      // The invariant the server and Postgres both assert, in the unit sold.
      expect(row['line_total_santim'],
          (row['qty']! as int) * (row['unit_price_santim']! as int));
    });

    test('takes qty × pack size off the batch, in base units (G5)', () async {
      final batch = await stock(100);
      await sell([
        CartLine(product: product, qty: 2, batchId: batch.id, pack: box),
        // Same batch again, loose — a box and a few over is an ordinary sale.
      ]);
      expect(await catalog.onHand(productId, branchId), 40);

      await sell(
          [CartLine(product: product, qty: 1, batchId: batch.id, pack: strip)]);
      await sell([CartLine(product: product, qty: 4, batchId: batch.id)]);
      expect(await catalog.onHand(productId, branchId), 26);
    });

    test('oversells by the box rather than refusing the sale (BR-3.2)',
        () async {
      final batch = await stock(10);
      final sale = await sell(
          [CartLine(product: product, qty: 1, batchId: batch.id, pack: box)]);

      expect(sale.totalSantim, 10000);
      expect(await catalog.onHand(productId, branchId), -20);
      expect((await catalog.attention(branchId)).negative, 1);
    });

    test('queues the pack on the wire, and the envelope accepts it', () async {
      await sell(
          [CartLine(product: product, qty: 2, batchId: null, pack: box)]);

      final line = await queuedLine('sale');
      expect(line['qty'], 2);
      expect(line['unitPriceSantim'], 10000);
      expect(line['lineTotalSantim'], 20000);
      expect(line['packSize'], 30);
      expect(line['packName'], 'box');

      final entry = (await outbox.pending()).single;
      final op = sales.toOperation(entry,
          tenantId: tenantId,
          branchId: branchId,
          actorId: cashierId,
          terminalId: terminalId);
      final wire = op.toJson()['payload'] as Map<String, dynamic>;
      final sent =
          (wire['lines'] as List<dynamic>).single as Map<String, dynamic>;
      expect(sent['packSize'], 30);
      expect(sent['packName'], 'box');
    });

    test('a loose sale queues no pack key at all — what 1.4.0 sent (ADR-009)',
        () async {
      await sell([CartLine(product: product, qty: 3, batchId: null)]);

      final line = await queuedLine('sale');
      expect(line.containsKey('packSize'), isFalse);
      expect(line.containsKey('packName'), isFalse);
      expect(line['qty'], 3);
      expect(line['unitPriceSantim'], 400);

      final row = (await db.db.query('sale_line')).single;
      expect(row['pack_size'], isNull);
      expect(row['pack_name'], isNull);
    });

    test('the receipt reads the pack from the line, not from the product',
        () async {
      // The product is not even in the local catalog here. A receipt reprinted after the
      // packs were edited — or the product removed — must still say what was handed over.
      final sale = await sell([
        CartLine(product: product, qty: 2, batchId: null, pack: box),
      ]);
      final lines = await sales.linesOf(sale.saleId);
      expect(lines.single.qty, 2);
      expect(lines.single.packName, 'box');
      expect(lines.single.lineTotalSantim, 20000);
    });
  });

  group('receiving by the pack', () {
    Future<void> receiveBoxes(int boxes) => inventory.commitReceipt(
          lines: [
            ReceiptLine(
                product: product,
                lotNo: 'LOT-BOX',
                expiryDate: '2030-12-31',
                qty: boxes,
                costSantim: 9000,
                pack: box),
          ],
          supplierName: 'EPSS',
          branchId: branchId,
        );

    test('credits the shelf qty × pack size', () async {
      await receiveBoxes(5);
      expect(await catalog.onHand(productId, branchId), 150);
    });

    test('keeps the invoice line as written: five boxes at the box cost',
        () async {
      await receiveBoxes(5);

      final row = (await db.db.query('goods_receipt_line')).single;
      expect(row['qty'], 5);
      expect(row['cost_santim'], 9000);
      expect(row['pack_size'], 30);

      final line = await queuedLine('goods_receipt');
      expect(line['qty'], 5);
      expect(line['costSantim'], 9000);
      expect(line['packSize'], 30);
    });

    test('a loose receipt queues no pack key', () async {
      await stock(40);
      final line = await queuedLine('goods_receipt');
      expect(line.containsKey('packSize'), isFalse);
      expect(await catalog.onHand(productId, branchId), 40);
    });

    test('the movement trail is in base units for both directions', () async {
      await receiveBoxes(2);
      final batch = (await catalog.fefoBatch(productId, branchId))!;
      await sell(
          [CartLine(product: product, qty: 1, batchId: batch.id, pack: strip)]);

      final moves = await catalog.movements(productId, branchId);
      expect(moves.firstWhere((m) => m.kind == 'receipt').delta, 60);
      expect(moves.firstWhere((m) => m.kind == 'sale').delta, -10);
    });
  });

  group('the catalog on the device', () {
    PullResponse pullOf(List<ProductPack>? packs) => PullResponse(
          contractVersion: kContractVersion,
          cursor: 9,
          hasMore: false,
          products: [
            ProductRef(
              id: productId,
              name: 'Amoxicillin 500mg',
              unit: 'capsule',
              isControlled: false,
              currentPriceSantim: 400,
              packs: packs,
              changeSeq: 9,
            ),
          ],
          branches: const [],
          users: const [],
          stockBatches: const [],
          serverTime: '2026-10-07T08:00:00.000Z',
        );

    test('keeps the packs a pull delivers, smallest first', () async {
      await catalog.applyPull(pullOf(const [box, strip]));
      final pulled = (await catalog.products()).single;
      expect(pulled.packs.map((p) => p.name), ['strip', 'box']);
      expect(pulled.packs.last.priceSantim, 10000);
    });

    test('a server that predates packs leaves the product sellable loose',
        () async {
      // `packs` absent on the wire — a 1.4.0 server during a staggered rollout.
      await catalog.applyPull(pullOf(null));
      expect((await catalog.products()).single.packs, isEmpty);
    });

    test('clearing the packs on the server clears them here', () async {
      await catalog.applyPull(pullOf(const [box]));
      await catalog.applyPull(pullOf(const []));
      expect((await catalog.products()).single.packs, isEmpty);
    });

    test('an unreadable pack list never takes the medicine off the counter',
        () {
      expect(decodePacks(null), isEmpty);
      expect(decodePacks(''), isEmpty);
      expect(decodePacks('not json'), isEmpty);
      expect(decodePacks('{"name":"box"}'), isEmpty);
      // A pack of one is the base unit, and is dropped rather than offered twice.
      expect(
          decodePacks('[{"name":"one","size":1,"priceSantim":400}]'), isEmpty);
    });

    test('says a count the way a shelf is counted, without changing it', () {
      expect(describeQuantity(74, product), '2 box + 14');
      expect(describeQuantity(60, product), '2 box');
      expect(describeQuantity(29, product), '29');
      expect(describeQuantity(-5, product), '-5');
      const plain = LocalProduct(
          id: 'x',
          name: 'x',
          unit: 'bottle',
          isControlled: false,
          priceSantim: 1);
      expect(describeQuantity(74, plain), '74');
    });
  });

  group('the pack editor', () {
    List<ProductPack>? read(List<(String, String, String)> rows) {
      final drafts = [
        for (final (name, size, price) in rows)
          PackDraft(name: name, size: size, price: price),
      ];
      final packs = readPacks(drafts);
      for (final draft in drafts) {
        draft.dispose();
      }
      return packs;
    }

    test('reads typed rows into packs, in santim, smallest first', () {
      final packs = read([('box', '30', '100'), ('strip', '10', '36.5')])!;
      expect(packs.map((p) => p.name), ['strip', 'box']);
      // 36.5 birr is 3650 santim — parsed as text, never through a double (G4).
      expect(packs.first.priceSantim, 3650);
      expect(packs.last.priceSantim, 10000);
    });

    test('ignores a row nobody typed in', () {
      expect(read([('', '', ''), ('box', '30', '100')])!.length, 1);
      expect(read([('', '', '')]), isEmpty);
    });

    test('refuses what the server would refuse', () {
      expect(read([('box', '1', '100')]), isNull, reason: 'a pack of one');
      expect(read([('box', '0', '100')]), isNull);
      expect(read([('box', '2.5', '100')]), isNull,
          reason: 'a fractional pack');
      expect(read([('box', '30', '')]), isNull, reason: 'no price');
      expect(read([('box', '30', '9.999')]), isNull, reason: 'sub-santim');
      expect(read([('', '30', '100')]), isNull, reason: 'no name');
      expect(read([('box', '30', '100'), ('Box', '10', '40')]), isNull,
          reason: 'two packs with one name');
      expect(read([('box', '30', '100'), ('carton', '30', '95')]), isNull,
          reason: 'two packs of one size');
      expect(read([('box', '100001', '1')]), isNull,
          reason: 'beyond the bound');
    });
  });
}
