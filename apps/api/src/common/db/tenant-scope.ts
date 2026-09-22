/**
 * The scope every database access runs inside.
 *
 * Two distinct concerns live here and are deliberately kept apart (docs/04 §8):
 *   - `tenantId` is a SECURITY boundary, enforced by Postgres RLS. Application code cannot
 *     opt out of it, and a bug cannot cross it.
 *   - `role` and `branchIds` are AUTHORIZATION, enforced by application guards. RLS does not
 *     do fine-grained permissions; that is the app's job.
 */
export interface TenantScope {
  tenantId: string;
  userId: string;
  role: 'owner' | 'branch_manager' | 'cashier';
  /** Branches this user may act in. Empty for an owner, who is all-branch by role. */
  branchIds: string[];
}

/** Postgres session variables the RLS policies read. */
export const PG_TENANT_SETTING = 'app.current_tenant';
export const PG_USER_SETTING = 'app.current_user_id';
