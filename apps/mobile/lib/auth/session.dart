import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../contracts/contracts.dart';
import '../core/ids.dart';

/// The terminal's session and its cached authority.
///
/// After one successful online login the terminal keeps a snapshot of the user's scope in
/// platform secure storage and goes on working through the offline window (BR-2.3, NFR-4.2).
/// That snapshot IS the terminal's authority while offline, so it is stored deliberately and
/// explicitly rather than being reconstructed from whatever happens to be lying around.
///
/// Phase 0 keeps the access token. Phase 1 adds the derived PIN verifier so a cashier can
/// log in offline the next morning without the server (AC-2.2) — the storage seam is here
/// so that change is additive.
class SessionStore {
  SessionStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _sessionKey = 'pharmaet.session';
  static const _terminalKey = 'pharmaet.terminal_id';

  /// This device's stable identity, minted once and kept.
  ///
  /// It travels on every operation so that a sync dispute — a duplicate, a gap, an
  /// unexplained oversell — can always be traced back to the till it came from (BR-4.3).
  Future<String> terminalId() async {
    final existing = await _storage.read(key: _terminalKey);
    if (existing != null) return existing;
    final minted = newId();
    await _storage.write(key: _terminalKey, value: minted);
    return minted;
  }

  Future<void> save(LoginResponse response, String tenantCode) async {
    await _storage.write(
      key: _sessionKey,
      value: jsonEncode({
        'accessToken': response.accessToken,
        'refreshToken': response.refreshToken,
        'expiresAt': response.expiresAt,
        'offlineValidUntil': response.offlineValidUntil,
        'tenantCode': tenantCode,
        'scope': response.scope.toJson(),
      }),
    );
  }

  Future<CachedSession?> load() async {
    final raw = await _storage.read(key: _sessionKey);
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return CachedSession(
        accessToken: json['accessToken'] as String,
        // Optional on read: a session cached before refresh existed has no stored value, and
        // signing those terminals out to introduce a convenience would be the wrong trade.
        refreshToken: json['refreshToken'] as String? ?? '',
        tenantCode: json['tenantCode'] as String,
        offlineValidUntil: DateTime.parse(json['offlineValidUntil'] as String),
        scope: AuthScope.fromJson(json['scope'] as Map<String, dynamic>),
      );
    } catch (_) {
      // A corrupt or older-format session. Treat it as signed out rather than crashing on
      // launch — a till that will not open is worse than one that asks for a PIN.
      return null;
    }
  }

  Future<void> clear() => _storage.delete(key: _sessionKey);
}

class CachedSession {
  const CachedSession({
    required this.accessToken,
    required this.refreshToken,
    required this.tenantCode,
    required this.offlineValidUntil,
    required this.scope,
  });

  final String accessToken;

  /// Redeemed for a new session when the access token expires (ADR-019). Empty on a session
  /// cached before this existed, in which case expiry falls back to signing in again.
  final String refreshToken;

  final String tenantCode;
  final DateTime offlineValidUntil;
  final AuthScope scope;

  /// Past this point, privileged actions need an online re-auth — but an in-progress sale
  /// is never blocked (BR-2.3). The till does not close because a token got old.
  bool get offlineWindowExpired => expiredAt(DateTime.now());

  /// The same question asked at a given instant.
  ///
  /// The clock is a parameter because otherwise the boundary cannot be tested: by the time
  /// a test built a session ending "now" and read the getter, the wall clock has already
  /// moved past it. docs/05 §10 asks for expiry to be checked **at the window boundary**,
  /// and a rule about time that can only be exercised well away from its edge is a rule
  /// whose edge nobody has looked at.
  ///
  /// `isAfter` is strict, so a terminal exactly at its deadline is still valid. That is the
  /// forgiving side, and forgiving is right here: the alternative locks a manager out on the
  /// tick of a deadline they cannot see.
  bool expiredAt(DateTime now) => now.isAfter(offlineValidUntil);

  /// The branch this terminal acts in. Owners are all-branch by role, so a terminal signed
  /// in as an owner uses whichever branch it was provisioned to.
  String? get primaryBranchId =>
      scope.branchIds.isEmpty ? null : scope.branchIds.first;
}
