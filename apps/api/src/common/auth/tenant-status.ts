import { ForbiddenException, Injectable } from '@nestjs/common';
import { ScopedDbService } from '../db/scoped-db.service';
import { Tenant } from '../../entities';

/** The machine-readable reason a client keys on to show the deactivated screen. */
export const TENANT_DEACTIVATED = 'tenant_deactivated';

/**
 * `403` with a code, not a bare `403`.
 *
 * A client must be able to tell "this pharmacy's account is closed by the platform" from
 * "you may not do that" (a permission) and from `402` (a billing matter, ADR-016). Only the
 * first should lock the terminal and wipe its offline sign-in.
 */
export function tenantDeactivated(reason: string | null): ForbiddenException {
  return new ForbiddenException({
    statusCode: 403,
    error: 'Account deactivated',
    code: TENANT_DEACTIVATED,
    message:
      reason ?? 'This pharmacy’s PharmaEt account has been deactivated. Contact PharmaEt support.',
  });
}

interface Known {
  deactivated: boolean;
  reason: string | null;
  checkedAt: number;
}

/**
 * Whether a tenant is deactivated (ADR-025), answered from a short cache.
 *
 * Every authenticated request asks, so the answer cannot cost a database round trip each
 * time — NFR-3.2's latency budget is measured on the sync path this guards. Fifteen seconds
 * is the bound on how long a deactivation takes to reach a second API instance; the instance
 * that performed it is told directly through [forget].
 *
 * Read in the tenant's own scope, through RLS: the `tenant` policy lets a tenant see its own
 * row and no other, so this needs no platform-scope access and logs nothing per request.
 */
@Injectable()
export class TenantStatusService {
  static readonly TTL_MS = 15_000;
  private readonly known = new Map<string, Known>();

  constructor(private readonly db: ScopedDbService) {}

  async assertActive(tenantId: string, userId: string): Promise<void> {
    const cached = this.known.get(tenantId);
    const fresh =
      cached && Date.now() - cached.checkedAt < TenantStatusService.TTL_MS
        ? cached
        : await this.load(tenantId, userId);
    if (fresh.deactivated) throw tenantDeactivated(fresh.reason);
  }

  /** Drops the cached answer, so the change is enforced on the very next request. */
  forget(tenantId: string): void {
    this.known.delete(tenantId);
  }

  private async load(tenantId: string, userId: string): Promise<Known> {
    const tenant = await this.db.runInScope(
      { tenantId, userId, role: 'owner', branchIds: [] },
      (em) =>
        em.getRepository(Tenant).findOne({
          where: { id: tenantId },
          select: { id: true, status: true, deactivatedReason: true },
        }),
    );
    const known: Known = {
      deactivated: tenant?.status === 'deactivated',
      reason: tenant?.deactivatedReason ?? null,
      checkedAt: Date.now(),
    };
    this.known.set(tenantId, known);
    return known;
  }
}
