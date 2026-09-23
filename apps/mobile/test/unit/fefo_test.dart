import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/contracts/contracts.dart';
import 'package:pharmaet_mobile/data/catalog_repository.dart';
import 'package:pharmaet_mobile/data/local_db.dart';

import '../support/test_db.dart';

/// FEFO batch selection (AC-3.2) and the negative-stock policy (BR-3.2).
void main() {
  late LocalDb db;
  late Directory dir;
  late CatalogRepository catalog;

  const branchId = '01930000-0000-7000-8000-000000000002';
  const productId = '01930000-0000-7000-8000-00000000000a';

  StockBatchRef batch(String id, String expiry, int qty) => StockBatchRef(
        id: id,
        branchId: branchId,
        productId: productId,
        lotNo: 'LOT-$id',
        expiryDate: expiry,
        qtyOnHand: qty,
        changeSeq: 1,
        deletedAt: null,
      );

  Future<void> seed(List<StockBatchRef> batches) async {
    await catalog.applyPull(PullResponse(
      contractVersion: kContractVersion,
      cursor: 1,
      hasMore: false,
      products: const [],
      branches: const [],
      users: const [],
      stockBatches: batches,
      serverTime: DateTime.now().toUtc().toIso8601String(),
    ));
  }

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

  test('picks the batch that expires first, not the one received first',
      () async {
    // What costs a pharmacy money is stock dying on the shelf, which is exactly what happens
    // when the longest-dated box goes out first.
    await seed([
      batch('01930000-0000-7000-8000-0000000000b1', '2028-01-31', 50),
      batch('01930000-0000-7000-8000-0000000000b2', '2027-02-28', 5),
      batch('01930000-0000-7000-8000-0000000000b3', '2027-11-30', 20),
    ]);

    final selected = await catalog.fefoBatch(productId, branchId);
    expect(selected?.expiryDate, '2027-02-28');
  });

  test('skips an already-expired batch', () async {
    // Dispensing expired stock needs an explicit authorised override (E-4.2), which is
    // Phase 1. Until then the batch is simply not offered.
    await seed([
      batch('01930000-0000-7000-8000-0000000000b1', '2020-01-31', 50),
      batch('01930000-0000-7000-8000-0000000000b2', '2027-06-30', 10),
    ]);

    final selected = await catalog.fefoBatch(productId, branchId);
    expect(selected?.expiryDate, '2027-06-30');
  });

  test('returns null rather than throwing when nothing is on hand', () async {
    // A null batch must not stop a sale: the terminal may hold stock the server has not
    // told it about, and closing the counter over a number we know can be wrong is the one
    // outcome this product refuses (BR-3.2).
    final selected = await catalog.fefoBatch(productId, branchId);
    expect(selected, isNull);
  });

  test('ignores another branch\'s stock', () async {
    await seed(
        [batch('01930000-0000-7000-8000-0000000000b1', '2027-06-30', 10)]);
    final selected = await catalog.fefoBatch(productId, 'other-branch');
    expect(selected, isNull);
  });

  test('local stock may go negative — an oversell is recorded, not prevented',
      () async {
    await seed(
        [batch('01930000-0000-7000-8000-0000000000b1', '2027-06-30', 3)]);

    await catalog.decrementLocal(
      db.db,
      batchId: '01930000-0000-7000-8000-0000000000b1',
      qty: 8,
    );

    expect(await catalog.onHand(productId, branchId), -5);
  });
}
