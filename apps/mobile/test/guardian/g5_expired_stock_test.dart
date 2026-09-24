import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/core/permissions.dart';
import 'package:pharmaet_mobile/data/catalog_repository.dart';
import 'package:pharmaet_mobile/data/local_db.dart';

import '../support/test_db.dart';

/// G5 — EXPIRED STOCK IS FOUND, NOT HIDDEN (E-4.2, ADR-020).
///
/// FEFO excludes expired batches from *selection*, which is right. What was wrong was that
/// nothing then looked for them: the terminal offered no batch, and to the person at the
/// counter that reads as "there is no stock" rather than "the only stock here is expired".
/// They reach for the box anyway, because the box is on the shelf.
///
/// The warning is the control. These tests defend the two facts it rests on — that expired
/// stock is found when there is nothing else, and that the matrix decides who may authorise
/// dispensing it.
void main() {
  late LocalDb db;
  late Directory dir;
  late CatalogRepository catalog;

  const branchId = '01930000-0000-7000-8000-000000000002';
  const productId = '01930000-0000-7000-8000-00000000000a';

  Future<void> addBatch(String id, String expiry, {int qty = 10}) =>
      db.db.insert('stock_batch', {
        'id': id,
        'branch_id': branchId,
        'product_id': productId,
        'lot_no': 'LOT-$id',
        'expiry_date': expiry,
        'qty_on_hand': qty,
        'deleted': 0,
      });

  String daysFromNow(int days) => DateTime.now()
      .toUtc()
      .add(Duration(days: days))
      .toIso8601String()
      .substring(0, 10);

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

  group('finding it', () {
    test('an expired batch is never selected while anything is in date',
        () async {
      await addBatch('a', daysFromNow(-30));
      await addBatch('b', daysFromNow(60));

      // FEFO must not reach for the expired box just because it expires soonest. "First to
      // expire" means first among the sellable.
      final picked = await catalog.fefoBatch(productId, branchId);
      expect(picked!.id, 'b');
    });

    test('and is found when there is nothing else', () async {
      await addBatch('a', daysFromNow(-30));

      expect(await catalog.fefoBatch(productId, branchId), isNull);
      final fallback = await catalog.expiredFallbackBatch(productId, branchId);
      expect(fallback, isNotNull);
      expect(fallback!.id, 'a');
    });

    test('nothing is invented when the shelf is simply empty', () async {
      // "No stock" and "only expired stock" must stay distinguishable, or the warning would
      // fire on an empty shelf and stop meaning anything.
      expect(await catalog.fefoBatch(productId, branchId), isNull);
      expect(await catalog.expiredFallbackBatch(productId, branchId), isNull);
    });

    test('a batch expiring today is in date, not expired', () async {
      await addBatch('a', daysFromNow(0));

      // The boundary. `expiry_date` is a calendar date: a box stamped with today is sellable
      // today, and warning about it would train people to dismiss the warning.
      expect((await catalog.fefoBatch(productId, branchId))!.id, 'a');
      expect(await catalog.expiredFallbackBatch(productId, branchId), isNull);
    });

    test('an expired batch with nothing left on it is not offered', () async {
      await addBatch('a', daysFromNow(-30), qty: 0);

      // There is no box. Warning about a lot that is expired *and* empty would be a false
      // alarm, and false alarms are how real ones get ignored.
      expect(await catalog.expiredFallbackBatch(productId, branchId), isNull);
    });

    test('of several expired lots it offers the least stale', () async {
      await addBatch('old', daysFromNow(-200));
      await addBatch('recent', daysFromNow(-2));

      // Of a bad set of options, the least bad — and the box a pharmacist would reach for if
      // they were choosing deliberately.
      final fallback = await catalog.expiredFallbackBatch(productId, branchId);
      expect(fallback!.id, 'recent');
    });
  });

  group('who may authorise it', () {
    test('an owner and a branch manager may; a cashier may not', () {
      // E-4.2 asks for an "authorized role", and the FR-2 matrix is where this system says
      // what that means — rather than a special case buried in the POS screen.
      expect('owner'.can(Capability.expiryOverride), isTrue);
      expect('branch_manager'.can(Capability.expiryOverride), isTrue);
      expect('cashier'.can(Capability.expiryOverride), isFalse);
    });

    test('a cashier can still sell — only the attribution is gated', () {
      // The distinction the whole ADR rests on. Refusing the sale would not stop the box
      // leaving the shelf; it would only stop the pharmacy trading (NFR-1.2).
      expect('cashier'.can(Capability.saleCreate), isTrue);
      expect('cashier'.can(Capability.expiryOverride), isFalse);
    });
  });
}
