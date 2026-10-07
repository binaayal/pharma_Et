import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/contracts/contracts.dart';
import 'package:pharmaet_mobile/data/backup.dart';
import 'package:pharmaet_mobile/data/catalog_repository.dart';
import 'package:pharmaet_mobile/data/customer_repository.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/data/outbox.dart';
import 'package:pharmaet_mobile/data/sale_repository.dart';
import 'package:pharmaet_mobile/data/shift_repository.dart';

import '../support/test_db.dart';

/// G4 — THE CUSTOMER CREDIT LEDGER, device half (FR-16, ADR-034; contract 1.7.0).
///
/// Selling on credit and taking a repayment both happen at the counter, with or without a
/// network. This suite holds what has to be true on the phone while they do:
///
///   - **the money still adds up** — what was paid now plus what is owed is the sale's
///     total, to the santim (G4);
///   - **the balance is the server's figure plus what this phone has queued**, and a pull
///     can never erase a debt that has not synced, nor count one twice once it has;
///   - **cash against a debt is in the drawer**, so the cash-up expects it — and the part
///     of a sale that went on credit is not (BR-8.2);
///   - an ordinary cash sale leaves the phone exactly as it did before credit existed.
void main() {
  late LocalDb db;
  late Directory dir;
  late Outbox outbox;
  late CatalogRepository catalog;
  late CustomerRepository customers;
  late SaleRepository sales;
  late ShiftRepository shifts;

  const tenantId = '01930000-0000-7000-8000-000000000001';
  const branchId = '01930000-0000-7000-8000-000000000002';
  const cashierId = '01930000-0000-7000-8000-000000000003';
  const terminalId = '01930000-0000-7000-8000-000000000004';

  const product = LocalProduct(
    id: '01930000-0000-7000-8000-00000000000a',
    name: 'Paracetamol 500mg tablet',
    unit: 'tablet',
    isControlled: false,
    priceSantim: 1500,
  );

  setUp(() async {
    final opened = await openTestDb();
    db = opened.db;
    dir = opened.dir;
    outbox = Outbox(db);
    catalog = CatalogRepository(db);
    customers = CustomerRepository(db, outbox);
    sales = SaleRepository(db, outbox, catalog);
    shifts = ShiftRepository(db, outbox);
  });

  tearDown(() async {
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// 3 × 15.00 = 45.00, with [credit] of it owed by [customerId].
  Future<CommittedSale> sell(
          {String? customerId, int credit = 0, String? shiftId, int qty = 3}) =>
      sales.commitSale(
        lines: [CartLine(product: product, qty: qty, batchId: null)],
        tenantId: tenantId,
        branchId: branchId,
        cashierId: cashierId,
        terminalId: terminalId,
        shiftId: shiftId,
        customerId: customerId,
        creditSantim: credit,
      );

  Future<void> pay(String customerId, int amount,
          {String method = 'cash', String? shiftId}) =>
      customers.recordPayment(
        customerId: customerId,
        amountSantim: amount,
        branchId: branchId,
        receivedBy: cashierId,
        method: method,
        shiftId: shiftId,
      );

  /// What the server would send back for one customer.
  PullResponse pullOf(String id, int balance, {int seq = 5}) => PullResponse(
        contractVersion: kContractVersion,
        cursor: seq,
        hasMore: false,
        products: const [],
        branches: const [],
        users: const [],
        stockBatches: const [],
        customers: [
          CustomerRef(
              id: id,
              name: 'Abebe Kebede',
              balanceSantim: balance,
              changeSeq: seq),
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

  Future<int> owes(String id) async =>
      (await customers.customer(id))!.balanceSantim;

  group('opening an account at the counter', () {
    test('needs no network, and is queued ahead of the sale that names it',
        () async {
      final c = await customers.create(name: '  Abebe Kebede ', phone: ' ');
      await sell(customerId: c.id, credit: 4500);

      final queued = await outbox.pending();
      // The server applies in this order; the customer must exist before their debt.
      expect(queued.map((e) => e.entityType).toList(), ['customer', 'sale']);
      expect(c.name, 'Abebe Kebede');
      expect(queued.first.payload['phone'], isNull);
    });

    test('refuses a customer with no name', () {
      expect(() => customers.create(name: '   '), throwsArgumentError);
    });

    test('is one the server will accept', () async {
      await customers.create(name: 'Abebe Kebede', phone: '0911 23 45 67');
      final op = customers.toOperation((await outbox.pending()).single,
          tenantId: tenantId,
          branchId: branchId,
          actorId: cashierId,
          terminalId: terminalId);
      final wire = op.toJson();
      expect(wire['entityType'], 'customer');
      expect((wire['payload'] as Map)['name'], 'Abebe Kebede');
    });
  });

  group('selling on credit', () {
    test('what is paid now and what is owed add up to the total (G4)',
        () async {
      final c = await customers.create(name: 'Abebe');
      // 45.00 sold; 25.00 on the account, so 20.00 in cash now.
      final sale = await sell(customerId: c.id, credit: 2500);
      expect(sale.totalSantim, 4500);

      final rows = await db.db.query('payment', orderBy: 'method');
      expect(rows.map((r) => [r['method'], r['amount_santim']]).toList(), [
        ['cash', 2000],
        ['credit', 2500],
      ]);
      expect(rows.fold<int>(0, (sum, r) => sum + (r['amount_santim']! as int)),
          sale.totalSantim);
    });

    test('wholly on credit records no cash payment at all', () async {
      final c = await customers.create(name: 'Abebe');
      await sell(customerId: c.id, credit: 4500);

      final rows = await db.db.query('payment');
      expect(rows.single['method'], 'credit');
      expect(rows.single['amount_santim'], 4500);
    });

    test('queues the customer and both payments on the wire', () async {
      final c = await customers.create(name: 'Abebe');
      await sell(customerId: c.id, credit: 2500);

      final entry =
          (await outbox.pending()).firstWhere((e) => e.entityType == 'sale');
      expect(entry.payload['customerId'], c.id);
      final payments = (entry.payload['payments'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect(payments.map((p) => p['method']).toList(), ['cash', 'credit']);
      expect(payments.fold<int>(0, (s, p) => s + (p['amountSantim'] as int)),
          4500);

      // And the envelope takes it.
      final op = sales.toOperation(entry,
          tenantId: tenantId,
          branchId: branchId,
          actorId: cashierId,
          terminalId: terminalId);
      expect((op.toJson()['payload'] as Map)['customerId'], c.id);
    });

    test('refuses credit owed by nobody, and credit beyond the total',
        () async {
      final c = await customers.create(name: 'Abebe');
      await expectLater(sell(credit: 1000), throwsArgumentError);
      await expectLater(
          sell(customerId: c.id, credit: 4501), throwsArgumentError);
      await expectLater(
          sell(customerId: c.id, credit: -1), throwsArgumentError);
      expect(await db.db.query('sale'), isEmpty);
    });

    test('an ordinary cash sale is exactly what it was before credit existed',
        () async {
      await sell();

      final entry = (await outbox.pending()).single;
      // No customer key at all, and one payment: byte-for-byte a 1.6.0 sale (ADR-009).
      expect(entry.payload.containsKey('customerId'), isFalse);
      final payments = (entry.payload['payments'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect(payments.single['method'], 'cash');
      expect(payments.single['amountSantim'], 4500);
      expect((await db.db.query('sale')).single['customer_id'], isNull);
    });

    test('a cash sale to a known customer is not put in the debt book',
        () async {
      // The book is who owes money, not who bought what (docs/01 §2.3).
      final c = await customers.create(name: 'Abebe');
      await sell(customerId: c.id);
      expect((await db.db.query('sale')).single['customer_id'], isNull);
      expect(await owes(c.id), 0);
    });
  });

  group('what a customer owes', () {
    test('is what this phone sold them on credit, before anything syncs',
        () async {
      final c = await customers.create(name: 'Abebe');
      await sell(customerId: c.id, credit: 2500);
      await sell(customerId: c.id, credit: 4500);

      final now = (await customers.customer(c.id))!;
      expect(now.balanceSantim, 7000);
      // All of it still queued, and said to be.
      expect(now.pendingSantim, 7000);
    });

    test('falls by a repayment, and may go below zero', () async {
      final c = await customers.create(name: 'Abebe');
      await sell(customerId: c.id, credit: 4500);
      await pay(c.id, 2000);
      expect(await owes(c.id), 2500);

      // Settles the rest with a 50 note and waves away the change.
      await pay(c.id, 5000);
      expect(await owes(c.id), -2500);
    });

    test('is the server\'s figure plus what this phone has queued', () async {
      const id = '01930000-0000-7000-8000-00000000000c';
      // Another phone sold this customer 50.00 on credit; it has synced.
      await catalog.applyPull(pullOf(id, 5000));
      expect(await owes(id), 5000);

      await sell(customerId: id, credit: 2500);
      await pay(id, 1000);

      final now = (await customers.customer(id))!;
      expect(now.balanceSantim, 5000 + 2500 - 1000);
      expect(now.pendingSantim, 1500);
    });

    test('a pull never erases a debt that has not synced', () async {
      const id = '01930000-0000-7000-8000-00000000000c';
      await catalog.applyPull(pullOf(id, 5000));
      await sell(customerId: id, credit: 2500);

      // The server's figure moves (another phone took a repayment) while ours is queued.
      await catalog.applyPull(pullOf(id, 3000, seq: 6));

      expect(await owes(id), 3000 + 2500);
    });

    test('is not counted twice once the server has it', () async {
      const id = '01930000-0000-7000-8000-00000000000c';
      await catalog.applyPull(pullOf(id, 5000));
      await sell(customerId: id, credit: 2500);
      await pay(id, 1000);

      // Push succeeds; the next pull brings a figure that already includes both.
      await ackAll();
      await catalog.applyPull(pullOf(id, 6500, seq: 7));

      final now = (await customers.customer(id))!;
      expect(now.balanceSantim, 6500);
      expect(now.pendingSantim, 0);
    });

    test(
        'the total owed does not let one customer\'s credit hide another\'s debt',
        () async {
      final a = await customers.create(name: 'Abebe');
      final b = await customers.create(name: 'Clinic');
      await sell(customerId: a.id, credit: 4500);
      await pay(b.id, 2000); // the clinic is 20.00 ahead

      expect(await customers.totalOwed(), 4500);
      // And the list leads with who owes most.
      expect((await customers.customers()).first.name, 'Abebe');
    });

    test('a repayment must be more than nothing', () async {
      final c = await customers.create(name: 'Abebe');
      await expectLater(pay(c.id, 0), throwsArgumentError);
      await expectLater(pay(c.id, -500), throwsArgumentError);
      await expectLater(pay(c.id, 500, method: 'credit'), throwsArgumentError);
      expect(await db.db.query('credit_payment'), isEmpty);
    });

    test('a repayment is one the server will accept', () async {
      final c = await customers.create(name: 'Abebe');
      await pay(c.id, 2500);
      final entry = (await outbox.pending())
          .firstWhere((e) => e.entityType == 'credit_payment');
      final op = customers.toOperation(entry,
          tenantId: tenantId,
          branchId: branchId,
          actorId: cashierId,
          terminalId: terminalId);
      final payload = op.toJson()['payload'] as Map;
      expect(payload['amountSantim'], 2500);
      expect(payload['amountSantim'], isA<int>());
      expect(payload['receivedBy'], cashierId);
    });

    test('this phone\'s history shows both directions, newest first', () async {
      final c = await customers.create(name: 'Abebe');
      await sell(customerId: c.id, credit: 4500);
      await pay(c.id, 2000);

      final history = await customers.history(c.id);
      expect(history.length, 2);
      expect(history.first.isPayment, isTrue);
      expect(history.first.amountSantim, 2000);
      expect(history.last.isPayment, isFalse);
      expect(history.last.amountSantim, 4500);
      expect(history.every((e) => !e.synced), isTrue);
    });
  });

  group('the cash-up (BR-8.2)', () {
    test('expects cash taken against a debt, and not the credit it was sold on',
        () async {
      final c = await customers.create(name: 'Abebe');
      final shift = await shifts.openShift(
          userId: cashierId, branchId: branchId, openingFloatSantim: 20000);

      await sell(shiftId: shift.id, qty: 1); // 15.00 cash
      await sell(
          customerId: c.id, credit: 3500, shiftId: shift.id); // 10.00 cash
      await pay(c.id, 2500, shiftId: shift.id); // 25.00 cash
      await pay(c.id, 500, method: 'other_recorded', shiftId: shift.id);

      final expected = await shifts.expectedCash(shift.id);
      expect(expected.cashTakenSantim, 1500 + 1000);
      expect(expected.repaidCashSantim, 2500);
      // The 35.00 on credit and the 5.00 by Telebirr never reached the drawer.
      expect(expected.expectedSantim, 20000 + 1500 + 1000 + 2500);
    });

    test('the figure the cashier agrees to is the one that is recorded',
        () async {
      final c = await customers.create(name: 'Abebe');
      final shift = await shifts.openShift(
          userId: cashierId, branchId: branchId, openingFloatSantim: 20000);
      await pay(c.id, 2500, shiftId: shift.id);

      final variance =
          await shifts.closeShiftWithCashUp(shift: shift, countedSantim: 22500);
      // Counted exactly float + repayment: no variance. Before this, a repayment showed
      // as 25.00 of unexplained extra cash on every shift that took one.
      expect(variance, 0);
      expect((await db.db.query('cash_up')).single['expected_santim'], 22500);
    });

    test('a repayment in another till does not count toward this one',
        () async {
      final c = await customers.create(name: 'Abebe');
      final shift = await shifts.openShift(
          userId: cashierId, branchId: branchId, openingFloatSantim: 20000);
      await pay(c.id, 2500); // no till

      expect((await shifts.expectedCash(shift.id)).repaidCashSantim, 0);
    });
  });

  group('a lost phone (FR-15)', () {
    test(
        'a backup carries an unsynced customer, their debt and their repayment',
        () async {
      BackupService.useIsolate = false;
      final c = await customers.create(name: 'Abebe Kebede');
      await sell(customerId: c.id, credit: 4500);
      await pay(c.id, 1000);
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

      final restored = CustomerRepository(fresh.db, Outbox(fresh.db));
      final back = (await restored.customer(c.id))!;
      expect(back.name, 'Abebe Kebede');
      expect(back.balanceSantim, 3500);
      // And in the order the server needs: the customer before what they owe.
      expect(
          (await Outbox(fresh.db).pending()).map((e) => e.entityType).toList(),
          ['customer', 'sale', 'credit_payment']);
    });
  });
}
