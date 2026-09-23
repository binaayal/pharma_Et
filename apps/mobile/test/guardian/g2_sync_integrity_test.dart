import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/contracts/contracts.dart';
import 'package:pharmaet_mobile/data/catalog_repository.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/data/outbox.dart';
import 'package:pharmaet_mobile/data/sale_repository.dart';

import '../support/test_db.dart';

/// G2 — SYNC INTEGRITY, client half (docs/05-qa §4; AC-9.1, AC-9.2).
///
/// The server proves exactly-once on its side. What the device must prove is the other
/// half of the same contract: that it removes an operation from the outbox for exactly one
/// reason — the server said it has it — and for no other reason, ever.
void main() {
  late LocalDb db;
  late Directory dir;
  late Outbox outbox;
  late SaleRepository sales;

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

  Future<void> commit({int count = 1}) async {
    for (var i = 0; i < count; i++) {
      await sales.commitSale(
        lines: [CartLine(product: product, qty: 1, batchId: null)],
        tenantId: tenantId,
        branchId: branchId,
        cashierId: cashierId,
        terminalId: terminalId,
      );
    }
  }

  Ack ack(String opId, String status, {String? reason}) =>
      Ack(opId: opId, status: status, serverVersion: 1, reason: reason);

  test('an "applied" ack clears the entry and marks the sale synced', () async {
    await commit();
    final entry = (await outbox.pending()).single;

    await outbox.applyAcks([ack(entry.opId, 'applied')]);

    expect(await outbox.depth(), 0);
    expect(await sales.unsyncedCount(), 0);
  });

  test('a "duplicate" ack is success, not an error', () async {
    // This is what a retry after a dropped connection looks like. Treating it as a failure
    // would leave the sale in the outbox forever, re-sent on every sync, for no reason.
    await commit();
    final entry = (await outbox.pending()).single;

    await outbox.applyAcks([ack(entry.opId, 'duplicate')]);

    expect(await outbox.depth(), 0);
    expect(await sales.unsyncedCount(), 0);
  });

  test('a "rejected" ack keeps the operation and flags it for a person',
      () async {
    // A rejected transaction is a conversation with a human, not something to discard. The
    // money was taken; somebody has to decide what happens to it.
    await commit();
    final entry = (await outbox.pending()).single;

    await outbox
        .applyAcks([ack(entry.opId, 'rejected', reason: 'branch not found')]);

    expect(await outbox.depth(), 1);
    expect(await outbox.attentionCount(), 1);
    // And it stops being retried, so it cannot block the sales queued behind it.
    expect(await outbox.pending(), isEmpty);
  });

  test('an unrecognised ack status leaves the operation untouched', () async {
    // A newer server saying something this build does not understand. Keeping the entry
    // costs one redundant retry; guessing could throw away a real sale.
    await commit();
    final entry = (await outbox.pending()).single;

    await outbox.applyAcks([ack(entry.opId, 'quarantined')]);

    expect(await outbox.depth(), 1);
    expect(await outbox.attentionCount(), 0);
  });

  test('a partial ack clears only what was acknowledged', () async {
    await commit(count: 5);
    final pending = await outbox.pending();

    await outbox.applyAcks([
      ack(pending[0].opId, 'applied'),
      ack(pending[1].opId, 'duplicate'),
    ]);

    expect(await outbox.depth(), 3);
    final remaining =
        (await outbox.pending()).map((e) => e.terminalSeq).toList();
    expect(remaining, [3, 4, 5]);
  });

  test('operations are handed over in terminal_seq order, never by time',
      () async {
    await commit(count: 12);
    final seqs = (await outbox.pending()).map((e) => e.terminalSeq).toList();
    expect(seqs, List<int>.generate(12, (i) => i + 1));
  });

  test('the built envelope round-trips through the generated contract types',
      () async {
    await commit();
    final entry = (await outbox.pending()).single;

    final operation = sales.toOperation(
      entry,
      tenantId: tenantId,
      branchId: branchId,
      actorId: cashierId,
      terminalId: terminalId,
    );

    // If the client and server disagree about this shape, transactions are silently lost.
    // Round-tripping through the generated parser is the cheapest proof that they do not.
    final reparsed = Operation.fromJson(operation.toJson());
    expect(reparsed, isA<OperationSale>());
    expect((reparsed as OperationSale).opId, entry.opId);
    expect(reparsed.terminalSeq, entry.terminalSeq);
    expect(reparsed.payload.totalSantim, 1500);
    expect(reparsed.opType, 'create');
  });

  test('the envelope carries the contract version this build speaks (ADR-009)',
      () {
    expect(kContractVersion, isNotEmpty);
    expect(kContractVersion, matches(RegExp(r'^\d+\.\d+\.\d+$')));
  });
}
