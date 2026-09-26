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
  static const _terminalBranchKey = 'pharmaet.terminal_branch';

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

  /// The branch this device stands in, once somebody has said which — **for one pharmacy**.
  ///
  /// A property of the terminal, not of whoever is signed in (SRS §2: a terminal is "a
  /// single device … at a branch"), so it survives sign-out. But it belongs to the tenant it
  /// was chosen in. Stored bare, it once carried Abay's Bole branch into a newly opened
  /// pharmacy's session on the same phone: an owner is all-branch by role, so the check
  /// passed, and every sale they rang up would have been refused by the server's tenant
  /// isolation and sat in the outbox for good. A placement from another pharmacy is no
  /// placement at all.
  Future<({String tenantId, String branchId, String? name})?>
      _placement() async {
    final raw = await _storage.read(key: _terminalBranchKey);
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return (
        tenantId: j['tenantId'] as String,
        branchId: j['branchId'] as String,
        name: j['name'] as String?,
      );
    } catch (_) {
      // A bare id from before placements carried their tenant: unknown provenance, so
      // it is not trusted. The device asks again, once.
      return null;
    }
  }

  Future<String?> terminalBranchId(String tenantId) async {
    final placed = await _placement();
    return placed?.tenantId == tenantId ? placed!.branchId : null;
  }

  Future<void> setTerminalBranch(String tenantId, String branchId,
          {String? name}) =>
      _storage.write(
        key: _terminalBranchKey,
        value: jsonEncode(
            {'tenantId': tenantId, 'branchId': branchId, 'name': name}),
      );

  /// The placed branch's name, for the top bar ("Bole · Sara") without a network.
  Future<String?> terminalBranchName(String tenantId) async {
    final placed = await _placement();
    return placed?.tenantId == tenantId ? placed!.name : null;
  }

  /// Names the branch this device is placed at, for this pharmacy.
  Future<void> setTerminalBranchName(
          String tenantId, String branchId, String name) =>
      setTerminalBranch(tenantId, branchId, name: name);

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
        terminalBranchId: await terminalBranchId(
            (json['scope'] as Map<String, dynamic>)['tenantId'] as String),
      );
    } catch (_) {
      // A corrupt or older-format session. Treat it as signed out rather than crashing on
      // launch — a till that will not open is worse than one that asks for a PIN.
      return null;
    }
  }

  Future<void> clear() => _storage.delete(key: _sessionKey);

  static const _identityKey = 'pharmaet.last_identity';

  /// Who last signed in here — pharmacy, username and name, never a credential — so the
  /// next sign-in is "Welcome back, Sara" and a PIN, as the prototype's login shows.
  Future<RememberedIdentity?> lastIdentity() async {
    final raw = await _storage.read(key: _identityKey);
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return RememberedIdentity(
        tenantCode: j['tenantCode'] as String,
        username: j['username'] as String,
        displayName: j['displayName'] as String,
        usesPassword: j['usesPassword'] as bool? ?? false,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> rememberIdentity(RememberedIdentity identity) => _storage.write(
        key: _identityKey,
        value: jsonEncode({
          'tenantCode': identity.tenantCode,
          'username': identity.username,
          'displayName': identity.displayName,
          'usesPassword': identity.usesPassword,
        }),
      );

  Future<void> forgetIdentity() => _storage.delete(key: _identityKey);
}

class RememberedIdentity {
  const RememberedIdentity({
    required this.tenantCode,
    required this.username,
    required this.displayName,
    this.usesPassword = false,
  });
  final String tenantCode;
  final String username;
  final String displayName;

  /// An owner or manager who signed in with a password gets the keyboard, not the keypad.
  final bool usesPassword;
}

class CachedSession {
  const CachedSession({
    required this.accessToken,
    required this.refreshToken,
    required this.tenantCode,
    required this.offlineValidUntil,
    required this.scope,
    this.terminalBranchId,
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

  /// Where this device was placed, if anyone had to choose (see [SessionStore]).
  final String? terminalBranchId;

  /// The branch this terminal acts in: the one it was placed at, if this user may act
  /// there; otherwise the user's only branch. Null means nobody has chosen yet, and the app
  /// asks before the counter opens — an owner used to reach it with no branch at all, and
  /// every sale they rang up was refused by the server for an empty branch id.
  String? get primaryBranchId {
    final placed = terminalBranchId;
    if (placed != null &&
        (scope.branchIds.isEmpty || scope.branchIds.contains(placed))) {
      return placed;
    }
    return scope.branchIds.length == 1 ? scope.branchIds.single : null;
  }

  CachedSession placedAt(String branchId) => CachedSession(
        accessToken: accessToken,
        refreshToken: refreshToken,
        tenantCode: tenantCode,
        offlineValidUntil: offlineValidUntil,
        scope: scope,
        terminalBranchId: branchId,
      );
}
