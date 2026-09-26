import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../contracts/contracts.dart';

/// Why an offline sign-in was refused. The screen words each one differently, because each
/// needs a different thing from the person at the counter.
enum OfflineRefusal {
  /// Nobody has signed in online here as this user, so there is nothing to check against.
  unknown,

  /// The PIN did not match. Worded exactly like an online refusal (ADR-017).
  wrong,

  /// Past the offline window (BR-2.3): this authority has to be refreshed online.
  expired,

  /// Too many wrong attempts in a row on this device.
  throttled,
}

class OfflineSignInRefused implements Exception {
  OfflineSignInRefused(this.reason, {this.retryAfter});
  final OfflineRefusal reason;
  final Duration? retryAfter;
}

/// Offline sign-in with a cached PIN (AC-2.2, BR-2.3; ADR-023).
///
/// Each successful online sign-in leaves behind, for that user on this device only, a salted
/// PBKDF2 digest of the secret — never the secret — and the session the server issued. With
/// no network, the same PIN reproduces the digest and restores that session, provided its
/// offline window has not closed. The session is the server's own grant, not a new one: the
/// device can only hand back authority it was already given, and the next sync refreshes or
/// refuses it like any other.
///
/// Everything lives in platform secure storage (Android Keystore, iOS Keychain). Five wrong
/// PINs lock offline sign-in on this device for fifteen minutes, because a four-digit PIN
/// is ten thousand guesses and the server's throttle cannot see a phone with no network.
class OfflineCredentials {
  OfflineCredentials(
      {FlutterSecureStorage? storage, DateTime Function()? clock})
      : _storage = storage ?? const FlutterSecureStorage(),
        _now = clock ?? DateTime.now;

  final FlutterSecureStorage _storage;
  final DateTime Function() _now;

  /// PBKDF2-HMAC-SHA256 rounds. Slow enough that each guess costs something on a phone,
  /// fast enough that a correct PIN on a low-end handset still feels instant.
  static const iterations = 20000;
  static const maxFailures = 5;
  static const lockout = Duration(minutes: 15);

  static String _key(String tenantCode, String username) =>
      'pharmaet.offline.${tenantCode.trim().toLowerCase()}.${username.trim().toLowerCase()}';
  static const _failuresKey = 'pharmaet.offline.failures';

  /// Called after every successful online sign-in.
  Future<void> remember({
    required String tenantCode,
    required String username,
    required String secret,
    required LoginResponse response,
  }) async {
    final salt = _randomBytes(16);
    await _storage.write(
      key: _key(tenantCode, username),
      value: jsonEncode({
        'salt': base64Encode(salt),
        'digest': base64Encode(derive(secret, salt, iterations)),
        'iterations': iterations,
        'session': response.toJson(),
      }),
    );
  }

  /// Restores the cached session if [secret] is right and the window is still open.
  Future<LoginResponse> signIn({
    required String tenantCode,
    required String username,
    required String secret,
  }) async {
    final lockedFor = await _lockedFor();
    if (lockedFor != null) {
      throw OfflineSignInRefused(OfflineRefusal.throttled,
          retryAfter: lockedFor);
    }

    final raw = await _storage.read(key: _key(tenantCode, username));
    if (raw == null) throw OfflineSignInRefused(OfflineRefusal.unknown);
    final entry = jsonDecode(raw) as Map<String, dynamic>;

    final digest = derive(secret, base64Decode(entry['salt'] as String),
        entry['iterations'] as int);
    if (!_equal(digest, base64Decode(entry['digest'] as String))) {
      await _fail();
      throw OfflineSignInRefused(OfflineRefusal.wrong);
    }
    await _storage.delete(key: _failuresKey);

    final session =
        LoginResponse.fromJson(entry['session'] as Map<String, dynamic>);
    // BR-2.3: past the window the cached authority is not good enough to sign in with.
    if (_now().isAfter(DateTime.parse(session.offlineValidUntil))) {
      throw OfflineSignInRefused(OfflineRefusal.expired);
    }
    return session;
  }

  /// Keeps a renewed session current, so the next offline sign-in restores the newest grant.
  Future<void> refreshSession(
      String tenantCode, String username, LoginResponse renewed) async {
    final key = _key(tenantCode, username);
    final raw = await _storage.read(key: key);
    if (raw == null) return;
    final entry = jsonDecode(raw) as Map<String, dynamic>;
    entry['session'] = renewed.toJson();
    await _storage.write(key: key, value: jsonEncode(entry));
  }

  /// PBKDF2-HMAC-SHA256, one 32-byte block.
  static Uint8List derive(String secret, List<int> salt, int rounds) {
    final hmac = Hmac(sha256, utf8.encode(secret));
    var u = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
    final out = Uint8List.fromList(u);
    for (var i = 1; i < rounds; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < out.length; j++) {
        out[j] ^= u[j];
      }
    }
    return out;
  }

  Future<Duration?> _lockedFor() async {
    final raw = await _storage.read(key: _failuresKey);
    if (raw == null) return null;
    final j = jsonDecode(raw) as Map<String, dynamic>;
    if ((j['count'] as int) < maxFailures) return null;
    final until = DateTime.parse(j['last'] as String).add(lockout);
    final left = until.difference(_now());
    if (left.isNegative) {
      await _storage.delete(key: _failuresKey);
      return null;
    }
    return left;
  }

  Future<void> _fail() async {
    final raw = await _storage.read(key: _failuresKey);
    final count = raw == null
        ? 0
        : (jsonDecode(raw) as Map<String, dynamic>)['count'] as int;
    await _storage.write(
      key: _failuresKey,
      value: jsonEncode(
          {'count': count + 1, 'last': _now().toUtc().toIso8601String()}),
    );
  }

  static bool _equal(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static Uint8List _randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }
}
