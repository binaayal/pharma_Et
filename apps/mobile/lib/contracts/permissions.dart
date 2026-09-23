// GENERATED FILE — DO NOT EDIT.
//
// The FR-2 permission matrix, generated from packages/contracts/src/permissions.ts by
// `pnpm gen:contracts`. Edit it there; CI fails if this file is stale (ADR-010).
//
// AC-2.1 requires a denial at both the app and the API layer. Both read this one table, so
// the app cannot offer something the server will refuse.
//
// Contract version: 1.2.0

// ignore_for_file: lines_longer_than_80_chars

/// How far a capability reaches for a role.
///
/// The distinction between [tenant] and [branch] is the one that matters and the one that
/// gets lost: both mean "allowed", and treating them alike lets a branch manager act across
/// a tenant they only partly run.
///
/// [own] is narrower still — the actor's own records only — and cannot be decided from the
/// role alone, because the grant knows the role and the data knows the owner.
enum Grant { tenant, branch, own, denied }

/// Capability names, matching the server's exactly.
abstract final class Capability {
  static const String tenantManage = 'tenant.manage';
  static const String paymentVerify = 'payment.verify';
  static const String branchManage = 'branch.manage';
  static const String staffManage = 'staff.manage';
  static const String catalogManage = 'catalog.manage';
  static const String goodsReceive = 'goods.receive';
  static const String saleCreate = 'sale.create';
  static const String controlledDispense = 'controlled.dispense';
  static const String cashupPerform = 'cashup.perform';
  static const String reportBranch = 'report.branch';
  static const String reportTenant = 'report.tenant';
  static const String settingsConfigure = 'settings.configure';
}

const Map<String, Map<String, Grant>> kPermissionMatrix =
    <String, Map<String, Grant>>{
  'owner': <String, Grant>{
    'tenant.manage': Grant.denied,
    'payment.verify': Grant.denied,
    'branch.manage': Grant.tenant,
    'staff.manage': Grant.tenant,
    'catalog.manage': Grant.tenant,
    'goods.receive': Grant.tenant,
    'sale.create': Grant.tenant,
    'controlled.dispense': Grant.tenant,
    'cashup.perform': Grant.tenant,
    'report.branch': Grant.tenant,
    'report.tenant': Grant.tenant,
    'settings.configure': Grant.tenant,
  },
  'branch_manager': <String, Grant>{
    'tenant.manage': Grant.denied,
    'payment.verify': Grant.denied,
    'branch.manage': Grant.denied,
    'staff.manage': Grant.branch,
    'catalog.manage': Grant.branch,
    'goods.receive': Grant.branch,
    'sale.create': Grant.branch,
    'controlled.dispense': Grant.branch,
    'cashup.perform': Grant.branch,
    'report.branch': Grant.branch,
    'report.tenant': Grant.denied,
    'settings.configure': Grant.denied,
  },
  'cashier': <String, Grant>{
    'tenant.manage': Grant.denied,
    'payment.verify': Grant.denied,
    'branch.manage': Grant.denied,
    'staff.manage': Grant.denied,
    'catalog.manage': Grant.denied,
    'goods.receive': Grant.branch,
    'sale.create': Grant.branch,
    'controlled.dispense': Grant.branch,
    'cashup.perform': Grant.own,
    'report.branch': Grant.own,
    'report.tenant': Grant.denied,
    'settings.configure': Grant.denied,
  },
};

/// The grant a role holds for a capability. Unknown role or capability is [Grant.denied] —
/// failing closed, because an unrecognised name is far more likely to be a typo than a
/// reason to allow something.
Grant grantFor(String role, String capability) =>
    kPermissionMatrix[role]?[capability] ?? Grant.denied;

/// Whether a role may do something at all. Use [grantFor] when the scope matters.
bool isAllowed(String role, String capability) =>
    grantFor(role, capability) != Grant.denied;
