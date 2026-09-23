import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/core/money.dart';
import 'package:pharmaet_mobile/data/catalog_repository.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/data/outbox.dart';
import 'package:pharmaet_mobile/data/sale_repository.dart';

import '../support/test_db.dart';

/// G4 — MONEY INTEGRITY, device half (docs/05-qa §4).
///
/// Money is an integer count of santim from the tap on the screen to the row in Postgres.
/// A money error is an S1 and, unlike a crash, it is invisible: a few santim of drift per
/// sale goes unnoticed for months and then the till does not reconcile.
void main() {
  late LocalDb db;
  late Directory dir;
  late SaleRepository sales;

  const tenantId = '01930000-0000-7000-8000-000000000001';
  const branchId = '01930000-0000-7000-8000-000000000002';
  const cashierId = '01930000-0000-7000-8000-000000000003';
  const terminalId = '01930000-0000-7000-8000-000000000004';

  LocalProduct priced(int santim) => LocalProduct(
        id: '01930000-0000-7000-8000-00000000000a',
        name: 'Test product',
        unit: 'tablet',
        isControlled: false,
        priceSantim: santim,
      );

  setUp(() async {
    final opened = await openTestDb();
    db = opened.db;
    dir = opened.dir;
    final outbox = Outbox(db);
    sales = SaleRepository(db, outbox, CatalogRepository(db));
  });

  tearDown(() async {
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('formatting', () {
    test('divides to birr exactly once, at the edge', () {
      expect(formatEtb(1999), '19.99 ETB');
      expect(formatEtb(150), '1.50 ETB');
      expect(formatEtb(5), '0.05 ETB');
      expect(formatEtb(0), '0.00 ETB');
    });

    test('keeps large totals exact where a double would not', () {
      expect(formatEtb(123456789), '1,234,567.89 ETB');
      // 8,999,999.99 ETB. A float pipeline loses the last santim here.
      expect(formatEtb(899999999), '8,999,999.99 ETB');
    });

    test('puts the sign outside the value', () {
      expect(formatEtb(-2550), '-25.50 ETB');
    });
  });

  group('arithmetic', () {
    test('line totals are integer products', () {
      expect(lineTotalSantim(qty: 3, unitPriceSantim: 1999), 5997);
      expect(lineTotalSantim(qty: 7, unitPriceSantim: 733), 5131);
    });

    test('a committed sale total equals the sum of its lines', () async {
      final sale = await sales.commitSale(
        lines: [
          CartLine(product: priced(1999), qty: 3, batchId: null),
          CartLine(product: priced(733), qty: 7, batchId: null),
        ],
        tenantId: tenantId,
        branchId: branchId,
        cashierId: cashierId,
        terminalId: terminalId,
      );

      // Two lines on the same product id merge into one row in this fixture; what matters
      // is that the stored total and the stored lines agree.
      final rows = await db.db.rawQuery(
        'SELECT s.total_santim AS total, sum(l.line_total_santim) AS lines '
        'FROM sale s JOIN sale_line l ON l.sale_id = s.id WHERE s.id = ? GROUP BY s.id',
        [sale.saleId],
      );
      expect(rows.first['total'], rows.first['lines']);
    });

    test('money is stored as an integer column, not a real', () async {
      await sales.commitSale(
        lines: [CartLine(product: priced(1999), qty: 3, batchId: null)],
        tenantId: tenantId,
        branchId: branchId,
        cashierId: cashierId,
        terminalId: terminalId,
      );

      final rows = await db.db.rawQuery(
        "SELECT typeof(total_santim) AS t, total_santim AS v FROM sale",
      );
      expect(rows.first['t'], 'integer');
      expect(rows.first['v'], 5997);
    });

    test('the queued payload carries integers, not decimals', () async {
      await sales.commitSale(
        lines: [CartLine(product: priced(1999), qty: 3, batchId: null)],
        tenantId: tenantId,
        branchId: branchId,
        cashierId: cashierId,
        terminalId: terminalId,
      );

      final entry = (await Outbox(db).pending()).single;
      expect(entry.payload['totalSantim'], isA<int>());
      final lines = (entry.payload['lines'] as List<dynamic>).cast<Map<String, dynamic>>();
      expect(lines.first['unitPriceSantim'], isA<int>());
      expect(lines.first['lineTotalSantim'], isA<int>());
    });
  });
}
