import { Injectable } from '@nestjs/common';
import type { EntityManager } from 'typeorm';
import { firstRow } from '../../common/db/raw-query';

/**
 * Allocates the per-tenant monotonic change sequence that drives delta pull (docs/04 §7.2).
 *
 * Why a counter and not `updated_at`: offline terminals have skewed clocks, and two rows
 * written in the same millisecond tie. A cursor over a tied timestamp either re-sends rows
 * forever or silently skips them at a page boundary — and a skipped price change is a
 * terminal selling at yesterday's price for days.
 *
 * The UPDATE ... RETURNING takes a row lock, so concurrent writers serialise on it and no
 * two rows in a tenant can ever share a sequence value.
 */
@Injectable()
export class ChangeSeqService {
  async next(em: EntityManager, tenantId: string): Promise<number> {
    const row = firstRow<{ value: string }>(
      await em.query(
        `INSERT INTO tenant_change_seq (tenant_id, value) VALUES ($1, 1)
         ON CONFLICT (tenant_id) DO UPDATE SET value = tenant_change_seq.value + 1
         RETURNING value`,
        [tenantId],
      ),
    );
    if (!row) throw new Error(`could not allocate a change sequence for tenant ${tenantId}`);
    return Number(row.value);
  }

  async current(em: EntityManager, tenantId: string): Promise<number> {
    const row = firstRow<{ value: string }>(
      await em.query(`SELECT value FROM tenant_change_seq WHERE tenant_id = $1`, [tenantId]),
    );
    return row ? Number(row.value) : 0;
  }
}
