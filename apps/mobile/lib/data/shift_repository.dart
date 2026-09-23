import '../core/ids.dart';
import 'local_db.dart';
import 'outbox.dart';

class ActiveShift {
  const ActiveShift({
    required this.id,
    required this.userId,
    required this.branchId,
    required this.openedAt,
    required this.openingFloatSantim,
  });

  final String id;
  final String userId;
  final String branchId;
  final DateTime openedAt;
  final int openingFloatSantim;
}

/// What the cashier is shown at count time (BR-8.2).
class ExpectedCash {
  const ExpectedCash({
    required this.openingFloatSantim,
    required this.cashTakenSantim,
    required this.saleCount,
    required this.unsyncedSaleCount,
  });

  final int openingFloatSantim;
  final int cashTakenSantim;
  final int saleCount;

  /// How many of those sales the server has not acknowledged yet.
  ///
  /// Shown to the cashier, because it is the honest caveat on the number: if some sales are
  /// still queued, the server's own figure will differ, and that difference is a finding
  /// rather than a fault (ADR-012 §3).
  final int unsyncedSaleCount;

  int get expectedSantim => openingFloatSantim + cashTakenSantim;
}

/// Shift lifecycle and cash-up, offline-first (FR-8).
///
/// Everything here follows the same rule as a sale: commit locally, queue, never wait on
/// the network. A pharmacy counts its till at close, which in this market is frequently
/// after the power has gone — a cash-up that needed connectivity would simply not happen.
class ShiftRepository {
  ShiftRepository(this._db, this._outbox);

  final LocalDb _db;
  final Outbox _outbox;

  Future<ActiveShift?> activeShift(String userId) async {
    final rows = await _db.db.query(
      'shift',
      where: 'user_id = ? AND closed_at IS NULL',
      whereArgs: [userId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return ActiveShift(
      id: r['id'] as String,
      userId: r['user_id'] as String,
      branchId: r['branch_id'] as String,
      openedAt: DateTime.parse(r['opened_at'] as String),
      openingFloatSantim: r['opening_float_santim'] as int,
    );
  }

  /// Opens a till session. Refuses a second one for the same user, because two open tills
  /// split the expected figure and neither reconciles.
  Future<ActiveShift> openShift({
    required String userId,
    required String branchId,
    required int openingFloatSantim,
  }) async {
    final existing = await activeShift(userId);
    if (existing != null) return existing;

    final id = newId();
    final openedAt = DateTime.now().toUtc();

    await _db.db.transaction((txn) async {
      await txn.insert('shift', {
        'id': id,
        'branch_id': branchId,
        'user_id': userId,
        'opened_at': openedAt.toIso8601String(),
        'closed_at': null,
        'opening_float_santim': openingFloatSantim,
        'synced': 0,
      });

      await _outbox.enqueue(
        txn,
        opId: newId(),
        entityType: 'shift',
        entityId: id,
        payload: {
          'userId': userId,
          'openedAt': openedAt.toIso8601String(),
          'closedAt': null,
          'openingFloatSantim': openingFloatSantim,
        },
      );
    });

    return ActiveShift(
      id: id,
      userId: userId,
      branchId: branchId,
      openedAt: openedAt,
      openingFloatSantim: openingFloatSantim,
    );
  }

  /// What the till should hold: opening float plus cash taken during the shift.
  ///
  /// **Cash only.** A sale settled by another recorded tender never reached the drawer, so
  /// counting it would manufacture a shortfall on every shift that took one — and a control
  /// that is always wrong is a control that gets switched off.
  Future<ExpectedCash> expectedCash(String shiftId) async {
    final shift = await _db.db
        .query('shift', where: 'id = ?', whereArgs: [shiftId], limit: 1);
    if (shift.isEmpty) throw StateError('unknown shift $shiftId');

    final row = await _db.db.rawQuery(
      '''
      SELECT coalesce(sum(p.amount_santim), 0) AS cash,
             count(DISTINCT s.id)              AS sales,
             coalesce(sum(CASE WHEN s.synced = 0 THEN 1 ELSE 0 END), 0) AS unsynced
        FROM sale s
        JOIN payment p ON p.sale_id = s.id
       WHERE s.shift_id = ? AND p.method = 'cash'
      ''',
      [shiftId],
    );

    return ExpectedCash(
      openingFloatSantim: shift.first['opening_float_santim'] as int,
      cashTakenSantim: (row.first['cash'] as int?) ?? 0,
      saleCount: (row.first['sales'] as int?) ?? 0,
      unsyncedSaleCount: (row.first['unsynced'] as int?) ?? 0,
    );
  }

  /// Records the count and closes the shift, in one local transaction (AC-8.1).
  ///
  /// The expected figure stored here is the one the cashier was **shown**. The server
  /// recomputes its own on arrival and keeps it separately; neither overwrites the other,
  /// because this row is the record of what a person agreed to at a moment in time
  /// (ADR-012 §3).
  Future<int> closeShiftWithCashUp({
    required ActiveShift shift,
    required int countedSantim,
    String? note,
  }) async {
    final expected = await expectedCash(shift.id);
    final variance = countedSantim - expected.expectedSantim;
    final countedAt = DateTime.now().toUtc();
    final cashUpId = newId();

    await _db.db.transaction((txn) async {
      await txn.insert('cash_up', {
        'id': cashUpId,
        'shift_id': shift.id,
        'user_id': shift.userId,
        'counted_at': countedAt.toIso8601String(),
        'expected_santim': expected.expectedSantim,
        'counted_santim': countedSantim,
        'variance_santim': variance,
        'note': note,
        'synced': 0,
      });

      await txn.update(
        'shift',
        {'closed_at': countedAt.toIso8601String()},
        where: 'id = ?',
        whereArgs: [shift.id],
      );

      // The close is pushed as an update to the shift the server already has, then the
      // cash-up. Order matters: the server refuses a cash-up whose shift has not arrived,
      // and terminal_seq is what guarantees that order survives the trip.
      await _outbox.enqueue(
        txn,
        opId: newId(),
        entityType: 'shift',
        entityId: shift.id,
        payload: {
          'userId': shift.userId,
          'openedAt': shift.openedAt.toIso8601String(),
          'closedAt': countedAt.toIso8601String(),
          'openingFloatSantim': shift.openingFloatSantim,
        },
      );

      await _outbox.enqueue(
        txn,
        opId: newId(),
        entityType: 'cash_up',
        entityId: cashUpId,
        payload: {
          'shiftId': shift.id,
          'userId': shift.userId,
          'countedAt': countedAt.toIso8601String(),
          'expectedSantim': expected.expectedSantim,
          'countedSantim': countedSantim,
          'varianceSantim': variance,
          'note': note,
        },
      );
    });

    return variance;
  }

  Future<List<Map<String, Object?>>> recentCashUps({int limit = 10}) =>
      _db.db.query(
        'cash_up',
        orderBy: 'counted_at DESC',
        limit: limit,
      );
}
