import { ForbiddenException } from '@nestjs/common';
import type { TenantScope } from '../db/tenant-scope';

/**
 * Which branches a request may read (FR-2 permission matrix).
 *
 * The matrix distinguishes **T** (tenant-wide) from **B** (branch-scoped), and the
 * difference is not cosmetic: a branch manager reading another branch's takings is a real
 * breach of a real expectation, even though both branches belong to the same tenant. RLS
 * cannot express this — it answers "which tenant", not "which branch, for this role" — so
 * it is the application's job (docs/04 §8), and it has to be done deliberately at every
 * call site that reads branch data.
 *
 * Returns `null` for "every branch in the tenant", which is the owner's case. Callers must
 * treat `null` as unrestricted rather than as empty; `[]` would silently return nothing and
 * look like a working report with no data.
 */
export function readableBranchIds(scope: TenantScope): string[] | null {
  switch (scope.role) {
    case 'owner':
      // All-branch by role; owners hold no user_branch rows (docs/04 §5.1).
      return null;
    case 'branch_manager':
    case 'cashier':
      return scope.branchIds;
  }
}

/**
 * Narrows a requested branch to what the caller may actually read.
 *
 * A request for a branch outside the caller's scope is **refused**, not silently emptied.
 * Returning an empty report would tell the manager their colleague's branch took nothing
 * today, which is worse than an error: it is a confident, wrong answer.
 */
export function resolveBranchFilter(
  scope: TenantScope,
  requestedBranchId?: string,
): string[] | null {
  const allowed = readableBranchIds(scope);

  if (requestedBranchId) {
    if (allowed !== null && !allowed.includes(requestedBranchId)) {
      throw new ForbiddenException('you do not have access to that branch');
    }
    return [requestedBranchId];
  }

  if (allowed !== null && allowed.length === 0) {
    // Scoped to nothing. Genuinely empty, and distinguishable from unrestricted.
    throw new ForbiddenException('you are not assigned to any branch');
  }
  return allowed;
}
