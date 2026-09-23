import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../contracts/contracts.dart';
import 'local_db.dart';

/// A pending operation, as it sits on the device.
class OutboxEntry {
  const OutboxEntry({
    required this.opId,
    required this.terminalSeq,
    required this.entityType,
    required this.entityId,
    required this.payload,
    required this.createdAt,
    required this.attempts,
    required this.needsAttention,
    this.lastError,
  });

  final String opId;
  final int terminalSeq;
  final String entityType;
  final String entityId;
  final Map<String, dynamic> payload;
  final String createdAt;
  final int attempts;
  final bool needsAttention;
  final String? lastError;

  static OutboxEntry fromRow(Map<String, Object?> row) => OutboxEntry(
        opId: row['op_id'] as String,
        terminalSeq: row['terminal_seq'] as int,
        entityType: row['entity_type'] as String,
        entityId: row['entity_id'] as String,
        payload:
            jsonDecode(row['payload_json'] as String) as Map<String, dynamic>,
        createdAt: row['created_at'] as String,
        attempts: row['attempts'] as int,
        needsAttention: (row['needs_attention'] as int) == 1,
        lastError: row['last_error'] as String?,
      );
}

/// The append-only outbox (ADR-002).
///
/// Ordering is by `terminal_seq`, a monotonic counter, never by a timestamp: a device clock
/// can drift or be reset by the user, and a goods receipt ordered after the sale that
/// consumed its stock produces nonsense the server cannot untangle (ADR-006).
///
/// The counter is allocated inside the same transaction that writes the operation, so a
/// crash between the two is impossible — there is no window in which a sale exists with no
/// sequence number, or a sequence number is burnt with no sale.
class Outbox {
  Outbox(this._db);

  final LocalDb _db;

  static const _seqKey = 'terminal_seq';

  /// Enqueues an operation. Must be called inside the same transaction that persisted the
  /// entity itself, so that "the sale is committed" and "the sale will sync" are one fact.
  Future<int> enqueue(
    DatabaseExecutor txn, {
    required String opId,
    required String entityType,
    required String entityId,
    required Map<String, dynamic> payload,
  }) async {
    final seq = await _nextSeq(txn);
    await txn.insert('outbox', {
      'op_id': opId,
      'terminal_seq': seq,
      'entity_type': entityType,
      'entity_id': entityId,
      'payload_json': jsonEncode(payload),
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'attempts': 0,
      'needs_attention': 0,
    });
    return seq;
  }

  Future<int> _nextSeq(DatabaseExecutor txn) async {
    final rows = await txn.query('meta',
        where: 'key = ?', whereArgs: [_seqKey], limit: 1);
    final current = rows.isEmpty ? 0 : int.parse(rows.first['value'] as String);
    final next = current + 1;
    await txn.insert(
      'meta',
      {'key': _seqKey, 'value': next.toString()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return next;
  }

  /// The next batch to push, oldest first.
  ///
  /// Operations already parked for human attention are skipped: they would only be rejected
  /// again, and retrying them forever would block everything behind them.
  Future<List<OutboxEntry>> pending({int limit = 200}) async {
    final rows = await _db.db.query(
      'outbox',
      where: 'needs_attention = 0',
      orderBy: 'terminal_seq ASC',
      limit: limit,
    );
    return rows.map(OutboxEntry.fromRow).toList();
  }

  Future<int> depth() async {
    final rows = await _db.db.rawQuery('SELECT count(*) AS n FROM outbox');
    return (rows.first['n'] as int?) ?? 0;
  }

  Future<int> attentionCount() async {
    final rows = await _db.db.rawQuery(
      'SELECT count(*) AS n FROM outbox WHERE needs_attention = 1',
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  /// Applies the server's acknowledgements.
  ///
  /// `applied` and `duplicate` both clear the entry: duplicate means the server already has
  /// it, which is exactly what a retry after a dropped connection looks like, and is a
  /// success, not an error (AC-9.2).
  ///
  /// `rejected` does NOT clear it. The operation is flagged for human attention and kept,
  /// because a transaction the server would not take is a conversation with a person, not
  /// something to discard.
  Future<void> applyAcks(List<Ack> acks) async {
    await _db.db.transaction((txn) async {
      for (final ack in acks) {
        // Read the entity the operation referred to BEFORE removing the row — afterwards
        // there is nothing left to look it up from.
        final rows = await txn.query(
          'outbox',
          columns: ['entity_id', 'entity_type'],
          where: 'op_id = ?',
          whereArgs: [ack.opId],
          limit: 1,
        );
        final entityId =
            rows.isEmpty ? null : rows.first['entity_id'] as String;
        final entityType =
            rows.isEmpty ? null : rows.first['entity_type'] as String;

        switch (ack.status) {
          case 'applied':
          case 'duplicate':
            await txn
                .delete('outbox', where: 'op_id = ?', whereArgs: [ack.opId]);
            if (entityId != null && entityType == 'sale') {
              await txn.update(
                'sale',
                {'synced': 1},
                where: 'id = ?',
                whereArgs: [entityId],
              );
            }
          case 'rejected':
            await txn.update(
              'outbox',
              {
                'needs_attention': 1,
                'last_error': ack.reason ?? 'rejected by server',
                'attempts': 1,
              },
              where: 'op_id = ?',
              whereArgs: [ack.opId],
            );
          default:
            // An unknown status from a newer server. Keep the entry and try again later
            // rather than guessing: dropping it would lose the transaction permanently.
            break;
        }
      }
    });
  }

  /// Records a failed attempt without removing anything.
  ///
  /// Network failures are the normal case here, not an exception — the counter is expected
  /// to run for days without connectivity.
  Future<void> recordFailure(List<OutboxEntry> entries, String error) async {
    await _db.db.transaction((txn) async {
      for (final entry in entries) {
        await txn.update(
          'outbox',
          {'attempts': entry.attempts + 1, 'last_error': error},
          where: 'op_id = ?',
          whereArgs: [entry.opId],
        );
      }
    });
  }
}
