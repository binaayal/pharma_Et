import 'package:pharmaet_mobile/data/local_db.dart';

/// Latency measurement for NFR-3.2, shared by the CI regression guard and the on-device run.
///
/// It lives in one file because the two must measure the *same* thing. A device number and a
/// CI number produced by subtly different code are not comparable, and the whole point of the
/// device matrix is to compare them.

/// The result of timing one operation many times.
class LatencySample {
  LatencySample(this.name, List<int> microseconds)
      : _sorted = (List<int>.of(microseconds)..sort());

  final String name;
  final List<int> _sorted;

  int get count => _sorted.length;

  /// Percentiles in **microseconds**, because at a 100 ms budget a millisecond-resolution
  /// clock rounds most of the measurement away — a 0 ms reading is not a fast operation, it
  /// is an unmeasured one.
  int percentileUs(double fraction) {
    if (_sorted.isEmpty) return 0;
    // Nearest-rank. With 100 samples p95 is the 95th slowest, which is what "95% of counter
    // taps were at least this fast" actually means.
    final rank = (fraction * _sorted.length).ceil().clamp(1, _sorted.length);
    return _sorted[rank - 1];
  }

  double get p50Ms => percentileUs(0.50) / 1000;
  double get p95Ms => percentileUs(0.95) / 1000;
  double get maxMs => _sorted.last / 1000;

  /// One line per operation, in a form both a human and `scripts/device-matrix.sh` can read.
  String get report => '$name  n=$count  '
      'p50=${p50Ms.toStringAsFixed(1)}ms  '
      'p95=${p95Ms.toStringAsFixed(1)}ms  '
      'max=${maxMs.toStringAsFixed(1)}ms';
}

/// Times [body] [iterations] times, after [warmup] untimed runs.
///
/// The warm-up is not cosmetic. The first call pays for lazy table opens, query-plan
/// preparation and (on a device) the JIT; including it would report a number no cashier ever
/// experiences, on the one operation they only perform once.
Future<LatencySample> measure(
  String name,
  Future<void> Function(int i) body, {
  int iterations = 100,
  int warmup = 10,
}) async {
  for (var i = 0; i < warmup; i++) {
    await body(-1 - i);
  }

  final samples = <int>[];
  final watch = Stopwatch();
  for (var i = 0; i < iterations; i++) {
    watch
      ..reset()
      ..start();
    await body(i);
    watch.stop();
    samples.add(watch.elapsedMicroseconds);
  }
  return LatencySample(name, samples);
}

/// A catalogue the size of a real pharmacy's, so the measurement is not taken against a
/// table small enough to live entirely in one page.
///
/// `productCount` defaults to 500 — larger than the shops this ships to first, on purpose:
/// a budget that only holds for a small shop is not a budget.
Future<List<String>> seedCatalogue(
  LocalDb db, {
  required String branchId,
  int productCount = 500,
  int batchesPerProduct = 3,
}) async {
  final productIds = <String>[];

  await db.db.transaction((txn) async {
    for (var p = 0; p < productCount; p++) {
      final productId = _id(0x1000 + p);
      productIds.add(productId);
      await txn.insert('product', {
        'id': productId,
        'name': 'Product ${p.toString().padLeft(4, '0')}',
        'unit': 'tablet',
        'is_controlled': 0,
        'price_santim': 1000 + p,
        'deleted': 0,
      });

      for (var b = 0; b < batchesPerProduct; b++) {
        await txn.insert('stock_batch', {
          'id': _id(0x200000 + p * 16 + b),
          'branch_id': branchId,
          'product_id': productId,
          'lot_no': 'LOT-$p-$b',
          // Spread across years so FEFO has to actually order, rather than returning the
          // only row that matched.
          'expiry_date': '202${7 + (b % 3)}-0${1 + (b % 9)}-15',
          'qty_on_hand': 100,
          'deleted': 0,
        });
      }
    }
  });

  return productIds;
}

String _id(int tag) =>
    '01930000-0000-7000-8000-${tag.toRadixString(16).padLeft(12, '0')}';
