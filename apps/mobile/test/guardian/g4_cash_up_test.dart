import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/data/catalog_repository.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/data/outbox.dart';
import 'package:pharmaet_mobile/data/sale_repository.dart';
import 'package:pharmaet_mobile/data/shift_repository.dart';

import '../support/test_db.dart';

/// G4 — CASH-UP INTEGRITY, device half (FR-8, BR-8.2, AC-8.1).
///
/// Vision §2.1.1 calls per-shift cash reconciliation the owner's primary anti-shrinkage
/// control. It runs at close of trade, which in this market is frequently after the power
/// has gone — so every one of these tests runs with no network anywhere in sight, and the
/// ones that matter kill the database and reopen it.
void main() {
  late LocalDb db;
  late Directory dir;
  late Outbox outbox;
  late SaleRepository sales;
  late ShiftRepository shifts;

  const tenantId = '01930000-0000-7000-8000-000000000001';
  const branchId = '01930000-0000-7000-8000-000000000002';
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
    sales = SaleRepository(db, outbox, CatalogRepository(db));
    shifts = ShiftRepository(db, outbox);
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

  Future<void> killAndRestart() async {
    await db.close();
    final reopened = await openTestDb(reuse: dir);
    db = reopened.db;
    await wire();
  }

  Future<ActiveShift> openTill({int float = 20000}) => shifts.openShift(
        userId: cashierId,
        branchId: branchId,
        openingFloatSantim: float,
      );

  Future<void> sell(ActiveShift shift, {int qty = 1}) => sales.commitSale(
        lines: [CartLine(product: product, qty: qty, batchId: null)],
        tenantId: tenantId,
        branchId: branchId,
        cashierId: cashierId,
        terminalId: terminalId,
        shiftId: shift.id,
      ).then((_) {});

  test('expected cash is the opening float plus cash taken', () async {
    final shift = await openTill(float: 20000);
    await sell(shift, qty: 2); // 3000
    await sell(shift, qty: 1); // 1500

    final expected = await shifts.expectedCash(shift.id);
    expect(expected.openingFloatSantim, 20000);
    expect(expected.cashTakenSantim, 4500);
    expect(expected.expectedSantim, 24500);
    expect(expected.saleCount, 2);
  });

  test('a sale rung up with no till open does not reach any shift', () async {
    // It still commits — a missing shift must never stop the counter (BR-4.1) — but it
    // cannot honestly be attributed to a till session either.
    await sales.commitSale(
      lines: [CartLine(product: product, qty: 3, batchId: null)],
      tenantId: tenantId,
      branchId: branchId,
      cashierId: cashierId,
      terminalId: terminalId,
      shiftId: null,
    );

    final shift = await openTill(float: 1000);
    final expected = await shifts.expectedCash(shift.id);
    expect(expected.cashTakenSantim, 0);
    expect(expected.expectedSantim, 1000);
  });

  test('a shortfall is recorded, and the shift closes anyway', () async {
    // Blocking the cash-up on a discrepancy would teach people to fudge the count until the
    // screen let them through, which destroys the control (AC-8.1).
    final shift = await openTill(float: 20000);
    await sell(shift, qty: 2); // expected 23000

    final variance = await shifts.closeShiftWithCashUp(
      shift: shift,
      countedSantim: 22150,
      note: 'checking receipts',
    );

    expect(variance, -850);
    expect(await shifts.activeShift(cashierId), isNull);

    final recorded = (await shifts.recentCashUps()).single;
    expect(recorded['expected_santim'], 23000);
    expect(recorded['counted_santim'], 22150);
    expect(recorded['variance_santim'], -850);
    expect(recorded['note'], 'checking receipts');
  });

  test('an overage is recorded too — cash appearing is also a signal',
      () async {
    final shift = await openTill(float: 10000);
    expect(
        await shifts.closeShiftWithCashUp(shift: shift, countedSantim: 10250),
        250);
  });

  test('a balanced till records a zero variance rather than nothing', () async {
    // "No record" and "no discrepancy" must not look the same in the evidence.
    final shift = await openTill(float: 5000);
    expect(await shifts.closeShiftWithCashUp(shift: shift, countedSantim: 5000),
        0);
    expect((await shifts.recentCashUps()).single['variance_santim'], 0);
  });

  test('the cash-up and the shift close survive the app being killed',
      () async {
    final shift = await openTill(float: 20000);
    await sell(shift, qty: 2);
    await shifts.closeShiftWithCashUp(shift: shift, countedSantim: 22000);

    final queuedBefore = await outbox.depth();
    await killAndRestart();

    expect(await outbox.depth(), queuedBefore);
    expect(await shifts.activeShift(cashierId), isNull);
    expect((await shifts.recentCashUps()).single['variance_santim'], -1000);
  });

  test('the shift close is queued before the cash-up that depends on it',
      () async {
    // The server refuses a cash-up whose shift has not arrived, so order is not cosmetic.
    // terminal_seq is what carries it across the wire.
    final shift = await openTill();
    await shifts.closeShiftWithCashUp(shift: shift, countedSantim: 20000);

    final pending = await outbox.pending();
    final types = pending.map((e) => e.entityType).toList();
    expect(types, ['shift', 'shift', 'cash_up']);
    final seqs = pending.map((e) => e.terminalSeq).toList();
    expect(seqs, [...seqs]..sort());
  });

  test('opening a till twice returns the same shift, never a second one',
      () async {
    // Two open tills for one person split the expected figure and neither reconciles.
    final first = await openTill();
    final second = await openTill();
    expect(second.id, first.id);
  });

  test('a cash-up is queued as its own operation, not folded into the shift',
      () async {
    final shift = await openTill();
    await shifts.closeShiftWithCashUp(
        shift: shift, countedSantim: 19000, note: 'short');

    final cashUp =
        (await outbox.pending()).firstWhere((e) => e.entityType == 'cash_up');
    expect(cashUp.payload['shiftId'], shift.id);
    expect(cashUp.payload['varianceSantim'], -1000);
    expect(cashUp.payload['countedSantim'], isA<int>());
    expect(cashUp.payload['expectedSantim'], isA<int>());
  });

  test('variance always equals counted minus expected, across many values',
      () async {
    // The server and the database both assert this; a client that computed it differently
    // would have its cash-ups rejected, and a rejected cash-up is a till nobody reconciled.
    for (final (float, taken, counted) in [
      (0, 0, 0),
      (20000, 1500, 21500),
      (1, 1, 0),
      (999999, 1, 500000),
    ]) {
      final shift = await openTill(float: float);
      if (taken > 0) {
        await sales.commitSale(
          lines: [
            CartLine(
              product: LocalProduct(
                id: product.id,
                name: product.name,
                unit: product.unit,
                isControlled: false,
                priceSantim: taken,
              ),
              qty: 1,
              batchId: null,
            ),
          ],
          tenantId: tenantId,
          branchId: branchId,
          cashierId: cashierId,
          terminalId: terminalId,
          shiftId: shift.id,
        );
      }
      final variance = await shifts.closeShiftWithCashUp(
          shift: shift, countedSantim: counted);
      expect(variance, counted - (float + taken));
    }
  });
}
