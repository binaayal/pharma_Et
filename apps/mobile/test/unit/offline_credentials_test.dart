import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/auth/offline_credentials.dart';
import 'package:pharmaet_mobile/contracts/contracts.dart';

/// AC-2.2 — an offline terminal within the window signs a cashier in with the cached PIN.
/// BR-2.3 — beyond the window it does not.
void main() {
  var now = DateTime.utc(2026, 9, 26, 8);
  OfflineCredentials store() => OfflineCredentials(clock: () => now);

  LoginResponse response({required DateTime until}) => LoginResponse(
        accessToken: 'access',
        refreshToken: 'refresh',
        expiresAt: now.add(const Duration(minutes: 15)).toIso8601String(),
        offlineValidUntil: until.toIso8601String(),
        scope: const AuthScope(
          userId: '01930000-0000-7000-8000-000000000003',
          tenantId: '01930000-0000-7000-8000-000000000001',
          role: 'cashier',
          displayName: 'Sara Girma',
          branchIds: ['01930000-0000-7000-8000-000000000002'],
        ),
      );

  setUp(() {
    now = DateTime.utc(2026, 9, 26, 8);
    FlutterSecureStorage.setMockInitialValues({});
  });

  Future<void> rememberSara({Duration window = const Duration(days: 3)}) =>
      store().remember(
          tenantCode: 'abay',
          username: 'sara',
          secret: '4821',
          response: response(until: now.add(window)));

  test('the right PIN restores the session the server issued', () async {
    await rememberSara();
    final session = await store()
        .signIn(tenantCode: 'ABAY', username: 'Sara', secret: '4821');
    expect(session.scope.displayName, 'Sara Girma');
    expect(session.refreshToken, 'refresh');
  });

  test('the PIN itself is never stored', () async {
    await rememberSara();
    final all = await const FlutterSecureStorage().readAll();
    expect(all.values.any((v) => v.contains('4821')), isFalse);
  });

  test('a wrong PIN is refused', () async {
    await rememberSara();
    expect(
      () =>
          store().signIn(tenantCode: 'abay', username: 'sara', secret: '1111'),
      throwsA(isA<OfflineSignInRefused>()
          .having((e) => e.reason, 'reason', OfflineRefusal.wrong)),
    );
  });

  test('someone who never signed in here online cannot sign in offline',
      () async {
    expect(
      () =>
          store().signIn(tenantCode: 'abay', username: 'dawit', secret: '4821'),
      throwsA(isA<OfflineSignInRefused>()
          .having((e) => e.reason, 'reason', OfflineRefusal.unknown)),
    );
  });

  test('past the offline window the cached authority is not enough (BR-2.3)',
      () async {
    await rememberSara(window: const Duration(days: 3));
    now = now.add(const Duration(days: 4));
    expect(
      () =>
          store().signIn(tenantCode: 'abay', username: 'sara', secret: '4821'),
      throwsA(isA<OfflineSignInRefused>()
          .having((e) => e.reason, 'reason', OfflineRefusal.expired)),
    );
  });

  test('five wrong PINs lock offline sign-in for fifteen minutes', () async {
    await rememberSara();
    for (var i = 0; i < OfflineCredentials.maxFailures; i++) {
      await expectLater(
          store().signIn(tenantCode: 'abay', username: 'sara', secret: '0000'),
          throwsA(isA<OfflineSignInRefused>()));
    }
    // Even the right PIN waits: ten thousand guesses must cost real time.
    await expectLater(
      store().signIn(tenantCode: 'abay', username: 'sara', secret: '4821'),
      throwsA(isA<OfflineSignInRefused>()
          .having((e) => e.reason, 'reason', OfflineRefusal.throttled)),
    );
    now = now.add(const Duration(minutes: 16));
    final session = await store()
        .signIn(tenantCode: 'abay', username: 'sara', secret: '4821');
    expect(session.scope.displayName, 'Sara Girma');
  });

  test('PBKDF2 matches the RFC 6070-style known answer for SHA-256', () {
    // PBKDF2-HMAC-SHA256("password", "salt", 1) — a published test vector.
    final dk = OfflineCredentials.derive('password', 'salt'.codeUnits, 1);
    expect(
      dk.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b',
    );
  });
}
