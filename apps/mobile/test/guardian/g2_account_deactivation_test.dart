import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pharmaet_mobile/auth/offline_credentials.dart';
import 'package:pharmaet_mobile/contracts/contracts.dart';
import 'package:pharmaet_mobile/data/catalog_repository.dart';
import 'package:pharmaet_mobile/data/inventory_repository.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/data/outbox.dart';
import 'package:pharmaet_mobile/data/sale_repository.dart';
import 'package:pharmaet_mobile/sync/sync_client.dart';
import 'package:pharmaet_mobile/sync/sync_service.dart';
import 'package:pharmaet_mobile/ui/login_screen.dart';

import '../support/pump.dart';
import '../support/test_db.dart';

/// G2 — A DEACTIVATED PHARMACY STOPS, AND KEEPS ITS RECORDS (ADR-025).
///
/// The server refuses every request from a pharmacy the platform has deactivated. On the
/// device, three things must follow, and each has an obvious way to be quietly wrong:
///
///  - **It is not reported as "offline".** Offline is the state a cashier is trained to
///    ignore; a deactivated terminal reported that way would keep trading for days.
///  - **The outbox is untouched.** A refused push is still an unacknowledged push, and the
///    records in it are the pharmacy's. If the account is reactivated, they upload.
///  - **Offline sign-in is wiped for that pharmacy.** Otherwise the phone reopens the till
///    without a network for the rest of the offline window.
void main() {
  const reason = 'Selling prescription-only medicine without a prescription.';
  final deactivatedBody = jsonEncode({
    'statusCode': 403,
    'error': 'Account deactivated',
    'code': 'tenant_deactivated',
    'message': reason,
  });

  group('the client reads the refusal', () {
    test('a 403 with the code is a deactivation, carrying the reason',
        () async {
      final client = SyncClient(
        baseUrl: 'http://stub.invalid',
        client: MockClient((_) async => http.Response(deactivatedBody, 403)),
      );
      await expectLater(
        client.pull(token: 't', cursor: 0),
        throwsA(isA<SyncTransportException>()
            .having((e) => e.accountDeactivated, 'deactivated', isTrue)
            .having((e) => e.message, 'message', reason)),
      );
    });

    test('a plain 403 is not', () async {
      final client = SyncClient(
        baseUrl: 'http://stub.invalid',
        client: MockClient((_) async =>
            http.Response('{"statusCode":403,"message":"Forbidden"}', 403)),
      );
      await expectLater(
        client.pull(token: 't', cursor: 0),
        throwsA(isA<SyncTransportException>()
            .having((e) => e.accountDeactivated, 'deactivated', isFalse)),
      );
    });
  });

  group('the sync service', () {
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

    Future<SyncStatus> syncAgainst(MockClient http) {
      final client = SyncClient(baseUrl: 'http://stub.invalid', client: http);
      final catalog = CatalogRepository(db);
      return SyncService(
        db: db,
        outbox: outbox,
        client: client,
        catalog: catalog,
        sales: sales,
        inventory: InventoryRepository(db, outbox, catalog),
      ).sync(
        token: 'access',
        refreshToken: 'refresh',
        tenantId: '01930000-0000-7000-8000-000000000001',
        branchId: '01930000-0000-7000-8000-000000000002',
        actorId: '01930000-0000-7000-8000-000000000003',
        terminalId: '01930000-0000-7000-8000-000000000004',
      );
    }

    Future<void> queueASale() => sales.commitSale(
          lines: [
            CartLine(
                product: const LocalProduct(
                  id: '01930000-0000-7000-8000-00000000000a',
                  name: 'Paracetamol',
                  unit: 'tablet',
                  isControlled: false,
                  priceSantim: 1500,
                ),
                qty: 1,
                batchId: null)
          ],
          tenantId: '01930000-0000-7000-8000-000000000001',
          branchId: '01930000-0000-7000-8000-000000000002',
          cashierId: '01930000-0000-7000-8000-000000000003',
          terminalId: '01930000-0000-7000-8000-000000000004',
        );

    test('says "deactivated", not "offline", and keeps every queued sale',
        () async {
      await queueASale();
      final status = await syncAgainst(
          MockClient((_) async => http.Response(deactivatedBody, 403)));

      expect(status.state, SyncState.accountDeactivated);
      expect(status.message, reason);
      expect(await outbox.depth(), 1,
          reason: 'a refused push is still unacknowledged — it stays queued');
    });

    test('is recognised when the refusal arrives on the refresh', () async {
      // The access token expired first, and the pharmacy was deactivated in between.
      await queueASale();
      final status = await syncAgainst(MockClient((request) async {
        if (request.url.path.endsWith('/auth/refresh')) {
          return http.Response(deactivatedBody, 403);
        }
        return http.Response('{"message":"unauthorized"}', 401);
      }));

      expect(status.state, SyncState.accountDeactivated);
      expect(await outbox.depth(), 1);
    });
  });

  group('offline sign-in', () {
    LoginResponse cached() => LoginResponse(
          accessToken: 'access',
          refreshToken: 'refresh',
          expiresAt:
              DateTime.now().add(const Duration(minutes: 15)).toIso8601String(),
          offlineValidUntil:
              DateTime.now().add(const Duration(days: 3)).toIso8601String(),
          scope: const AuthScope(
            userId: '01930000-0000-7000-8000-000000000003',
            tenantId: '01930000-0000-7000-8000-000000000001',
            role: 'cashier',
            displayName: 'Sara Girma',
            branchIds: ['01930000-0000-7000-8000-000000000002'],
          ),
        );

    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    test('is wiped for the deactivated pharmacy, and only for it', () async {
      final offline = OfflineCredentials();
      for (final (code, user) in [
        ('abay', 'sara'),
        ('abay', 'owner'),
        ('tana', 'abebe')
      ]) {
        await offline.remember(
            tenantCode: code,
            username: user,
            secret: '4821',
            response: cached());
      }

      await offline.forgetTenant(' ABAY ');

      for (final user in ['sara', 'owner']) {
        await expectLater(
          offline.signIn(tenantCode: 'abay', username: user, secret: '4821'),
          throwsA(isA<OfflineSignInRefused>()
              .having((e) => e.reason, 'reason', OfflineRefusal.unknown)),
        );
      }
      final tana = await offline.signIn(
          tenantCode: 'tana', username: 'abebe', secret: '4821');
      expect(tana.scope.displayName, 'Sara Girma');
    });

    testWidgets(
        'a proven sign-in to a deactivated pharmacy says why, and wipes the cache',
        (tester) async {
      final offline = OfflineCredentials();
      await tester.runAsync(() => offline.remember(
          tenantCode: 'abay',
          username: 'cashier',
          secret: '1234',
          response: cached()));

      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await pumpScreen(
        tester,
        LoginScreen(
          client: SyncClient(
            baseUrl: 'http://stub.invalid',
            client:
                MockClient((_) async => http.Response(deactivatedBody, 403)),
          ),
          terminalId: '01930000-0000-7000-8000-000000000004',
          offline: offline,
          onSignedIn: (_, __, ___, ____) =>
              fail('a deactivated pharmacy must not sign in'),
        ),
      );
      await tester.enterText(find.byType(TextField).at(0), 'abay');
      await tester.enterText(find.byType(TextField).at(1), 'cashier');
      for (final digit in '1234'.split('')) {
        await tester.tap(find.bySemanticsLabel(digit).first);
        await tester.pump();
      }
      await tester.runAsync(() async {
        await tester.tap(find.text('Sign in'));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();

      expect(find.textContaining('has been deactivated'), findsOneWidget);
      expect(find.textContaining(reason), findsOneWidget);
      await tester.runAsync(() async {
        await expectLater(
          offline.signIn(
              tenantCode: 'abay', username: 'cashier', secret: '1234'),
          throwsA(isA<OfflineSignInRefused>()),
        );
      });
    });
  });
}
