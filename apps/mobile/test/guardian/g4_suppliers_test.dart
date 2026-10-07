import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/contracts/contracts.dart';
import 'package:pharmaet_mobile/data/backup.dart';
import 'package:pharmaet_mobile/data/catalog_repository.dart';
import 'package:pharmaet_mobile/data/inventory_repository.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/data/outbox.dart';
import 'package:pharmaet_mobile/data/sale_repository.dart';
import 'package:pharmaet_mobile/data/shift_repository.dart';
import 'package:pharmaet_mobile/data/supplier_repository.dart';

import '../support/test_db.dart';

/// G4 — SUPPLIERS AND WHAT IS OWED TO THEM, device half (FR-18, ADR-038; contract 1.9.0).
///
/// A van arrives when it arrives, and the invoice is paid when there is money. Both happen
/// with no network. What has to hold on the phone:
///
///   - **what is owed is what deliveries left owing, less what was paid** — and it is the
///     server's figure plus this phone's queue, never one overwriting the other (G4);
///   - **the stock arrives whether or not it was paid for** (G5);
///   - **cash paid out of a till has left the drawer**, so the cash-up stops expecting it;
///   - a delivery with nothing owing and no supplier is exactly the receipt it always was
///     (ADR-009).
void main() {
  late LocalDb db;
  late Directory dir;
  late Outbox outbox;
  late CatalogRepository catalog;
  late InventoryRepository inventory;
  late SupplierRepository suppliers;
  late ShiftRepository shifts;
  late SaleRepository sales;

  const tenantId = '01930000-0000-7000-8000-000000000001';
  const branchId = '01930000-0000-7000-8000-000000000002';
  const managerId = '01930000-0000-7000-8000-000000000003';
  const terminalId = '01930000-0000-7000-8000-000000000004';

  const box = ProductPack(name: 'box', size: 30, priceSantim: 10000);
  const product = LocalProduct(
    id: '01930000-0000-7000-8000-00000000000a',
    name: 'Amoxicillin 500mg',
    unit: 'capsule',
    isControlled: false,
    priceSantim: 400,
    packs: [box],
  );

  setUp(() async {
    final opened = await openTestDb();
    db = opened.db;
    dir = opened.dir;
    outbox = Outbox(db);
    catalog = CatalogRepository(db);
    inventory = InventoryRepository(db, outbox, catalog);
    suppliers = SupplierRepository(db, outbox);
    shifts = ShiftRepository(db, outbox);
    sales = SaleRepository(db, outbox, catalog);
  });

  tearDown(() async {
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// Five boxes at 90.00 — a delivery that cost 450.00 — with [owed] of it not paid.
  Future<String> receive(
          {String? supplierId, int owed = 0, String name = 'EPSS'}) =>
      inventory.commitReceipt(
        lines: [
          ReceiptLine(
              product: product,
              lotNo: 'LOT-${DateTime.now().microsecondsSinceEpoch}',
              expiryDate: '2030-12-31',
              qty: 5,
              costSantim: 9000,
              pack: box),
        ],
        supplierName: name,
        branchId: branchId,
        supplierId: supplierId,
        owedSantim: owed,
      );

  Future<void> pay(String supplierId, int amount,
          {String method = 'cash', String? shiftId}) =>
      suppliers.recordPayment(
        supplierId: supplierId,
        amountSantim: amount,
        branchId: branchId,
        paidBy: managerId,
        method: method,
        shiftId: shiftId,
      );

  /// What the server would send back for one supplier.
  PullResponse pullOf(String id, int balance, {int seq = 5}) => PullResponse(
        contractVersion: kContractVersion,
        cursor: seq,
        hasMore: false,
        products: const [],
        branches: const [],
        users: const [],
        stockBatches: const [],
        suppliers: [
          SupplierRef(
              id: id, name: 'EPSS', balanceSantim: balance, changeSeq: seq),
        ],
        serverTime: '2026-10-07T08:00:00.000Z',
      );

  /// The server acknowledges everything queued, as a successful push does.
  Future<void> ackAll() async {
    final pending = await outbox.pending(limit: 500);
    await outbox.applyAcks([
      for (final e in pending)
        Ack(opId: e.opId, status: 'applied', serverVersion: 1),
    ]);
  }

  Future<int> owed(String id) async =>
      (await suppliers.supplier(id))!.balanceSantim;

  Operation wire(OutboxEntry entry) {
    final build = switch (entry.entityType) {
      'goods_receipt' => inventory.toOperation,
      _ => suppliers.toOperation,
    };
    return build(entry,
        tenantId: tenantId,
        branchId: branchId,
        actorId: managerId,
        terminalId: terminalId);
  }

  group('a supplier', () {
    test('is opened with no network, and queued ahead of its first delivery',
        () async {
      final s = await suppliers.create(name: '  EPSS ', phone: '0911 000000');
      await receive(supplierId: s.id, owed: 45000);

      expect(s.name, 'EPSS');
      expect((await outbox.pending()).map((e) => e.entityType).toList(),
          ['supplier', 'goods_receipt']);
    });

    test('with no name is refused', () {
      expect(() => suppliers.create(name: '   '), throwsArgumentError);
    });

    test('typed again in another case is the same supplier, not a second one',
        () async {
      final first = await suppliers.findOrCreate('EPSS');
      final again = await suppliers.findOrCreate('  epss ');
      final other = await suppliers.findOrCreate('Addis Pharma');

      expect(again.id, first.id);
      expect(other.id, isNot(first.id));
      expect((await suppliers.suppliers()).length, 2);
      // One `supplier` operation each — not one per receipt.
      expect(
          (await outbox.pending())
              .where((e) => e.entityType == 'supplier')
              .length,
          2);
    });

    test('is one the server will accept', () async {
      await suppliers.create(name: 'EPSS', note: '30 days');
      final op = wire((await outbox.pending()).single).toJson();
      expect(op['entityType'], 'supplier');
      final payload = op['payload'] as Map<String, dynamic>;
      expect(payload['name'], 'EPSS');
      expect(payload['phone'], isNull);
      expect(payload['note'], '30 days');
    });
  });

  group('a delivery not paid for', () {
    test('leaves the pharmacy owing exactly what was not paid', () async {
      final s = await suppliers.create(name: 'EPSS');
      await receive(supplierId: s.id, owed: 45000);
      await receive(supplierId: s.id, owed: 20000);
      await receive(supplierId: s.id); // paid on delivery

      expect(await owed(s.id), 65000);
    });

    test('puts the stock on the shelf whether or not it was paid for (G5)',
        () async {
      final s = await suppliers.create(name: 'EPSS');
      await receive(supplierId: s.id, owed: 45000);
      // Five boxes of thirty.
      expect(await catalog.onHand(product.id, branchId), 150);
    });

    test('cannot leave more owing than it cost, or owe it to nobody', () async {
      final s = await suppliers.create(name: 'EPSS');
      expect(() => receive(supplierId: s.id, owed: 45001), throwsArgumentError);
      expect(() => receive(supplierId: s.id, owed: -1), throwsArgumentError);
      expect(() => receive(owed: 100), throwsArgumentError);
      // Refused before anything was written.
      expect(await db.db.query('goods_receipt'), isEmpty);
      expect(await catalog.onHand(product.id, branchId), 0);
    });

    test('says who and how much on the wire, and the envelope accepts it',
        () async {
      final s = await suppliers.create(name: 'EPSS');
      await receive(supplierId: s.id, owed: 20000);

      final entry = (await outbox.pending()).last;
      final payload = wire(entry).toJson()['payload'] as Map<String, dynamic>;
      expect(payload['supplierId'], s.id);
      expect(payload['owedSantim'], 20000);
      expect(payload['owedSantim'], isA<int>());
      expect(payload['supplierName'], 'EPSS');
    });

    test('paid on delivery names the supplier and sends nothing owed',
        () async {
      final s = await suppliers.create(name: 'EPSS');
      await receive(supplierId: s.id);
      final entry = (await outbox.pending()).last;
      expect(entry.payload['supplierId'], s.id);
      expect(entry.payload.containsKey('owedSantim'), isFalse);
    });

    test(
        'with no supplier queues no new key at all — what 1.8.0 sent (ADR-009)',
        () async {
      await receive();
      final entry = (await outbox.pending()).single;
      expect(entry.payload.containsKey('supplierId'), isFalse);
      expect(entry.payload.containsKey('owedSantim'), isFalse);
      final row = (await db.db.query('goods_receipt')).single;
      expect(row['supplier_id'], isNull);
      expect(row['owed_santim'], 0);
    });
  });

  group('what is owed to a supplier', () {
    test('falls by a payment, and may go below zero', () async {
      final s = await suppliers.create(name: 'EPSS');
      await receive(supplierId: s.id, owed: 45000);
      await pay(s.id, 20000);
      expect(await owed(s.id), 25000);

      await pay(s.id, 30000, method: 'other_recorded');
      // 50.00 paid ahead, said plainly rather than capped at zero.
      expect(await owed(s.id), -5000);
    });

    test('is the server\'s figure plus what this phone has queued', () async {
      const id = '01930000-0000-7000-8000-00000000000c';
      // Another phone received 500.00 on account; it has synced.
      await catalog.applyPull(pullOf(id, 50000));
      expect(await owed(id), 50000);

      await receive(supplierId: id, owed: 45000);
      await pay(id, 10000);

      final now = (await suppliers.supplier(id))!;
      expect(now.balanceSantim, 50000 + 45000 - 10000);
      expect(now.pendingSantim, 35000);
    });

    test('a pull never erases a debt that has not synced', () async {
      const id = '01930000-0000-7000-8000-00000000000c';
      await catalog.applyPull(pullOf(id, 50000));
      await receive(supplierId: id, owed: 45000);

      // The server's figure moves (the owner paid from another phone) while ours waits.
      await catalog.applyPull(pullOf(id, 30000, seq: 6));

      expect(await owed(id), 30000 + 45000);
    });

    test('is not counted twice once the server has it', () async {
      const id = '01930000-0000-7000-8000-00000000000c';
      await catalog.applyPull(pullOf(id, 50000));
      await receive(supplierId: id, owed: 45000);
      await pay(id, 10000);

      // Push succeeds; the next pull brings a figure that already includes both.
      await ackAll();
      await catalog.applyPull(pullOf(id, 85000, seq: 7));

      final now = (await suppliers.supplier(id))!;
      expect(now.balanceSantim, 85000);
      expect(now.pendingSantim, 0);
    });

    test(
        'the total does not let one supplier paid ahead hide a debt to another',
        () async {
      final a = await suppliers.create(name: 'EPSS');
      final b = await suppliers.create(name: 'Addis Pharma');
      await receive(supplierId: a.id, owed: 45000);
      await pay(b.id, 20000); // 200.00 ahead with the other

      expect(await suppliers.totalOwed(), 45000);
      expect((await suppliers.suppliers()).first.name, 'EPSS');
    });

    test('a payment must be more than nothing, in a tender that exists',
        () async {
      final s = await suppliers.create(name: 'EPSS');
      expect(() => pay(s.id, 0), throwsArgumentError);
      expect(() => pay(s.id, -500), throwsArgumentError);
      expect(() => pay(s.id, 500, method: 'credit'), throwsArgumentError);
      expect(await db.db.query('supplier_payment'), isEmpty);
    });

    test('a payment is one the server will accept', () async {
      final s = await suppliers.create(name: 'EPSS');
      await pay(s.id, 20000);
      final payload = wire((await outbox.pending()).last).toJson()['payload']
          as Map<String, dynamic>;
      expect(payload['supplierId'], s.id);
      expect(payload['amountSantim'], 20000);
      expect(payload['method'], 'cash');
      expect(payload['shiftId'], isNull);
      expect(payload['paidBy'], managerId);
    });

    test('this phone\'s history shows deliveries and payments, newest first',
        () async {
      final s = await suppliers.create(name: 'EPSS');
      await receive(supplierId: s.id, owed: 20000);
      await pay(s.id, 5000);

      final history = await suppliers.history(s.id);
      expect(history.length, 2);
      expect(history.first.isPayment, isTrue);
      expect(history.first.amountSantim, 5000);
      expect(history.last.isPayment, isFalse);
      // 450.00 delivered, 200.00 of it left owing.
      expect(history.last.costSantim, 45000);
      expect(history.last.amountSantim, 20000);
    });
  });

  group('the cash-up (BR-8.2)', () {
    Future<void> cashSale(String shiftId) => sales.commitSale(
          lines: [CartLine(product: product, qty: 5, batchId: null)],
          tenantId: tenantId,
          branchId: branchId,
          cashierId: managerId,
          terminalId: terminalId,
          shiftId: shiftId,
        );

    test('does not expect cash that was paid to a supplier out of the till',
        () async {
      final s = await suppliers.create(name: 'EPSS');
      final shift = await shifts.openShift(
          userId: managerId, branchId: branchId, openingFloatSantim: 20000);
      await cashSale(shift.id); // 20.00 in
      await pay(s.id, 5000, shiftId: shift.id); // 50.00 out of the drawer
      await pay(s.id, 1000, method: 'other_recorded'); // a transfer
      await pay(s.id, 500); // the owner's own cash

      final expected = await shifts.expectedCash(shift.id);
      expect(expected.paidOutCashSantim, 5000);
      expect(expected.expectedSantim, 20000 + 2000 - 5000);
    });

    test('the figure the cashier agrees to is the one that is recorded',
        () async {
      final s = await suppliers.create(name: 'EPSS');
      final shift = await shifts.openShift(
          userId: managerId, branchId: branchId, openingFloatSantim: 20000);
      await pay(s.id, 5000, shiftId: shift.id);

      final variance =
          await shifts.closeShiftWithCashUp(shift: shift, countedSantim: 15000);
      // Counted exactly float less the payment: no variance. Without this, paying a
      // supplier from the drawer was a 50.00 shortage with the cashier's name on it.
      expect(variance, 0);
      expect((await db.db.query('cash_up')).single['expected_santim'], 15000);
    });

    test('a till that paid no supplier expects exactly what it did', () async {
      final shift = await shifts.openShift(
          userId: managerId, branchId: branchId, openingFloatSantim: 20000);
      await cashSale(shift.id);
      final expected = await shifts.expectedCash(shift.id);
      expect(expected.paidOutCashSantim, 0);
      expect(expected.expectedSantim, 22000);
    });

    test('only cash can come out of a till', () async {
      final s = await suppliers.create(name: 'EPSS');
      final shift = await shifts.openShift(
          userId: managerId, branchId: branchId, openingFloatSantim: 20000);
      expect(() => pay(s.id, 1000, method: 'other_recorded', shiftId: shift.id),
          throwsArgumentError);
    });
  });

  group('a lost phone (FR-15)', () {
    test('a backup carries an unsynced supplier, the debt and the payment',
        () async {
      BackupService.useIsolate = false;
      final s = await suppliers.create(name: 'EPSS');
      await receive(supplierId: s.id, owed: 45000);
      await pay(s.id, 10000);
      final file = await BackupService(db, kdfRounds: 1000).create(
        passphrase: 'correct horse battery',
        tenantId: tenantId,
        tenantCode: 'abay',
        branchId: branchId,
        branchName: 'Bole',
        terminalId: terminalId,
      );

      final fresh = await openTestDb();
      addTearDown(() async {
        await fresh.db.close();
        if (fresh.dir.existsSync()) fresh.dir.deleteSync(recursive: true);
      });
      await BackupService(fresh.db, kdfRounds: 1000).restore(file,
          passphrase: 'correct horse battery',
          tenantId: tenantId,
          branchId: branchId);

      final restored = SupplierRepository(fresh.db, Outbox(fresh.db));
      final back = (await restored.supplier(s.id))!;
      expect(back.name, 'EPSS');
      expect(back.balanceSantim, 35000);
      // And in the order the server needs: the supplier before what it is owed.
      expect(
          (await Outbox(fresh.db).pending()).map((e) => e.entityType).toList(),
          ['supplier', 'goods_receipt', 'supplier_payment']);
    });
  });
}
