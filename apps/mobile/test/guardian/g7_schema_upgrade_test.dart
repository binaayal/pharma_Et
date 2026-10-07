import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pharmaet_mobile/contracts/contracts.dart';
import 'package:pharmaet_mobile/data/catalog_repository.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/data/outbox.dart';
import 'package:pharmaet_mobile/data/sale_repository.dart';
import 'package:pharmaet_mobile/data/shift_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// G7 — A SCHEMA UPGRADE MUST NOT LOSE A QUEUED TRANSACTION (NFR-1.3).
///
/// This is the scenario nobody rehearses and everybody eventually hits: a pharmacy updates
/// the app while the till is holding two days of sales that have never reached the server.
/// Those rows are the only copy of that money. An upgrade that rewrites or drops a table —
/// the ordinary way people evolve a local schema — destroys them, and there is no backup,
/// because the whole point of the outbox is that the server has not seen them yet.
///
/// So the rule is: upgrades are additive only. This test is what holds that rule in place.
void main() {
  const branchId = '01930000-0000-7000-8000-000000000002';
  const cashierId = '01930000-0000-7000-8000-000000000003';

  /// Builds a database exactly as version 1 shipped it — no shift tables, no sale.shift_id.
  Future<void> writeV1Database(String path) async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 1),
    );

    await db.execute('''
      CREATE TABLE product (
        id TEXT PRIMARY KEY, name TEXT NOT NULL, unit TEXT NOT NULL,
        is_controlled INTEGER NOT NULL DEFAULT 0, price_santim INTEGER NOT NULL,
        change_seq INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0)
    ''');
    await db.execute('''
      CREATE TABLE stock_batch (
        id TEXT PRIMARY KEY, branch_id TEXT NOT NULL, product_id TEXT NOT NULL,
        lot_no TEXT NOT NULL, expiry_date TEXT NOT NULL, qty_on_hand INTEGER NOT NULL,
        change_seq INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0)
    ''');
    await db.execute('''
      CREATE TABLE sale (
        id TEXT PRIMARY KEY, branch_id TEXT NOT NULL, cashier_id TEXT NOT NULL,
        total_santim INTEGER NOT NULL, sold_at TEXT NOT NULL,
        synced INTEGER NOT NULL DEFAULT 0)
    ''');
    await db.execute('''
      CREATE TABLE sale_line (
        id TEXT PRIMARY KEY, sale_id TEXT NOT NULL REFERENCES sale(id),
        product_id TEXT NOT NULL, batch_id TEXT, qty INTEGER NOT NULL,
        unit_price_santim INTEGER NOT NULL, line_total_santim INTEGER NOT NULL)
    ''');
    await db.execute('''
      CREATE TABLE payment (
        id TEXT PRIMARY KEY, sale_id TEXT NOT NULL REFERENCES sale(id),
        method TEXT NOT NULL, amount_santim INTEGER NOT NULL)
    ''');
    await db.execute('''
      CREATE TABLE outbox (
        op_id TEXT PRIMARY KEY, terminal_seq INTEGER NOT NULL UNIQUE,
        entity_type TEXT NOT NULL, entity_id TEXT NOT NULL, payload_json TEXT NOT NULL,
        created_at TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT,
        needs_attention INTEGER NOT NULL DEFAULT 0)
    ''');
    await db.execute(
        'CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)');

    // Two days of trade the server has never seen.
    for (var i = 0; i < 40; i++) {
      final saleId = 'sale-$i';
      await db.insert('sale', {
        'id': saleId,
        'branch_id': branchId,
        'cashier_id': cashierId,
        'total_santim': 1500,
        'sold_at': '2026-09-21T09:00:00.000Z',
        'synced': 0,
      });
      await db.insert('payment', {
        'id': 'pay-$i',
        'sale_id': saleId,
        'method': 'cash',
        'amount_santim': 1500,
      });
      await db.insert('outbox', {
        'op_id': 'op-$i',
        'terminal_seq': i + 1,
        'entity_type': 'sale',
        'entity_id': saleId,
        'payload_json': '{"totalSantim":1500}',
        'created_at': '2026-09-21T09:00:00.000Z',
        'attempts': 3,
        'needs_attention': 0,
      });
    }
    await db.insert('meta', {'key': 'terminal_seq', 'value': '40'});
    await db.insert('meta', {'key': 'pull_cursor', 'value': '77'});
    await db.close();
  }

  test('upgrading from v1 keeps every queued sale and the sequence counter',
      () async {
    final dir = await Directory.systemTemp.createTemp('pharmaet_upgrade_');
    final path = p.join(dir.path, 'pharmaet.db');
    await writeV1Database(path);

    // The update lands and the app opens the existing file.
    final db =
        await LocalDb.open(factory: databaseFactoryFfi, directory: dir.path);
    final outbox = Outbox(db);
    final sales = SaleRepository(db, outbox, CatalogRepository(db));

    // Not one of the forty may go missing. They are the only copy of that money.
    expect(await outbox.depth(), 40);
    expect(await sales.unsyncedCount(), 40);

    // The pull cursor survives too: losing it would re-pull the whole catalog, which on a
    // metered connection in the field is a real cost, not a nuisance.
    expect(await db.meta('pull_cursor'), '77');

    // And the sequence counter, which is the ordering key. If it restarted, the next
    // operation would collide with one already queued and a sale would be lost the moment
    // they were pushed.
    final shifts = ShiftRepository(db, outbox);
    final shift = await shifts.openShift(
      userId: cashierId,
      branchId: branchId,
      openingFloatSantim: 0,
    );
    final seqs =
        (await outbox.pending(limit: 200)).map((e) => e.terminalSeq).toList();
    expect(seqs.length, 41);
    expect(seqs.toSet().length, 41,
        reason: 'terminal_seq must stay unique across upgrade');
    expect(seqs.last, 41);

    // The new capability works on the upgraded database.
    expect(shift.id, isNotEmpty);
    final expected = await shifts.expectedCash(shift.id);
    // The pre-upgrade sales carry no shift, so they are correctly not counted against it.
    expect(expected.cashTakenSantim, 0);

    await db.close();
    dir.deleteSync(recursive: true);
  });

  test('a fresh install and an upgraded install end up with the same schema',
      () async {
    // Otherwise the two populations diverge and a bug reproduces on only one of them —
    // the kind of thing that costs a week to find.
    Future<Set<String>> columnsOf(LocalDb db, String table) async {
      final rows = await db.db.rawQuery('PRAGMA table_info($table)');
      return rows.map((r) => r['name'] as String).toSet();
    }

    final freshDir = await Directory.systemTemp.createTemp('pharmaet_fresh_');
    final fresh = await LocalDb.open(
        factory: databaseFactoryFfi, directory: freshDir.path);

    final upgradedDir =
        await Directory.systemTemp.createTemp('pharmaet_upgraded_');
    await writeV1Database(p.join(upgradedDir.path, 'pharmaet.db'));
    final upgraded = await LocalDb.open(
        factory: databaseFactoryFfi, directory: upgradedDir.path);

    for (final table in [
      'sale',
      'shift',
      'cash_up',
      'outbox',
      // FR-11 added columns to these three; an upgraded till must have every one of them.
      'product',
      'sale_line',
      'goods_receipt_line',
      // FR-16 added these two tables, and a column to `sale` above.
      'customer',
      'credit_payment',
      // FR-18 added these two tables, and two columns to a receipt.
      'supplier',
      'supplier_payment',
      'goods_receipt',
    ]) {
      expect(
        await columnsOf(upgraded, table),
        await columnsOf(fresh, table),
        reason: '$table differs between a fresh install and an upgraded one',
      );
    }

    await fresh.close();
    await upgraded.close();
    freshDir.deleteSync(recursive: true);
    upgradedDir.deleteSync(recursive: true);
  });

  test('an upgraded till sells by the pack, and its old sales read as loose',
      () async {
    // FR-11 (schema v5). The forty queued sales were rung up before packs existed. They
    // must come through untouched, and "no pack" on them must read as what it was — the
    // base unit — not as an error or a pack of zero.
    final dir =
        await Directory.systemTemp.createTemp('pharmaet_upgrade_packs_');
    final path = p.join(dir.path, 'pharmaet.db');
    await writeV1Database(path);
    {
      final raw = await databaseFactoryFfi.openDatabase(path);
      await raw.insert('sale_line', {
        'id': 'line-0',
        'sale_id': 'sale-0',
        'product_id': 'prod-1',
        'batch_id': null,
        'qty': 3,
        'unit_price_santim': 500,
        'line_total_santim': 1500,
      });
      await raw.close();
    }

    final db =
        await LocalDb.open(factory: databaseFactoryFfi, directory: dir.path);
    final outbox = Outbox(db);
    final sales = SaleRepository(db, outbox, CatalogRepository(db));

    expect(await outbox.depth(), 40);
    final old =
        await db.db.query('sale_line', where: 'id = ?', whereArgs: ['line-0']);
    expect(old.single['qty'], 3);
    expect(old.single['pack_size'], isNull);
    expect((await sales.linesOf('sale-0')).single.packName, isNull);

    // And the new capability works on the same file.
    const box = ProductPack(name: 'box', size: 30, priceSantim: 10000);
    final sale = await sales.commitSale(
      lines: [
        CartLine(
          product: const LocalProduct(
            id: '01930000-0000-7000-8000-00000000000a',
            name: 'Amoxicillin',
            unit: 'capsule',
            isControlled: false,
            priceSantim: 400,
            packs: [box],
          ),
          qty: 2,
          batchId: null,
          pack: box,
        ),
      ],
      tenantId: '01930000-0000-7000-8000-000000000001',
      branchId: branchId,
      cashierId: cashierId,
      terminalId: '01930000-0000-7000-8000-000000000004',
    );
    expect(sale.totalSantim, 20000);
    expect(await outbox.depth(), 41);

    await db.close();
    dir.deleteSync(recursive: true);
  });
}
