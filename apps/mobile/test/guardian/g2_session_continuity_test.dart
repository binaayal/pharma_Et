import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/contracts/contracts.dart';
import 'package:pharmaet_mobile/data/catalog_repository.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/data/outbox.dart';
import 'package:pharmaet_mobile/data/inventory_repository.dart';
import 'package:pharmaet_mobile/data/sale_repository.dart';
import 'package:pharmaet_mobile/sync/sync_client.dart';
import 'package:pharmaet_mobile/sync/sync_service.dart';

import '../support/test_db.dart';

/// G2 — SESSION CONTINUITY (ADR-019, docs/05-qa §4).
///
/// The defect this suite exists for: an access token lives fifteen minutes, and when it
/// expired the 401 was reported as `SyncState.offline`. That is indistinguishable from a
/// network outage — a state this product is *designed* to tolerate and a cashier is trained
/// to ignore. So a terminal stopped syncing fifteen minutes after sign-in, kept taking
/// sales quite happily, and nothing anywhere gave anyone a reason to look. The owner's
/// dashboard simply stopped updating.
///
/// It survived every other suite because they log in and sync within seconds. Nothing waited
/// fifteen minutes, so nothing ever saw a 401.
///
/// Two properties are defended here, and the second matters as much as the first: the
/// terminal recovers **by itself** when it can, and says so **plainly** when it cannot.
void main() {
  late LocalDb db;
  late Directory dir;
  late Outbox outbox;
  late SaleRepository sales;
  late SyncService service;
  late _StubClient client;

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

  setUp(() async {
    final opened = await openTestDb();
    db = opened.db;
    dir = opened.dir;
    outbox = Outbox(db);
    final catalog = CatalogRepository(db);
    sales = SaleRepository(db, outbox, catalog);
    client = _StubClient();
    service = SyncService(
      db: db,
      outbox: outbox,
      client: client,
      catalog: catalog,
      sales: sales,
      inventory: InventoryRepository(db, outbox, catalog),
    );
  });

  tearDown(() async {
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> queueASale() => sales.commitSale(
        lines: [CartLine(product: product(), qty: 1, batchId: null)],
        tenantId: tenantId,
        branchId: branchId,
        cashierId: cashierId,
        terminalId: terminalId,
      );

  Future<SyncStatus> runSync({String refreshToken = 'refresh-token'}) =>
      service.sync(
        token: 'expired-access-token',
        refreshToken: refreshToken,
        tenantId: tenantId,
        branchId: branchId,
        actorId: cashierId,
        terminalId: terminalId,
        onRenewed: (renewed) async => client.renewedHandedBack = renewed,
      );

  group('when the access token has expired', () {
    test('it refreshes and the sale lands, without anyone being asked',
        () async {
      await queueASale();
      client.rejectUntilRefreshed = true;

      final status = await runSync();

      expect(client.refreshCalls, 1,
          reason: 'exactly one refresh, not a retry storm');
      expect(status.state, isNot(SyncState.sessionExpired));
      // The queue drained. Before ADR-019 this sale sat here for the rest of the day.
      expect(await outbox.depth(), 0);
    });

    test(
        'the renewed session is handed back, so it is redeemed once and not every tick',
        () async {
      await queueASale();
      client.rejectUntilRefreshed = true;

      await runSync();

      // Without this the terminal would work — and mint a new session on every sync, which
      // is a request per tick for a token it is already holding.
      expect(client.renewedHandedBack, isNotNull);
      expect(client.renewedHandedBack!.accessToken, 'fresh-access-token');
    });
  });

  group('when the refresh cannot be redeemed', () {
    test('it says "sign in again" rather than "offline"', () async {
      await queueASale();
      client.rejectUntilRefreshed = true;
      client.refreshFails = true;

      final status = await runSync();

      // THE assertion. `offline` is the state a cashier is trained to ignore, because it is
      // normal and the app is built to keep working through it. Reporting an expired session
      // that way is what made this invisible for fifteen minutes at a time.
      expect(status.state, SyncState.sessionExpired);
      expect(status.state, isNot(SyncState.offline));
    });

    test('and the sale is still on the device, untouched', () async {
      await queueASale();
      client.rejectUntilRefreshed = true;
      client.refreshFails = true;

      final status = await runSync();

      // A failed session must never cost a sale. The queue is exactly as deep as it was.
      expect(await outbox.depth(), 1);
      expect(status.pending, 1);
    });

    test(
        'a session cached before refresh existed degrades to offline, not to a crash',
        () async {
      await queueASale();
      client.rejectUntilRefreshed = true;

      // No refresh token: an older session, upgraded in place. It cannot self-heal, and the
      // honest report is the ordinary one — it will recover when someone next signs in.
      final status = await runSync(refreshToken: '');

      expect(client.refreshCalls, 0);
      expect(status.state, SyncState.offline);
      expect(await outbox.depth(), 1);
    });
  });
}

/// A SyncClient that refuses until it has been refreshed, which is what an expired access
/// token looks like from the device.
class _StubClient extends SyncClient {
  _StubClient() : super(baseUrl: 'http://stub.invalid');

  bool rejectUntilRefreshed = false;
  bool refreshFails = false;
  bool refreshed = false;
  int refreshCalls = 0;
  LoginResponse? renewedHandedBack;

  void _authorise(String token) {
    if (rejectUntilRefreshed && !refreshed) {
      throw SyncTransportException('push rejected: unauthorized',
          statusCode: 401);
    }
  }

  @override
  Future<PushResponse> push({
    required String token,
    required String terminalId,
    required List<Operation> operations,
  }) async {
    _authorise(token);
    return PushResponse(
      contractVersion: kContractVersion,
      changeSeq: 1,
      acks: [
        // `Operation` is sealed with no common `opId` getter, so the id comes from the wire
        // form — which is also what the server would read.
        for (final op in operations)
          Ack(
            opId: op.toJson()['opId'] as String,
            status: 'applied',
            serverVersion: 1,
            reason: null,
          ),
      ],
    );
  }

  @override
  Future<PullResponse> pull({
    required String token,
    required int cursor,
    String? branchId,
  }) async {
    _authorise(token);
    return PullResponse(
      contractVersion: kContractVersion,
      cursor: cursor,
      hasMore: false,
      products: const [],
      branches: const [],
      users: const [],
      stockBatches: const [],
      serverTime: '2026-09-24T12:00:00.000Z',
    );
  }

  @override
  Future<LoginResponse> refresh({
    required String refreshToken,
    required String terminalId,
  }) async {
    refreshCalls++;
    if (refreshFails) {
      throw SyncTransportException('session expired', statusCode: 401);
    }
    refreshed = true;
    return LoginResponse(
      accessToken: 'fresh-access-token',
      refreshToken: 'fresh-refresh-token',
      expiresAt:
          DateTime.now().add(const Duration(minutes: 15)).toIso8601String(),
      offlineValidUntil:
          DateTime.now().add(const Duration(days: 7)).toIso8601String(),
      scope: const AuthScope(
        userId: cashierIdConst,
        tenantId: tenantIdConst,
        role: 'cashier',
        displayName: 'Test cashier',
        branchIds: [branchIdConst],
      ),
    );
  }
}

const cashierIdConst = '01930000-0000-7000-8000-000000000003';
const tenantIdConst = '01930000-0000-7000-8000-000000000001';
const branchIdConst = '01930000-0000-7000-8000-000000000002';
