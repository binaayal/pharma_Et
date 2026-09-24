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

/**
 * Exchanging a refresh token for a new session (docs/04 §9).
 *
 * The terminal holds this from its last login and sends it when its access token expires.
 * It carries no credential the user types: the whole point is that a till mid-shift does not
 * stop for a PIN prompt because fifteen minutes elapsed.
 */
export const refreshRequest = z.object({
  refreshToken: z.string().min(1),
  /** The device asking. Kept so a refresh is attributable to a terminal, like a login. */
  terminalId: uuidv7,
});
export type RefreshRequest = z.infer<typeof refreshRequest>;

/**
 * A refresh returns a **whole new session**, not merely a new access token.
 *
 * Deliberate, and the reason is authority rather than convenience. A refresh re-reads the
 * user from the database, so a cashier dismissed this morning cannot refresh their way
 * through the afternoon, and a role changed at lunchtime takes effect on the next refresh
 * rather than at the end of the offline window. Returning only a token would leave the
 * terminal running on the scope it cached at login, which is exactly the staleness BR-2.3
 * exists to bound.
 */
export const refreshResponse = loginResponse;
export type RefreshResponse = LoginResponse;
