import '../contracts/contracts.dart';
import '../data/catalog_repository.dart';
import '../data/local_db.dart';
import '../data/outbox.dart';
import '../data/inventory_repository.dart';
import '../data/sale_repository.dart';
import 'sync_client.dart';

/// `sessionExpired` is deliberately NOT `offline` (ADR-019).
///
/// Before it existed, an expired access token produced a 401 that this service reported as
/// `offline` — indistinguishable from a network outage, which is a state this product is
/// designed to tolerate and a cashier is trained to ignore. The terminal stopped syncing
/// fifteen minutes after login, kept taking sales, and nobody had any reason to look.
enum SyncState {
  idle,
  syncing,
  synced,
  offline,
  needsAttention,
  sessionExpired
}

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
    required InventoryRepository inventory,
  })  : _db = db,
        _outbox = outbox,
        _client = client,
        _catalog = catalog,
        _sales = sales,
        _inventory = inventory;

  final LocalDb _db;
  final Outbox _outbox;
  final SyncClient _client;
  final CatalogRepository _catalog;
  final SaleRepository _sales;
  final InventoryRepository _inventory;

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

    /// Redeemed once, transparently, when the access token has expired (ADR-019). Empty for
    /// a session cached before refresh existed; those fall back to signing in again.
    String refreshToken = '',

    /// Called with the renewed session so the caller can persist it. Without this the
    /// terminal would refresh on every single sync — correct, but a request per sync for a
    /// token it already holds.
    Future<void> Function(LoginResponse renewed)? onRenewed,
  }) async {
    var activeToken = token;
    var sessionExpired = false;

    /// Runs [call] with the current access token, and on a 401 refreshes once and retries.
    ///
    /// Once, not in a loop: if a freshly minted token is also refused, the problem is not
    /// staleness, and retrying would turn a broken session into a request storm against a
    /// server that has already said no.
    Future<T> withAuth<T>(Future<T> Function(String token) call) async {
      try {
        return await call(activeToken);
      } on SyncTransportException catch (error) {
        if (error.statusCode != 401 || refreshToken.isEmpty) rethrow;

        final LoginResponse renewed;
        try {
          renewed = await _client.refresh(
            refreshToken: refreshToken,
            terminalId: terminalId,
          );
        } on SyncTransportException {
          // The refresh token is spent, expired, or its user was deactivated. The terminal
          // cannot fix any of those by trying again — a human has to sign in.
          sessionExpired = true;
          rethrow;
        }
        activeToken = renewed.accessToken;
        refreshToken = renewed.refreshToken;
        await onRenewed?.call(renewed);
        return call(activeToken);
      }
    }

    final pending = await _outbox.pending();

    if (pending.isNotEmpty) {
      // Every queued entry goes, in terminal_seq order — not just sales. Filtering by type
      // here is how a shift close or a cash-up would sit in the outbox forever while the
      // chip cheerfully reported everything synced.
      // Every queued entry goes, in terminal_seq order. Which repository builds the
      // envelope depends on the entity type; an unrecognised one throws rather than being
      // skipped, because a silently skipped operation sits in the outbox forever while the
      // chip cheerfully reports everything synced.
      final operations = <Operation>[
        for (final entry in pending)
          if (entry.entityType == 'goods_receipt' ||
              entry.entityType == 'stock_adjustment')
            _inventory.toOperation(
              entry,
              tenantId: tenantId,
              branchId: branchId,
              actorId: actorId,
              terminalId: terminalId,
            )
          else
            _sales.toOperation(
              entry,
              tenantId: tenantId,
              branchId: branchId,
              actorId: actorId,
              terminalId: terminalId,
            ),
      ];

      try {
        final response = await withAuth((t) => _client.push(
              token: t,
              terminalId: terminalId,
              operations: operations,
            ));
        await _outbox.applyAcks(response.acks);
      } on SyncTransportException catch (error) {
        // Nothing is removed. The queue is exactly as deep as it was, and every sale in it
        // is still on this device.
        await _outbox.recordFailure(pending, error.message);
        return SyncStatus(
          state: sessionExpired ? SyncState.sessionExpired : SyncState.offline,
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
        final response = await withAuth(
            (t) => _client.pull(token: t, cursor: cursor, branchId: branchId));
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
        state: sessionExpired ? SyncState.sessionExpired : SyncState.offline,
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
