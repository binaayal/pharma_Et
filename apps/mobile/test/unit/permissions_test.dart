import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/core/permissions.dart';

/// FR-2 permission matrix, device half (AC-2.1: denied at both app and API layers).
///
/// The table is generated from `packages/contracts/src/permissions.ts`, so these tests and
/// the server's read the same cells. That is the point: two layers enforcing a permission
/// table means two copies unless something stops it, and the copies drift in the direction
/// where the app offers what the server refuses.
void main() {
  group('the generated matrix matches the SRS', () {
    test('a cashier may not manage the catalog (AC-2.1)', () {
      expect(isAllowed('cashier', Capability.catalogManage), isFalse);
      expect(grantFor('cashier', Capability.catalogManage), Grant.denied);
    });

    test('a cashier may sell and receive goods, branch-scoped', () {
      expect(grantFor('cashier', Capability.saleCreate), Grant.branch);
      expect(grantFor('cashier', Capability.goodsReceive), Grant.branch);
    });

    test('a cashier reconciles only their own till', () {
      expect(grantFor('cashier', Capability.cashupPerform), Grant.own);
    });

    test('a branch manager runs a branch but does not create them', () {
      expect(grantFor('branch_manager', Capability.branchManage), Grant.denied);
      expect(grantFor('branch_manager', Capability.staffManage), Grant.branch);
      expect(grantFor('branch_manager', Capability.reportTenant), Grant.denied);
    });

    test('an owner is tenant-wide', () {
      expect(grantFor('owner', Capability.catalogManage), Grant.tenant);
      expect(grantFor('owner', Capability.reportTenant), Grant.tenant);
    });

    test('no tenant role reaches the platform-admin capabilities (BR-2.2)', () {
      // Platform Admin is an identity outside tenant scope. An owner is the most
      // privileged person inside a tenant and still cannot verify their own payment.
      for (final role in ['owner', 'branch_manager', 'cashier']) {
        expect(isAllowed(role, Capability.tenantManage), isFalse);
        expect(isAllowed(role, Capability.paymentVerify), isFalse);
      }
    });
  });

  group('failing closed', () {
    test('an unknown role is denied, not allowed', () {
      // A typo in a role name must not become an escalation. On a device holding a cached
      // scope from an older build, an unrecognised value is far likelier to be a mistake
      // than a reason to permit something.
      expect(grantFor('superuser', Capability.catalogManage), Grant.denied);
      expect(isAllowed('', Capability.saleCreate), isFalse);
    });

    test('an unknown capability is denied', () {
      expect(grantFor('owner', 'catalog.delete_everything'), Grant.denied);
    });
  });

  group('branch reach', () {
    const branchA = 'branch-a';
    const branchB = 'branch-b';

    test('an owner acts in any branch without being assigned to one', () {
      expect(
        canActInBranch(
          role: 'owner',
          capability: Capability.saleCreate,
          branchId: branchB,
          assignedBranchIds: const [],
        ),
        isTrue,
      );
    });

    test('a manager acts only where they are assigned', () {
      expect(
        canActInBranch(
          role: 'branch_manager',
          capability: Capability.staffManage,
          branchId: branchA,
          assignedBranchIds: const [branchA],
        ),
        isTrue,
      );
      expect(
        canActInBranch(
          role: 'branch_manager',
          capability: Capability.staffManage,
          branchId: branchB,
          assignedBranchIds: const [branchA],
        ),
        isFalse,
      );
    });

    test('a denied capability stays denied even in an assigned branch', () {
      expect(
        canActInBranch(
          role: 'cashier',
          capability: Capability.catalogManage,
          branchId: branchA,
          assignedBranchIds: const [branchA],
        ),
        isFalse,
      );
    });
  });
}
