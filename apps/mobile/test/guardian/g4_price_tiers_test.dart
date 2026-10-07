import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/contracts/contracts.dart';
import 'package:pharmaet_mobile/data/catalog_repository.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/data/outbox.dart';
import 'package:pharmaet_mobile/data/sale_repository.dart';
import 'package:pharmaet_mobile/ui/catalog_sheets.dart';

import '../support/test_db.dart';

/// G4 — PRICE TIERS, device half (FR-19, ADR-037; contract 1.8.0).
///
/// A pharmacy that supplies a clinic keeps two price lists. Once the till can ring a sale
/// up on either, three things have to hold on a phone with no network:
///
///   - **a wholesale sale charges the wholesale price of the unit sold** — the box's own
///     wholesale price, never the tablet's multiplied out;
///   - **where no wholesale price was set, the customer pays what everyone pays** — the
///     till never invents a discount, and never charges nothing;
///   - **a retail sale is exactly the sale it always was** — no new key on the wire, which
///     is all an older server has ever been taught to read (ADR-009).
void main() {
  late LocalDb db;
  late Directory dir;
  late Outbox outbox;
  late CatalogRepository catalog;
  late SaleRepository sales;

  const tenantId = '01930000-0000-7000-8000-000000000001';
  const branchId = '01930000-0000-7000-8000-000000000002';
  const cashierId = '01930000-0000-7000-8000-000000000003';
  const terminalId = '01930000-0000-7000-8000-000000000004';
  const productId = '01930000-0000-7000-8000-00000000000a';

  // The strip has no wholesale price; the box does.
  const strip = ProductPack(name: 'strip', size: 10, priceSantim: 3600);
  const box = ProductPack(
      name: 'box', size: 30, priceSantim: 10000, wholesalePriceSantim: 8500);

  const product = LocalProduct(
    id: productId,
    name: 'Amoxicillin 500mg',
    unit: 'capsule',
    isControlled: false,
    priceSantim: 400,
    wholesalePriceSantim: 330,
    packs: [strip, box],
  );

  setUp(() async {
    final opened = await openTestDb();
    db = opened.db;
    dir = opened.dir;
    outbox = Outbox(db);
    catalog = CatalogRepository(db);
    sales = SaleRepository(db, outbox, catalog);
  });

  tearDown(() async {
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<CommittedSale> sell(List<CartLine> lines, {bool wholesale = false}) =>
      sales.commitSale(
        lines: lines,
        tenantId: tenantId,
        branchId: branchId,
        cashierId: cashierId,
        terminalId: terminalId,
        wholesale: wholesale,
      );

  CartLine line(int qty, {ProductPack? pack, bool wholesale = false}) =>
      CartLine(
          product: product,
          qty: qty,
          batchId: null,
          pack: pack,
          wholesale: wholesale);

  group('a cart line on the wholesale list', () {
    test('loose, is the product\'s wholesale price', () {
      expect(line(10, wholesale: true).unitPriceSantim, 330);
      expect(line(10, wholesale: true).lineTotalSantim, 3300);
    });

    test('in a pack, is that pack\'s own wholesale price', () {
      final l = line(2, pack: box, wholesale: true);
      expect(l.unitPriceSantim, 8500);
      expect(l.lineTotalSantim, 17000);
      // Not thirty capsules at the loose wholesale price (9,900 a box).
      expect(l.unitPriceSantim, isNot(30 * 330));
      // The shelf does not care who the customer was.
      expect(l.baseQty, 60);
    });

    test('a pack with no wholesale price sells at what everyone pays', () {
      final l = line(1, pack: strip, wholesale: true);
      expect(l.unitPriceSantim, 3600);
      // Not derived from the loose wholesale price either (3,300): the owner set no
      // wholesale price on a strip, and the till does not guess one.
      expect(l.unitPriceSantim, isNot(10 * 330));
    });

    test('a product with no wholesale price sells at what everyone pays', () {
      const plain = LocalProduct(
          id: 'p2',
          name: 'Paracetamol',
          unit: 'tablet',
          isControlled: false,
          priceSantim: 500);
      final l =
          CartLine(product: plain, qty: 4, batchId: null, wholesale: true);
      expect(l.unitPriceSantim, 500);
      expect(l.lineTotalSantim, 2000);
      expect(plain.hasWholesalePrice, isFalse);
    });

    test('on a retail sale the wholesale prices are never used', () {
      expect(line(10).unitPriceSantim, 400);
      expect(line(2, pack: box).unitPriceSantim, 10000);
    });
  });

  group('committing a wholesale sale', () {
    test('stores the wholesale prices, an exact total, and the tier (G4)',
        () async {
      final sale = await sell(
          [line(10, wholesale: true), line(2, pack: box, wholesale: true)],
          wholesale: true);
      expect(sale.totalSantim, 3300 + 17000);

      final row = (await db.db.query('sale')).single;
      expect(row['price_tier'], 'wholesale');
      expect(row['total_santim'], 20300);
      final lines =
          await db.db.query('sale_line', orderBy: 'unit_price_santim');
      expect(lines.map((l) => l['unit_price_santim']), [330, 8500]);
      // qty × unit price, line by line, with nothing left over.
      for (final l in lines) {
        expect(l['line_total_santim'],
            (l['qty']! as int) * (l['unit_price_santim']! as int));
      }
    });

    test('says so on the wire, and the envelope accepts it', () async {
      await sell([line(2, pack: box, wholesale: true)], wholesale: true);

      final entry = (await outbox.pending()).single;
      expect(entry.payload['priceTier'], 'wholesale');
      final op = sales.toOperation(entry,
          tenantId: tenantId,
          branchId: branchId,
          actorId: cashierId,
          terminalId: terminalId);
      final wire = op.toJson()['payload'] as Map<String, dynamic>;
      expect(wire['priceTier'], 'wholesale');
      final sent =
          (wire['lines'] as List<dynamic>).single as Map<String, dynamic>;
      expect(sent['unitPriceSantim'], 8500);
      expect(sent['lineTotalSantim'], 17000);
    });

    test('a retail sale queues no tier key at all — what 1.7.0 sent (ADR-009)',
        () async {
      await sell([line(3)]);

      final entry = (await outbox.pending()).single;
      expect(entry.payload.containsKey('priceTier'), isFalse);
      expect((await db.db.query('sale')).single['price_tier'], isNull);
    });
  });

  group('the catalog on the device', () {
    PullResponse pullOf({int? wholesale, List<ProductPack>? packs}) =>
        PullResponse(
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
              wholesalePriceSantim: wholesale,
              packs: packs,
              changeSeq: 9,
            ),
          ],
          branches: const [],
          users: const [],
          stockBatches: const [],
          serverTime: '2026-10-07T08:00:00.000Z',
        );

    test('keeps the wholesale prices a pull delivers', () async {
      await catalog
          .applyPull(pullOf(wholesale: 330, packs: const [strip, box]));
      final pulled = (await catalog.products()).single;
      expect(pulled.wholesalePriceSantim, 330);
      expect(pulled.packs.last.wholesalePriceSantim, 8500);
      expect(pulled.packs.first.wholesalePriceSantim, isNull);
      expect(pulled.hasWholesalePrice, isTrue);
    });

    test('a server that predates tiers leaves one price for everybody',
        () async {
      await catalog.applyPull(pullOf());
      final pulled = (await catalog.products()).single;
      expect(pulled.wholesalePriceSantim, isNull);
      expect(pulled.hasWholesalePrice, isFalse);
    });

    test('removing the wholesale price on the server removes it here',
        () async {
      await catalog.applyPull(pullOf(wholesale: 330));
      await catalog.applyPull(pullOf());
      expect((await catalog.products()).single.wholesalePriceSantim, isNull);
    });

    test('a wholesale price only on a pack still counts as having one',
        () async {
      await catalog.applyPull(pullOf(packs: const [box]));
      expect((await catalog.products()).single.hasWholesalePrice, isTrue);
    });
  });

  group('the pack editor', () {
    List<ProductPack>? read(String wholesale) {
      final draft = PackDraft(
          name: 'box', size: '30', price: '100', wholesale: wholesale);
      final packs = readPacks([draft]);
      draft.dispose();
      return packs;
    }

    test('reads a typed wholesale price in santim', () {
      expect(read('85.5')!.single.wholesalePriceSantim, 8550);
    });

    test('left empty, the pack has one price', () {
      expect(read('')!.single.wholesalePriceSantim, isNull);
    });

    test('a mistyped wholesale price is refused, never saved as "none"', () {
      expect(read('8x'), isNull);
      expect(read('9.999'), isNull, reason: 'sub-santim');
    });

    test('shows an existing wholesale price for editing', () {
      final draft = PackDraft.of(box);
      expect(draft.wholesale.text, '85.00');
      draft.dispose();
    });
  });
}
