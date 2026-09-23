/**
 * The FR-2 permission matrix, as data — in the contract package, on purpose.
 *
 * `docs/02-srs.md` FR-2 holds this table in prose. Restating it in code is not duplication:
 * it is what makes the matrix **testable cell by cell** rather than re-derived, differently,
 * at each of the thirty-odd places that need it. `05-qa` §10 requires every role ×
 * capability cell to be exercised at both layers, and that is only meaningful if there is
 * one table to exercise.
 *
 * **Why here and not in the API.** AC-2.1 requires a denial "at both app and API layers".
 * Two layers enforcing a table means two copies of it, and two copies drift — usually in
 * the direction where the app offers something the server refuses, which a user reads as
 * the product being broken. So the table lives in the contract and is generated into Dart
 * by `pnpm gen:contracts`, exactly as the sync envelope is (ADR-010).
 *
 * If this file and the SRS ever disagree, **the SRS is right** and this is a bug.
 */

/** Roles that exist inside a tenant. Platform Admin is deliberately not one of them. */
export type TenantRole = 'owner' | 'branch_manager' | 'cashier';

export const CAPABILITIES = [
  'tenant.manage',
  'payment.verify',
  'branch.manage',
  'staff.manage',
  'catalog.manage',
  'goods.receive',
  'sale.create',
  'controlled.dispense',
  'cashup.perform',
  'report.branch',
  'report.tenant',
  'settings.configure',
] as const;

export type Capability = (typeof CAPABILITIES)[number];

/**
 * How far a capability reaches.
 *
 * The distinction between `tenant` and `branch` is the one that matters and the one that
 * gets lost: both are "allowed", and treating them the same lets a branch manager act
 * across a tenant they only partly run.
 *
 * `own` is narrower still — the actor's own records only — and cannot be decided here,
 * because the grant knows the role and the data knows the owner. Handlers that receive
 * `own` must check ownership themselves; the guard says so by refusing to pretend otherwise.
 */
export type Grant = 'tenant' | 'branch' | 'own' | 'denied';

/**
 * Exactly the FR-2 table. ✓ against an unscoped row reads as `tenant` for an owner and
 * `branch` for the others, which is what the matrix's own footnote means by ✓.
 */
export const PERMISSION_MATRIX: Record<TenantRole, Record<Capability, Grant>> = {
  owner: {
    // Platform-level capabilities belong to the Platform Admin, an identity outside tenant
    // scope entirely (docs/04 §5.1, BR-2.2). An owner is the most privileged person inside
    // a tenant and still cannot reach them.
    'tenant.manage': 'denied',
    'payment.verify': 'denied',
    'branch.manage': 'tenant',
    'staff.manage': 'tenant',
    'catalog.manage': 'tenant',
    'goods.receive': 'tenant',
    'sale.create': 'tenant',
    'controlled.dispense': 'tenant',
    'cashup.perform': 'tenant',
    'report.branch': 'tenant',
    'report.tenant': 'tenant',
    'settings.configure': 'tenant',
  },
  branch_manager: {
    'tenant.manage': 'denied',
    'payment.verify': 'denied',
    // A branch manager runs a branch; creating and renaming branches is the owner's.
    'branch.manage': 'denied',
    'staff.manage': 'branch',
    'catalog.manage': 'branch',
    'goods.receive': 'branch',
    'sale.create': 'branch',
    'controlled.dispense': 'branch',
    'cashup.perform': 'branch',
    'report.branch': 'branch',
    // Tenant-wide figures span branches they do not run.
    'report.tenant': 'denied',
    'settings.configure': 'denied',
  },
  cashier: {
    'tenant.manage': 'denied',
    'payment.verify': 'denied',
    'branch.manage': 'denied',
    'staff.manage': 'denied',
    // AC-2.1 names this one explicitly: a cashier changing a price is denied at both the
    // application and the API layer.
    'catalog.manage': 'denied',
    'goods.receive': 'branch',
    'sale.create': 'branch',
    'controlled.dispense': 'branch',
    // "B (own shift)" in the matrix — a cashier reconciles their own till, nobody else's.
    'cashup.perform': 'own',
    'report.branch': 'own',
    'report.tenant': 'denied',
    'settings.configure': 'denied',
  },
};

export function grantFor(role: TenantRole, capability: Capability): Grant {
  return PERMISSION_MATRIX[role][capability];
}

export function isAllowed(role: TenantRole, capability: Capability): boolean {
  return grantFor(role, capability) !== 'denied';
}
