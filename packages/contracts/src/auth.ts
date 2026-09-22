import { z } from 'zod';
import { utcTimestamp, uuidv7 } from './primitives.js';

/**
 * Auth contract (FR-2, docs/04-system-design.md §8).
 *
 * A terminal logs in online at least once; from then on it validates a PIN against a cached
 * verifier and keeps working through the offline window (BR-2.3, AC-2.2).
 */

export const role = z.enum(['owner', 'branch_manager', 'cashier']);
export type Role = z.infer<typeof role>;

export const loginRequest = z.object({
  /**
   * The pharmacy's short code, issued at onboarding.
   *
   * Authentication is inherently pre-tenant: usernames are unique per tenant, not globally
   * (two pharmacies may both employ a cashier called "abebe"), so the request must say
   * which tenant it is authenticating against before any tenant-scoped lookup can happen.
   */
  tenantCode: z.string().min(2).max(32),
  /** Tenant-scoped username; PIN login is for the counter, password for back office. */
  username: z.string().min(1).max(64),
  secret: z.string().min(4).max(128),
  terminalId: uuidv7,
});
export type LoginRequest = z.infer<typeof loginRequest>;

/**
 * The scope snapshot cached on the terminal for offline authorization. It is the terminal's
 * whole authority while offline, so it is explicit rather than inferred.
 */
export const authScope = z.object({
  userId: uuidv7,
  tenantId: uuidv7,
  role,
  /** Branches this user may act in. An owner is all-branch by role (docs/04 §5.1). */
  branchIds: z.array(uuidv7),
  displayName: z.string(),
});
export type AuthScope = z.infer<typeof authScope>;

export const loginResponse = z.object({
  accessToken: z.string(),
  refreshToken: z.string(),
  expiresAt: utcTimestamp,
  scope: authScope,
  /** Cached-credential expiry: past this, privileged actions need online re-auth (NFR-1). */
  offlineValidUntil: utcTimestamp,
});
export type LoginResponse = z.infer<typeof loginResponse>;
