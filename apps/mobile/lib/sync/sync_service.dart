import '../contracts/contracts.dart';
import '../data/catalog_repository.dart';
import '../data/local_db.dart';
import '../data/outbox.dart';
import '../data/sale_repository.dart';
import 'sync_client.dart';

enum SyncState { idle, syncing, synced, offline, needsAttention }

class SyncStatus {
  const SyncStatus({
    required this.state,
    required this.pending,
    required this.needsAttention,
    this.lastSyncedAt,
    this.message,
  });

  final SyncState state;
  final int pending;
  final int needsAttention;
  final DateTime? lastSyncedAt;
  final String? message;
}

/// Drains the outbox and applies pulled deltas (docs/04 §7).
///
/// The contract this class keeps, and the reason it is written the way it is:
///
///   - It NEVER deletes an operation the server did not acknowledge. A timeout, a 500, a
///     parse failure — all of them leave the outbox exactly as it was. The only thing that
///     removes a sale from this device is the server saying it has it.
///
///   - A retry re-sends everything unacknowledged, including operations that may already
///     have landed. That is safe by construction: the server keys idempotency on `opId` and
///     answers `duplicate`, which the outbox treats as success (AC-9.2).
///
///   - Push happens before pull. Our local writes are the authority for what happened at
///     the counter; pulled reference data is a correction to what we believe about stock.
///     Doing it the other way round would briefly overwrite stock levels with a server view
///     that has not yet heard about this morning's sales.
class SyncService {
  SyncService({
    required LocalDb db,
    required Outbox outbox,
    required SyncClient client,
    required CatalogRepository catalog,
    required SaleRepository sales,
  })  : _db = db,
        _outbox = outbox,
        _client = client,
        _catalog = catalog,
        _sales = sales;

  final LocalDb _db;
  final Outbox _outbox;
  final SyncClient _client;
  final CatalogRepository _catalog;
  final SaleRepository _sales;

  DateTime? _lastSyncedAt;

  Future<SyncStatus> status() async => SyncStatus(
        state: await _outbox.depth() == 0 ? SyncState.synced : SyncState.idle,
        pending: await _outbox.depth(),
        needsAttention: await _outbox.attentionCount(),
        lastSyncedAt: _lastSyncedAt,
      );

  /// One full sync cycle. Safe to call at any time, including with no connectivity — a
  /// failure is reported, never thrown at the UI, because the counter must keep working.
  Future<SyncStatus> sync({
    required String token,
    required String tenantId,
    required String branchId,
    required String actorId,
    required String terminalId,
  }) async {
    final pending = await _outbox.pending();

    if (pending.isNotEmpty) {
      final operations = <Operation>[
        for (final entry in pending)
          if (entry.entityType == 'sale')
            _sales.toOperation(
              entry,
              tenantId: tenantId,
              branchId: branchId,
              actorId: actorId,
              terminalId: terminalId,
            ),
      ];

      try {
        final response = await _client.push(
          token: token,
          terminalId: terminalId,
          operations: operations,
        );
        await _outbox.applyAcks(response.acks);
      } on SyncTransportException catch (error) {
        // Nothing is removed. The queue is exactly as deep as it was, and every sale in it
        // is still on this device.
        await _outbox.recordFailure(pending, error.message);
        return SyncStatus(
          state: SyncState.offline,
          pending: await _outbox.depth(),
          needsAttention: await _outbox.attentionCount(),
          lastSyncedAt: _lastSyncedAt,
          message: error.message,
        );
      }
    }

    try {
      var cursor = int.tryParse(await _db.meta('pull_cursor') ?? '0') ?? 0;
      var pages = 0;
      while (pages < 20) {
        final response = await _client.pull(token: token, cursor: cursor, branchId: branchId);
        await _catalog.applyPull(response);
        cursor = response.cursor;
        pages++;
        // A full page means more rows are waiting. Keep going rather than running on half a
        // catalog until the next sync window (docs/04 §7.2).
        if (!response.hasMore) break;
      }
      _lastSyncedAt = DateTime.now();
    } on SyncTransportException catch (error) {
      return SyncStatus(
        state: SyncState.offline,
        pending: await _outbox.depth(),
        needsAttention: await _outbox.attentionCount(),
        lastSyncedAt: _lastSyncedAt,
        message: error.message,
      );
    }

    final depth = await _outbox.depth();
    final attention = await _outbox.attentionCount();
    return SyncStatus(
      state: attention > 0
          ? SyncState.needsAttention
          : depth == 0
              ? SyncState.synced
              : SyncState.idle,
      pending: depth,
      needsAttention: attention,
      lastSyncedAt: _lastSyncedAt,
    );
  }
}
