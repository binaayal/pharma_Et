import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/contracts/contracts.dart';
import 'package:pharmaet_mobile/core/gs1.dart';
import 'package:pharmaet_mobile/data/catalog_repository.dart';
import 'package:pharmaet_mobile/data/local_db.dart';

import '../support/test_db.dart';

/// G2 — BARCODES REACH THE TILL AND STAY THERE, device half (FR-13, ADR-031).
///
/// A scan is matched against the catalogue on the phone, with no network. So the links have
/// to arrive by pull, survive a restart, and still be what the scanner's reading is compared
/// with — in one spelling.
void main() {
  late LocalDb db;
  late Directory dir;
  late CatalogRepository catalog;

  const productId = '01930000-0000-7000-8000-00000000000a';

  setUp(() async {
    final opened = await openTestDb();
    db = opened.db;
    dir = opened.dir;
    catalog = CatalogRepository(db);
  });

  tearDown(() async {
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  PullResponse pullOf(List<String>? barcodes, {int seq = 9}) => PullResponse(
        contractVersion: kContractVersion,
        cursor: seq,
        hasMore: false,
        products: [
          ProductRef(
            id: productId,
            name: 'Paracetamol 500mg tablet',
            unit: 'tablet',
            isControlled: false,
            currentPriceSantim: 500,
            barcodes: barcodes,
            changeSeq: seq,
          ),
        ],
        branches: const [],
        users: const [],
        stockBatches: const [],
        serverTime: '2026-10-07T08:00:00.000Z',
      );

  test('a pulled link is what a scan of the box is compared with', () async {
    await catalog.applyPull(pullOf(const ['06291100080014']));
    final product = (await catalog.products()).single;

    // Both codes on the same box resolve to the stored link.
    expect(product.barcodes, contains(parseScan('6291100080014')!.barcode));
    expect(product.barcodes,
        contains(parseScan('010629110008001417271231')!.barcode));
  });

  test('links survive the app being closed', () async {
    await catalog.applyPull(pullOf(const ['06291100080014', 'SHELF-0042']));
    await db.close();

    final reopened = await openTestDb(reuse: dir);
    db = reopened.db;
    final product = (await CatalogRepository(db).products()).single;
    expect(product.barcodes, ['06291100080014', 'SHELF-0042']);
  });

  test('unlinking on the server unlinks here on the next pull', () async {
    await catalog.applyPull(pullOf(const ['06291100080014']));
    await catalog.applyPull(pullOf(const [], seq: 10));
    expect((await catalog.products()).single.barcodes, isEmpty);
  });

  test('a server that predates barcodes leaves the product found by name',
      () async {
    // `barcodes` absent on the wire — a 1.5.0 server during a staggered rollout.
    await catalog.applyPull(pullOf(null));
    final product = (await catalog.products()).single;
    expect(product.barcodes, isEmpty);
    expect(product.name, 'Paracetamol 500mg tablet');
  });

  test('an unreadable link list never hides the product', () {
    expect(decodeBarcodes(null), isEmpty);
    expect(decodeBarcodes('not json'), isEmpty);
    expect(decodeBarcodes('{"a":1}'), isEmpty);
    expect(decodeBarcodes('["06291100080014", 7, null]'), ['06291100080014']);
  });
}
