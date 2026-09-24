import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/auth/offline_window.dart';
import 'package:pharmaet_mobile/auth/session.dart';
import 'package:pharmaet_mobile/contracts/contracts.dart';
import 'package:pharmaet_mobile/core/permissions.dart';

/// G7 — THE OFFLINE AUTHORITY CEILING (BR-2.3, NFR-1.2, NFR-4.2).
///
/// Two claims are being defended at once, and they pull against each other, which is why
/// they are tested together rather than in separate files:
///
///  1. Cached authority expires. A terminal that has not reached the server in days must
///     stop honouring management actions on a scope it cannot re-verify.
///  2. **The shop never stops.** Whatever expires, the counter can still take money and the
///     till can still be closed and counted.
///
/// A change that satisfies one of these by breaking the other is the failure this suite
/// exists to catch — in both directions.
void main() {
  CachedSession sessionValidUntil(DateTime until, {String role = 'owner'}) =>
      CachedSession(
        accessToken: 'token',
        refreshToken: 'refresh',
        tenantCode: 'test',
        offlineValidUntil: until,
        scope: AuthScope(
          tenantId: '01930000-0000-7000-8000-000000000001',
          userId: '01930000-0000-7000-8000-000000000002',
          role: role,
          displayName: 'Test user',
          branchIds: const ['01930000-0000-7000-8000-000000000003'],
        ),
      );

  final fresh = sessionValidUntil(DateTime.now().add(const Duration(days: 3)));
  final stale =
      sessionValidUntil(DateTime.now().subtract(const Duration(minutes: 1)));

  /// The gate the POS screen applies: the matrix first, then the window.
  bool can(CachedSession session, String capability) {
    if (!session.scope.role.can(capability)) return false;
    return !session.offlineWindowExpired || survivesOfflineExpiry(capability);
  }

  group('the window closes', () {
    test('a session past its ceiling reports itself expired', () {
      expect(fresh.offlineWindowExpired, isFalse);
      expect(stale.offlineWindowExpired, isTrue);
    });

    test('an owner loses management capabilities once the window closes', () {
      // An owner is the most privileged role in a pharmacy, which is the point: expiry is a
      // property of the *terminal's* stale authority, not of the person. A dismissed manager
      // holding last week's session must not still be able to reprice the catalogue.
      for (final capability in [
        Capability.catalogManage,
        Capability.staffManage,
        Capability.branchManage,
        Capability.goodsReceive,
        Capability.controlledDispense,
        Capability.settingsConfigure,
        Capability.reportTenant,
      ]) {
        expect(can(fresh, capability), isTrue,
            reason: '$capability should be available before the window closes');
        expect(can(stale, capability), isFalse,
            reason:
                '$capability must require an online sign-in once the window closes');
      }
    });
  });

  group('the shop does not', () {
    test('a sale is never blocked by an expired window', () {
      // BR-2.3's named exemption, and NFR-1.2 restated: no core sale is ever hard-blocked.
      // If this ever fails, a pharmacy somewhere cannot serve a customer because a token got
      // old, and that is a worse outcome than every risk the ceiling mitigates.
      for (final role in ['owner', 'branch_manager', 'cashier']) {
        final expired = sessionValidUntil(
          DateTime.now().subtract(const Duration(days: 30)),
          role: role,
        );
        expect(can(expired, Capability.saleCreate), isTrue,
            reason:
                'a $role must still be able to sell past the offline ceiling');
      }
    });

    test('an open till can still be closed and counted', () {
      // A shift opened before the window closed has cash in a drawer. Refusing the cash-up
      // would leave it unreconciled overnight — the exact loss FR-8 exists to prevent.
      expect(can(stale, Capability.cashupPerform), isTrue);
    });
  });

  group('the boundary itself (docs/05 §10)', () {
    // §10 asks for offline-cache expiry to be tested **at the window boundary**, not merely
    // on either side of it. Boundaries are where off-by-one lives, and this one decides
    // whether a terminal at exactly its deadline can still authorise a manager action.
    //
    // A fixed deadline and an explicit clock, because the wall clock moves between building
    // a session and asking it a question — which is precisely why the boundary could not be
    // tested before `expiredAt` took the instant as a parameter.
    final deadline = DateTime.utc(2026, 9, 23, 12, 0, 0);
    final session = sessionValidUntil(deadline);

    /// The POS gate, evaluated at a chosen instant.
    bool canAt(DateTime now, String capability) {
      if (!session.scope.role.can(capability)) return false;
      return !session.expiredAt(now) || survivesOfflineExpiry(capability);
    }

    test('a session exactly at its deadline has not expired', () {
      // `isAfter` is strict, so "now == validUntil" is still valid. That is the forgiving
      // side, and forgiving is right here: the alternative locks a manager out on the tick
      // of a deadline they cannot see.
      expect(session.expiredAt(deadline), isFalse);
      expect(canAt(deadline, Capability.catalogManage), isTrue);
    });

    test('one microsecond past it, it has', () {
      final past = deadline.add(const Duration(microseconds: 1));
      expect(session.expiredAt(past), isTrue);
      expect(canAt(past, Capability.catalogManage), isFalse);
    });

    test('one microsecond before it, it has not', () {
      final before = deadline.subtract(const Duration(microseconds: 1));
      expect(session.expiredAt(before), isFalse);
      expect(canAt(before, Capability.catalogManage), isTrue);
    });

    test('and selling is unaffected on either side of the boundary', () {
      // The one property that must have no boundary at all (NFR-1.2). Whatever the clock
      // says, the counter takes money.
      for (final offset in [
        const Duration(days: -365),
        const Duration(microseconds: -1),
        Duration.zero,
        const Duration(microseconds: 1),
        const Duration(days: 365),
      ]) {
        expect(canAt(deadline.add(offset), Capability.saleCreate), isTrue,
            reason:
                'a sale was blocked at offset $offset from the window boundary');
      }
    });
  });

  group('the exemption list stays honest', () {
    test('only the trading loop survives expiry', () {
      // Pinned deliberately. Widening this set is a security decision, and it should be
      // impossible to make it accidentally while fixing something else — the diff has to say
      // so here, next to the reasoning in offline_window.dart.
      expect(kCapabilitiesSurvivingOfflineExpiry,
          {Capability.saleCreate, Capability.cashupPerform});
    });

    test('expiry never grants what the matrix denies', () {
      // The window can only ever subtract. A cashier who may not manage staff does not
      // acquire the capability by going offline, in either direction of the check.
      final cashier = sessionValidUntil(
        DateTime.now().subtract(const Duration(days: 30)),
        role: 'cashier',
      );
      expect(cashier.scope.role.can(Capability.staffManage), isFalse);
      expect(can(cashier, Capability.staffManage), isFalse);
    });
  });
}
