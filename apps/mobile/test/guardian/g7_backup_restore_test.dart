import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/data/backup.dart';
import 'package:pharmaet_mobile/data/catalog_repository.dart';
import 'package:pharmaet_mobile/data/inventory_repository.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/data/outbox.dart';
import 'package:pharmaet_mobile/data/sale_repository.dart';
import 'package:pharmaet_mobile/data/shift_repository.dart';

import '../support/test_db.dart';

/// G7 — A LOST PHONE DOES NOT LOSE THE SALES ON IT (FR-15, ADR-033; NFR-1.3).
///
/// The server has everything that synced. What lives only on the phone is the outbox: the
/// sales, receipts and cash-ups taken while the network was down — which here can be days.
/// A backup is a copy of that kept somewhere else, and this suite holds the promises a
/// backup has to keep to be worth making:
///
///   - what was queued on the lost phone is queued on the new one, **once**, in order;
///   - restoring **never destroys** what the restoring phone already holds;
///   - the file is **unreadable** without its passphrase, and says so honestly;
///   - it cannot be restored into the **wrong pharmacy or branch**.
void main() {
  const tenantId = '01930000-0000-7000-8000-000000000001';
  const branchId = '01930000-0000-7000-8000-000000000002';
  const cashierId = '01930000-0000-7000-8000-000000000003';
  const otherBranch = '01930000-0000-7000-8000-0000000000b2';
  const otherTenant = '01930000-0000-7000-8000-0000000000a1';
  const passphrase = 'correct horse battery';

  const product = LocalProduct(
    id: '01930000-0000-7000-8000-00000000000a',
    name: 'Paracetamol 500mg tablet',
    unit: 'tablet',
    isControlled: false,
    priceSantim: 500,
  );

  final dirs = <Directory>[];
  final dbs = <LocalDb>[];

  /// One phone: its own database file and the repositories over it.
  Future<_Phone> phone(String terminalId) async {
    final opened = await openTestDb();
    dirs.add(opened.dir);
    dbs.add(opened.db);
    return _Phone(opened.db, terminalId);
  }

  setUpAll(() => BackupService.useIsolate = false);

  tearDown(() async {
    for (final db in dbs) {
      await db.close();
    }
    for (final dir in dirs) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
    dbs.clear();
    dirs.clear();
  });

  Future<String> sell(_Phone p, {int qty = 1}) async =>
      (await p.sales.commitSale(
        lines: [CartLine(product: product, qty: qty, batchId: null)],
        tenantId: tenantId,
        branchId: branchId,
        cashierId: cashierId,
        terminalId: p.terminalId,
      ))
          .saleId;

  Future<Uint8List> backUp(_Phone p) => p.backup.create(
        passphrase: passphrase,
        tenantId: tenantId,
        tenantCode: 'abay',
        branchId: branchId,
        branchName: 'Bole',
        terminalId: p.terminalId,
      );

  Future<RestoreResult> restore(_Phone p, Uint8List file,
          {String pass = passphrase,
          String tenant = tenantId,
          String branch = branchId}) =>
      p.backup
          .restore(file, passphrase: pass, tenantId: tenant, branchId: branch);

  Future<List<String>> queuedOps(_Phone p) async =>
      (await p.outbox.pending(limit: 500)).map((e) => e.opId).toList();

  group('what was queued on the lost phone is queued on the new one', () {
    test('every unsynced sale comes back, once, in the order it was rung up',
        () async {
      final lost = await phone('01930000-0000-7000-8000-0000000000e1');
      final sold = [
        for (var i = 1; i <= 5; i++) await sell(lost, qty: i),
      ];
      final ops = await queuedOps(lost);
      final file = await backUp(lost);

      final fresh = await phone('01930000-0000-7000-8000-0000000000e2');
      final result = await restore(fresh, file);

      expect(result.operationsRestored, 5);
      expect(await queuedOps(fresh), ops);
      expect(await fresh.sales.unsyncedCount(), 5);

      // The sales themselves are on the new phone too — a receipt can be read back.
      final lines = await fresh.sales.linesOf(sold[2]);
      expect(lines.single.qty, 3);
      expect(lines.single.lineTotalSantim, 1500);
    });

    test('a restored operation is one the server will accept', () async {
      final lost = await phone('01930000-0000-7000-8000-0000000000e1');
      await sell(lost, qty: 2);
      final file = await backUp(lost);

      final fresh = await phone('01930000-0000-7000-8000-0000000000e2');
      await restore(fresh, file);

      final entry = (await fresh.outbox.pending()).single;
      final op = fresh.sales.toOperation(entry,
          tenantId: tenantId,
          branchId: branchId,
          actorId: cashierId,
          terminalId: fresh.terminalId);
      final wire = op.toJson();
      // Same idempotency key as on the lost phone: if that phone did sync before it
      // died, the server answers "duplicate" and the sale is not counted twice.
      expect(wire['opId'], entry.opId);
      expect((wire['payload'] as Map)['totalSantim'], 1000);
    });

    test('a shift, its sales and its cash-up keep their order', () async {
      final lost = await phone('01930000-0000-7000-8000-0000000000e1');
      final shift = await lost.shifts.openShift(
          userId: cashierId, branchId: branchId, openingFloatSantim: 20000);
      await lost.sales.commitSale(
        lines: [CartLine(product: product, qty: 4, batchId: null)],
        tenantId: tenantId,
        branchId: branchId,
        cashierId: cashierId,
        terminalId: lost.terminalId,
        shiftId: shift.id,
      );
      await lost.shifts
          .closeShiftWithCashUp(shift: shift, countedSantim: 22000);
      final types =
          (await lost.outbox.pending()).map((e) => e.entityType).toList();
      final file = await backUp(lost);

      final fresh = await phone('01930000-0000-7000-8000-0000000000e2');
      await restore(fresh, file);

      final restored = await fresh.outbox.pending();
      expect(restored.map((e) => e.entityType).toList(), types);
      // And strictly increasing, which is what the server orders by.
      final seqs = restored.map((e) => e.terminalSeq).toList();
      expect(seqs, [...seqs]..sort());
      expect(seqs.toSet().length, seqs.length);
    });

    test('a goods receipt comes back as a queued receipt', () async {
      final lost = await phone('01930000-0000-7000-8000-0000000000e1');
      await lost.inventory.commitReceipt(
        lines: const [
          ReceiptLine(
              product: product,
              lotNo: 'LOT-9',
              expiryDate: '2030-12-31',
              qty: 100,
              costSantim: 300),
        ],
        supplierName: 'EPSS',
        branchId: branchId,
      );
      final file = await backUp(lost);

      final fresh = await phone('01930000-0000-7000-8000-0000000000e2');
      await restore(fresh, file);
      expect((await fresh.outbox.pending()).single.entityType, 'goods_receipt');
    });
  });

  group('restoring never destroys what this phone already holds', () {
    test('this phone\'s own unsynced sales are all still there afterwards',
        () async {
      final lost = await phone('01930000-0000-7000-8000-0000000000e1');
      await sell(lost);
      await sell(lost);
      final file = await backUp(lost);

      // The replacement phone has been trading since.
      final current = await phone('01930000-0000-7000-8000-0000000000e2');
      final mine = [
        await sell(current),
        await sell(current),
        await sell(current)
      ];
      final myOps = await queuedOps(current);

      await restore(current, file);

      final all = await queuedOps(current);
      expect(all.length, 5);
      // Its own three first, untouched and in place; the restored two after them.
      expect(all.sublist(0, 3), myOps);
      for (final id in mine) {
        expect((await current.sales.linesOf(id)).length, 1);
      }
      expect(await current.sales.unsyncedCount(), 5);
    });

    test('restoring the same file twice adds nothing the second time',
        () async {
      final lost = await phone('01930000-0000-7000-8000-0000000000e1');
      await sell(lost);
      await sell(lost);
      final file = await backUp(lost);

      final fresh = await phone('01930000-0000-7000-8000-0000000000e2');
      await restore(fresh, file);
      final again = await restore(fresh, file);

      expect(again.operationsRestored, 0);
      expect(again.operationsAlreadyHere, 2);
      expect(again.recordsRestored, 0);
      expect(await fresh.outbox.depth(), 2);
      expect((await fresh.db.db.query('sale')).length, 2);
    });

    test('restoring a phone\'s own backup onto itself changes nothing',
        () async {
      final p = await phone('01930000-0000-7000-8000-0000000000e1');
      await sell(p);
      final before = await queuedOps(p);
      final result = await restore(p, await backUp(p));

      expect(result.operationsRestored, 0);
      expect(await queuedOps(p), before);
    });

    test('an old backup never overwrites newer prices or stock', () async {
      final lost = await phone('01930000-0000-7000-8000-0000000000e1');
      await lost.db.db.insert('product', {
        'id': product.id,
        'name': product.name,
        'unit': 'tablet',
        'is_controlled': 0,
        'price_santim': 500,
      });
      await sell(lost);
      final file = await backUp(lost);

      // Since then the owner raised the price, and the new phone pulled it.
      final current = await phone('01930000-0000-7000-8000-0000000000e2');
      await current.db.db.insert('product', {
        'id': product.id,
        'name': product.name,
        'unit': 'tablet',
        'is_controlled': 0,
        'price_santim': 650,
      });
      await restore(current, file);

      final row = (await current.db.db.query('product')).single;
      expect(row['price_santim'], 650);
      expect(await current.db.db.query('stock_batch'), isEmpty);
    });

    test('a restore that fails part-way leaves the phone exactly as it was',
        () async {
      final lost = await phone('01930000-0000-7000-8000-0000000000e1');
      await sell(lost);
      final file = await backUp(lost);

      final current = await phone('01930000-0000-7000-8000-0000000000e2');
      await sell(current);
      final before = await queuedOps(current);

      await expectLater(restore(current, file, pass: 'not the passphrase'),
          throwsA(isA<BackupException>()));
      expect(await queuedOps(current), before);
      expect((await current.db.db.query('sale')).length, 1);
    });
  });

  group('the file is unreadable without its passphrase', () {
    test('a wrong passphrase is refused, and said to be wrong', () async {
      final p = await phone('01930000-0000-7000-8000-0000000000e1');
      await sell(p);
      final file = await backUp(p);
      final fresh = await phone('01930000-0000-7000-8000-0000000000e2');

      await expectLater(
          restore(fresh, file, pass: 'correct horse batterx'),
          throwsA(isA<BackupException>().having(
              (e) => e.problem, 'problem', BackupProblem.wrongPassphrase)));
    });

    test('nothing a pharmacy would mind a stranger reading is in the clear',
        () async {
      final p = await phone('01930000-0000-7000-8000-0000000000e1');
      final saleId = await sell(p);
      final text = latin1.decode(await backUp(p));

      expect(text, isNot(contains('Paracetamol')));
      expect(text, isNot(contains(saleId)));
      expect(text, isNot(contains(cashierId)));
      expect(text, isNot(contains('totalSantim')));
      expect(text, isNot(contains(passphrase)));
    });

    test('two backups of the same phone do not look alike', () async {
      // A fresh salt and nonce each time: identical files would let someone holding two
      // tell that nothing had been sold in between.
      final p = await phone('01930000-0000-7000-8000-0000000000e1');
      await sell(p);
      final now = DateTime.utc(2026, 10, 7, 12);
      Future<Uint8List> make() => p.backup.create(
            passphrase: passphrase,
            tenantId: tenantId,
            tenantCode: 'abay',
            branchId: branchId,
            branchName: 'Bole',
            terminalId: p.terminalId,
            now: now,
          );
      final a = await make();
      final b = await make();
      expect(a.length, b.length);
      expect(a, isNot(equals(b)));
    });

    test('a file altered after it was made is refused', () async {
      final p = await phone('01930000-0000-7000-8000-0000000000e1');
      await sell(p);
      final file = await backUp(p);
      final fresh = await phone('01930000-0000-7000-8000-0000000000e2');

      // One bit, in the encrypted part.
      final flipped = Uint8List.fromList(file)..[file.length - 40] ^= 0x01;
      await expectLater(
          restore(fresh, flipped), throwsA(isA<BackupException>()));

      // And in the readable header: claim more unsynced sales than there are.
      final text = latin1.decode(file);
      final at = text.indexOf('"pending":1');
      expect(at, greaterThan(0));
      final edited = Uint8List.fromList(file)..[at + 10] = '7'.codeUnitAt(0);
      expect(BackupService.readHeader(edited).pending, 7);
      await expectLater(
          restore(fresh, edited),
          throwsA(isA<BackupException>().having(
              (e) => e.problem, 'problem', BackupProblem.wrongPassphrase)));
      expect(await fresh.outbox.depth(), 0);
    });

    test('a short passphrase is not accepted', () async {
      final p = await phone('01930000-0000-7000-8000-0000000000e1');
      expect(
          () => p.backup.create(
                passphrase: '1234567',
                tenantId: tenantId,
                tenantCode: 'abay',
                branchId: branchId,
                branchName: 'Bole',
                terminalId: p.terminalId,
              ),
          throwsArgumentError);
    });
  });

  group('it cannot be restored into the wrong place', () {
    test('another pharmacy\'s phone refuses it', () async {
      final p = await phone('01930000-0000-7000-8000-0000000000e1');
      await sell(p);
      final file = await backUp(p);
      final theirs = await phone('01930000-0000-7000-8000-0000000000e9');

      await expectLater(
          restore(theirs, file, tenant: otherTenant),
          throwsA(isA<BackupException>().having(
              (e) => e.problem, 'problem', BackupProblem.otherPharmacy)));
      expect(await theirs.outbox.depth(), 0);
    });

    test('another branch of the same pharmacy refuses it', () async {
      // Queued sales are pushed under the branch the phone stands in. Restoring Bole's
      // in Piassa would book them to Piassa.
      final p = await phone('01930000-0000-7000-8000-0000000000e1');
      await sell(p);
      final file = await backUp(p);
      final piassa = await phone('01930000-0000-7000-8000-0000000000e3');

      await expectLater(
          restore(piassa, file, branch: otherBranch),
          throwsA(isA<BackupException>()
              .having((e) => e.problem, 'problem', BackupProblem.otherBranch)));
      expect(await piassa.outbox.depth(), 0);
    });
  });

  group('the header', () {
    test('says whose backup it is and what only it holds, with no passphrase',
        () async {
      final p = await phone('01930000-0000-7000-8000-0000000000e1');
      await sell(p);
      await sell(p);
      await sell(p);
      final header = BackupService.readHeader(await backUp(p));

      expect(header.branchName, 'Bole');
      expect(header.tenantCode, 'abay');
      expect(header.pending, 3);
      expect(header.sales, 3);
      expect(header.terminalId, p.terminalId);
    });

    test('this phone remembers when it last made one', () async {
      final p = await phone('01930000-0000-7000-8000-0000000000e1');
      expect(await p.backup.lastBackupAt(), isNull);
      await backUp(p);
      expect(await p.backup.lastBackupAt(), isNotNull);
    });
  });

  group('things that are not a backup', () {
    for (final (what, bytes) in <(String, List<int>)>[
      ('an empty file', []),
      ('a photo', [0xFF, 0xD8, 0xFF, 0xE0, 0, 16, 74, 70, 73, 70]),
      ('the first line and nothing else', ascii.encode('PHARMAET-BACKUP\n')),
      (
        'a header with no body',
        [
          ...ascii.encode('PHARMAET-BACKUP\n'),
          0, 0, 0, 2, 123, 125, //
        ]
      ),
    ]) {
      test('$what is refused as not a backup', () {
        expect(
            () => BackupService.readHeader(Uint8List.fromList(bytes)),
            throwsA(isA<BackupException>().having(
                (e) => e.problem, 'problem', BackupProblem.notABackup)));
      });
    }

    test('a backup cut short in transit is refused', () async {
      final p = await phone('01930000-0000-7000-8000-0000000000e1');
      await sell(p);
      final file = await backUp(p);
      final fresh = await phone('01930000-0000-7000-8000-0000000000e2');
      await expectLater(
          restore(fresh, Uint8List.sublistView(file, 0, file.length - 60)),
          throwsA(isA<BackupException>()));
      expect(await fresh.outbox.depth(), 0);
    });

    test('a backup from a newer app says so, rather than half-restoring',
        () async {
      final header = utf8.encode(jsonEncode({
        'format': BackupService.format + 1,
        'tenantId': tenantId,
        'tenantCode': 'abay',
        'branchId': branchId,
        'branchName': 'Bole',
        'terminalId': 'x',
        'createdAt': '2027-01-01T00:00:00.000Z',
        'pending': 1,
        'sales': 1,
      }));
      final file = Uint8List.fromList([
        ...ascii.encode('PHARMAET-BACKUP\n'),
        0, 0, (header.length >> 8) & 0xff, header.length & 0xff, //
        ...header,
        ...List.filled(64, 0),
      ]);
      expect(
          () => BackupService.readHeader(file),
          throwsA(isA<BackupException>()
              .having((e) => e.problem, 'problem', BackupProblem.tooNew)));
    });
  });
}

class _Phone {
  _Phone(this.db, this.terminalId)
      : outbox = Outbox(db),
        catalog = CatalogRepository(db),
        // Few rounds: these tests are about what a backup holds, not how slow a guess is.
        backup = BackupService(db, kdfRounds: 1000) {
    sales = SaleRepository(db, outbox, catalog);
    shifts = ShiftRepository(db, outbox);
    inventory = InventoryRepository(db, outbox, catalog);
  }

  final LocalDb db;
  final String terminalId;
  final Outbox outbox;
  final CatalogRepository catalog;
  final BackupService backup;
  late final SaleRepository sales;
  late final ShiftRepository shifts;
  late final InventoryRepository inventory;
}
