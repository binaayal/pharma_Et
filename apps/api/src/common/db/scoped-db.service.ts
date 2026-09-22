import { Injectable, Logger } from '@nestjs/common';
import { InjectDataSource } from '@nestjs/typeorm';
import { DataSource, EntityManager } from 'typeorm';
import { PG_TENANT_SETTING, PG_USER_SETTING, TenantScope } from './tenant-scope';

/** Connection name of the platform-privileged DataSource (see app.module.ts). */
export const PLATFORM_DATA_SOURCE = 'platform';

/**
 * The ONLY sanctioned route to the database (ADR-007).
 *
 * Every tenant call opens a transaction, applies `SET LOCAL app.current_tenant`, and hands
 * the caller an EntityManager bound to that transaction. The RLS policies on every table
 * read that setting, so a query written without a tenant predicate returns nothing rather
 * than returning another pharmacy's rows.
 *
 * Three details carry the whole guarantee:
 *
 *  1. `SET LOCAL` is transaction-scoped and reverts on commit or rollback, so a pooled
 *     connection cannot leak one tenant's scope into the next request. A plain `SET` would
 *     do exactly that, and the leak would be invisible under light load.
 *
 *  2. The default DataSource connects as a NON-OWNER role (`DATABASE_APP_USER`). Postgres
 *     exempts superusers and table owners from RLS, so connecting as the owner would leave
 *     this mechanism looking correct while doing nothing at all.
 *
 *  3. Platform access is a SEPARATE DataSource on the owner role — not a flag, not an
 *     optional argument. You cannot reach tenant-crossing authority by forgetting something;
 *     you have to ask for it by name, and it is logged when you do (BR-2.2).
 *
 * CI enforces that nothing else reaches a DataSource: see test/guardian/no-unscoped-access.
 */
@Injectable()
export class ScopedDbService {
  private readonly logger = new Logger(ScopedDbService.name);

  constructor(
    @InjectDataSource() private readonly tenantDataSource: DataSource,
    @InjectDataSource(PLATFORM_DATA_SOURCE) private readonly platformDataSource: DataSource,
  ) {}

  async runInScope<T>(scope: TenantScope, work: (em: EntityManager) => Promise<T>): Promise<T> {
    return this.transact(this.tenantDataSource, async (runner) => {
      // set_config takes the value as a bind parameter, so a hostile tenant id cannot
      // become SQL the way string interpolation into `SET LOCAL` would allow.
      await runner.query('SELECT set_config($1, $2, true)', [PG_TENANT_SETTING, scope.tenantId]);
      await runner.query('SELECT set_config($1, $2, true)', [PG_USER_SETTING, scope.userId]);
      return work(runner.manager);
    });
  }

  /**
   * Platform-level access, above every tenant (docs/04 §8): tenant onboarding, subscription
   * control, payment verification.
   *
   * Runs on the owner role, which Postgres exempts from RLS. Every call states its reason
   * and is logged, because a support read of tenant data must be explicit, least-privilege,
   * and auditable (BR-2.2) rather than an ambient capability.
   */
  async runAsPlatform<T>(reason: string, work: (em: EntityManager) => Promise<T>): Promise<T> {
    this.logger.warn(`platform-scope database access: ${reason}`);
    return this.transact(this.platformDataSource, (runner) => work(runner.manager));
  }

  private async transact<T>(
    dataSource: DataSource,
    work: (runner: import('typeorm').QueryRunner) => Promise<T>,
  ): Promise<T> {
    const runner = dataSource.createQueryRunner();
    await runner.connect();
    await runner.startTransaction();
    try {
      const result = await work(runner);
      await runner.commitTransaction();
      return result;
    } catch (error) {
      await runner.rollbackTransaction();
      throw error;
    } finally {
      await runner.release();
    }
  }
}
