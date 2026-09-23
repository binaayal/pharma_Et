import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/data/catalog_repository.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/data/outbox.dart';
import 'package:pharmaet_mobile/data/sale_repository.dart';

import '../support/test_db.dart';

/// G7 — CHAOS (docs/05-qa §7).
///
/// §7 asks for four things: kill the app mid-sale, kill it mid-sync, drop the network
/// mid-push, and **corrupt-then-restart**. The first three were covered. The fourth was not,
/// and it is the one with teeth: the target market has unreliable mains power and cheap
/// flash storage, so a write interrupted at the wrong moment is a routine event rather than
/// an exotic one.
///
/// Both suites here defend the same promise from opposite sides. A pharmacy must never lose
/// a sale it took, and a pharmacy must never be unable to trade. Where those two conflict —
/// and corruption is exactly where they conflict — trading wins, and the loss is made loud
/// rather than quiet (ADR-018).
void main() {
  const tenantId = '01930000-0000-7000-8000-000000000001';
  const branchId = '01930000-0000-7000-8000-000000000002';
  const cashierId = '01930000-0000-7000-8000-000000000003';
  const terminalId = '01930000-0000-7000-8000-000000000004';

  LocalProduct product() => const LocalProduct(
        id: '01930000-0000-7000-8000-00000000000a',
        name: 'Paracetamol',
        unit: 'tablet',
        isControlled: false,
        priceSantim: 1500,
      );

  group('a sale is never half-written', () {
    late LocalDb db;
    late Directory dir;
    late Outbox outbox;
    late SaleRepository sales;

    setUp(() async {
      final opened = await openTestDb();
      db = opened.db;
      dir = opened.dir;
      outbox = Outbox(db);
      sales = SaleRepository(db, outbox, CatalogRepository(db));
    });

    tearDown(() async {
      await db.close();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test(
        'a failure after the sale row but before the queue rolls back everything',
        () async {
      // The split-brain this guards against is the worst silent failure the system can have:
      // a sale recorded on the terminal but never queued would be invisible to the server
      // forever. The pharmacy's own records and the owner's reports would disagree, and
      // nothing anywhere would flag it — no sync error, no retry, no oversell.
      //
      // `outbox.terminal_seq` is UNIQUE, so planting the sequence number the next enqueue
      // will allocate makes the real `commitSale` fail at exactly that point, on the real
      // code path, rather than through a mock that could drift from it.
      await db.db.insert('outbox', {
        'op_id': 'planted',
        'terminal_seq': 1,
        'entity_type': 'sale',
        'entity_id': 'planted',
        'payload_json': '{}',
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'attempts': 0,
        'needs_attention': 0,
      });

      await expectLater(
        sales.commitSale(
          lines: [CartLine(product: product(), qty: 1, batchId: null)],
          tenantId: tenantId,
          branchId: branchId,
          cashierId: cashierId,
          terminalId: terminalId,
        ),
        throwsA(anything),
      );

      // Neither the sale nor its lines nor its payment may have survived the failure.
      expect((await db.db.query('sale')).length, 0,
          reason: 'a sale survived a transaction that did not complete');
      expect((await db.db.query('sale_line')).length, 0);
      expect((await db.db.query('payment')).length, 0);
    });

    test('and the terminal keeps selling once the obstruction is gone',
        () async {
      await db.db.insert('outbox', {
        'op_id': 'planted',
        'terminal_seq': 1,
        'entity_type': 'sale',
        'entity_id': 'planted',
        'payload_json': '{}',
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'attempts': 0,
        'needs_attention': 0,
      });
      await expectLater(
        sales.commitSale(
          lines: [CartLine(product: product(), qty: 1, batchId: null)],
          tenantId: tenantId,
          branchId: branchId,
          cashierId: cashierId,
          terminalId: terminalId,
        ),
        throwsA(anything),
      );

      // A failed write must not poison the terminal. The counter tries again, and the next
      // sale goes through with its outbox row — rolled back means rolled back, not wedged.
      await db.db.delete('outbox', where: 'op_id = ?', whereArgs: ['planted']);
      await sales.commitSale(
        lines: [CartLine(product: product(), qty: 1, batchId: null)],
        tenantId: tenantId,
        branchId: branchId,
        cashierId: cashierId,
        terminalId: terminalId,
      );

      expect((await db.db.query('sale')).length, 1);
      expect(await outbox.depth(), 1);
    });
  });

  group('corrupt-then-restart (docs/05 §7, ADR-018)', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('pharmaet_chaos_');
    });

    tearDown(() async {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    /// What a power cut during a write leaves behind: a file that is no longer a database.
    void corrupt(Directory at) {
      final file = File('${at.path}/pharmaet.db');
      final bytes = file.readAsBytesSync();
      for (var i = 0; i < 64 && i < bytes.length; i++) {
        bytes[i] = 0x00;
      }
      file.writeAsBytesSync(bytes);
    }

    Future<void> sellOnce(LocalDb db) async {
      final repo = SaleRepository(db, Outbox(db), CatalogRepository(db));
      await repo.commitSale(
        lines: [CartLine(product: product(), qty: 1, batchId: null)],
        tenantId: tenantId,
        branchId: branchId,
        cashierId: cashierId,
        terminalId: terminalId,
      );
    }

    test('the till still opens, which is the whole point', () async {
      final first = await openTestDb(reuse: dir);
      await sellOnce(first.db);
      await first.db.close();
      corrupt(dir);

      // Before ADR-018 this threw and the app could not start. A pharmacy that cannot open
      // its till has no workaround at a counter with a queue in front of it, and no amount
      // of preserved data is worth that.
      final reopened = await openTestDb(reuse: dir);
      expect(reopened.db.recoveredFromCorruption, isTrue);

      // And it is not merely open — it works. A database that opens but cannot take a sale
      // would be the same outage wearing a different error message.
      await sellOnce(reopened.db);
      expect((await reopened.db.db.query('sale')).length, 1);
      await reopened.db.close();
    });

    test('the unreadable file is kept, never deleted', () async {
      final first = await openTestDb(reuse: dir);
      await sellOnce(first.db);
      await first.db.close();
      corrupt(dir);

      final reopened = await openTestDb(reuse: dir);
      final quarantined = reopened.db.quarantinedFile;
      await reopened.db.close();

      // It holds whatever this terminal had not yet synced. Deleting it would turn a
      // recoverable incident into a certain loss, and the rows in it may be the only record
      // that those sales ever happened.
      expect(quarantined, isNotNull);
      expect(File(quarantined!).existsSync(), isTrue);
      expect(File(quarantined).lengthSync(), greaterThan(0));
    });

    test('the terminal knows it lost data, so it can say so', () async {
      final first = await openTestDb(reuse: dir);
      await sellOnce(first.db);
      await first.db.close();
      corrupt(dir);

      final reopened = await openTestDb(reuse: dir);
      // Silence here would be the product quietly reporting that a pharmacy had no sales —
      // worse than an error, because nobody would go looking.
      expect(reopened.db.recoveredFromCorruption, isTrue);
      await reopened.db.close();

      // A clean start must NOT claim to have recovered from anything, or the warning stops
      // meaning anything and staff learn to ignore it.
      final clean = await openTestDb();
      expect(clean.db.recoveredFromCorruption, isFalse);
      expect(clean.db.quarantinedFile, isNull);
      await clean.db.close();
      clean.dir.deleteSync(recursive: true);
    });

    test('the warning survives a restart, so it cannot be closed away',
        () async {
      final first = await openTestDb(reuse: dir);
      await sellOnce(first.db);
      await first.db.close();
      corrupt(dir);

      final recovered = await openTestDb(reuse: dir);
      expect(await recovered.db.pendingQuarantineNotice(), isNotNull);
      // Force-closed before anyone read it. That is an entirely ordinary thing to do to a
      // till that has just behaved strangely, and the person most likely to do it is the
      // one who most needs to see the warning.
      await recovered.db.close();

      final relaunched = await openTestDb(reuse: dir);
      expect(relaunched.db.recoveredFromCorruption, isFalse,
          reason: 'this launch found a perfectly good database');
      expect(await relaunched.db.pendingQuarantineNotice(), isNotNull,
          reason: 'restarting must not be a way to never see the warning');

      // And it clears when, and only when, a human has actually acknowledged it.
      await relaunched.db.acknowledgeQuarantine();
      await relaunched.db.close();

      final afterAck = await openTestDb(reuse: dir);
      expect(await afterAck.db.pendingQuarantineNotice(), isNull);
      await afterAck.db.close();
    });

    test('a second corruption does not overwrite the evidence of the first',
        () async {
      final first = await openTestDb(reuse: dir);
      await sellOnce(first.db);
      await first.db.close();
      corrupt(dir);

      final second = await openTestDb(reuse: dir);
      final firstQuarantine = second.db.quarantinedFile;
      await sellOnce(second.db);
      await second.db.close();

      // Same terminal, same failing storage, a week later. Two incidents must leave two
      // files: a scheme that reused one name would destroy the older evidence at exactly
      // the moment it became clear the hardware was the problem.
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      corrupt(dir);
      final third = await openTestDb(reuse: dir);
      final secondQuarantine = third.db.quarantinedFile;
      await third.db.close();

      expect(secondQuarantine, isNotNull);
      expect(secondQuarantine, isNot(equals(firstQuarantine)));
      expect(File(firstQuarantine!).existsSync(), isTrue);
      expect(File(secondQuarantine!).existsSync(), isTrue);
    });

    test('an error that is not corruption still propagates', () async {
      // The quarantine path renames the database aside. Applying that to a disk-full or
      // permission error would rename away a perfectly good database and *cause* the loss it
      // exists to contain, so the match is deliberately narrow.
      // A directory where the database file should be. SQLite cannot open it, and the
      // failure has nothing to do with the contents of any file — so quarantine must not
      // engage and the error must reach the caller.
      final blocked =
          await Directory.systemTemp.createTemp('pharmaet_blocked_');
      Directory('${blocked.path}/pharmaet.db').createSync();

      await expectLater(openTestDb(reuse: blocked), throwsA(anything));

      // Nothing was renamed aside: no `.corrupt-*` sibling was produced by a failure that
      // was never corruption.
      final strays = blocked
          .listSync()
          .where((e) => e.path.contains('.corrupt-'))
          .toList();
      expect(strays, isEmpty,
          reason: 'quarantine engaged on an error that was not corruption');
      blocked.deleteSync(recursive: true);
    });
  });
}
