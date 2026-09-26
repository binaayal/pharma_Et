import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/core/compliance.dart';
import 'package:pharmaet_mobile/data/catalog_repository.dart';
import 'package:pharmaet_mobile/data/controlled_repository.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/data/outbox.dart';
import 'package:pharmaet_mobile/data/shift_repository.dart';

import '../support/test_db.dart';

/// G5 — controlled dispensing at the till (FR-4 §4a, BR-4.2; ADR-024).
///
/// The rules run on the device so they hold with no network (docs/04 §6.4). BR-4.2: a
/// violation is blocked, never warned — so every case here asserts that nothing was written.
void main() {
  late LocalDb db;
  late Directory dir;
  late ControlledRepository controlled;
  late ShiftRepository shifts;
  late Outbox outbox;

  const diazepam = LocalProduct(
      id: '01930000-0000-7000-8000-0000000000d1',
      name: 'Diazepam 5mg',
      unit: 'tablet',
      isControlled: true,
      priceSantim: 1200);
  const lorazepam = LocalProduct(
      id: '01930000-0000-7000-8000-0000000000d2',
      name: 'Lorazepam 1mg',
      unit: 'tablet',
      isControlled: true,
      priceSantim: 900);
  const branch = '01930000-0000-7000-8000-000000000002';
  const cashier = '01930000-0000-7000-8000-000000000003';

  String daysAgo(int n) =>
      addisDate(DateTime.now().subtract(Duration(days: n)));

  setUp(() async {
    final opened = await openTestDb();
    db = opened.db;
    dir = opened.dir;
    outbox = Outbox(db);
    controlled = ControlledRepository(db, outbox);
    shifts = ShiftRepository(db, outbox);
  });

  tearDown(() async {
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<int> rows(String table) async =>
      (await db.db.rawQuery('SELECT count(*) AS n FROM $table')).first['n']
          as int;

  Future<String> dispense(LocalProduct p,
          {String rx = 'RX-PSY-00417', String? issued, String? shiftId}) =>
      controlled.dispense(
        product: p,
        qty: 2,
        prescriptionNo: rx,
        prescriber: 'Dr. Almaz Tesfaye',
        issuedOn: issued ?? daysAgo(2),
        branchId: branch,
        cashierId: cashier,
        shiftId: shiftId,
      );

  test(
      'a valid dispense writes the sale, the record and the outbox entry together',
      () async {
    await dispense(diazepam);

    expect(await rows('sale'), 1);
    expect(await rows('controlled_dispense'), 1);
    final queued = await db.db.query('outbox');
    expect(queued.single['entity_type'], 'controlled_dispense');
  });

  test('its cash belongs to the till: the cash-up expects it', () async {
    final shift = await shifts.openShift(
        userId: cashier, branchId: branch, openingFloatSantim: 10000);
    await dispense(diazepam, shiftId: shift.id);

    final expected = await shifts.expectedCash(shift.id);
    expect(expected.cashTakenSantim, 2400);
    expect(expected.expectedSantim, 12400);
  });

  test('AC-4.3 — an expired prescription is blocked, and nothing is written',
      () async {
    await expectLater(
      dispense(diazepam,
          issued: daysAgo(PsychotropicRules.psychotropicValidityDays + 1)),
      throwsA(isA<DispenseBlocked>()
          .having((e) => e.reason, 'reason', DispenseBlock.expired)),
    );
    expect(await rows('sale'), 0);
    expect(await rows('outbox'), 0);
  });

  test('the last valid day is still valid', () async {
    await dispense(diazepam,
        issued: daysAgo(PsychotropicRules.psychotropicValidityDays));
    expect(await rows('controlled_dispense'), 1);
  });

  test('a prescription dated in the future is blocked', () async {
    await expectLater(
      dispense(diazepam, issued: daysAgo(-3)),
      throwsA(isA<DispenseBlocked>()
          .having((e) => e.reason, 'reason', DispenseBlock.notYetValid)),
    );
  });

  test('AC-4.2 — a second psychotropic on the same paper is blocked, offline',
      () async {
    await dispense(diazepam);
    await expectLater(
      dispense(lorazepam, rx: 'rx psy 00417'),
      throwsA(isA<DispenseBlocked>().having(
          (e) => e.reason, 'reason', DispenseBlock.anotherPsychotropic)),
    );
    expect(await rows('controlled_dispense'), 1);

    // The same substance again on the same paper is a split dispense, not a second drug.
    await dispense(diazepam);
    expect(await rows('controlled_dispense'), 2);
  });

  test('the dedicated prescription number is required', () async {
    await expectLater(
      dispense(diazepam, rx: '  --  '),
      throwsA(isA<DispenseBlocked>().having(
          (e) => e.reason, 'reason', DispenseBlock.noPrescriptionNumber)),
    );
  });
}
