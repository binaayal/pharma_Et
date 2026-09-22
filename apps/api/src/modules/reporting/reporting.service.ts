import { Injectable } from '@nestjs/common';
import { ScopedDbService } from '../../common/db/scoped-db.service';
import type { TenantScope } from '../../common/db/tenant-scope';
import { Branch, OversellEvent, Sale } from '../../entities';

export interface SyncedSaleRow {
  id: string;
  branchId: string;
  branchName: string;
  cashierId: string;
  totalSantim: number;
  soldAt: string;
  syncedAt: string;
  lineCount: number;
}

/**
 * Phase 0 reporting: enough for the dashboard to show that a sale rung up offline on a
 * terminal really did arrive (docs/04 §13).
 *
 * The real report set — cash-up/Z-report first, since it is the owner's primary
 * anti-shrinkage control — lands in Phase 1 (FR-8).
 */
@Injectable()
export class ReportingService {
  constructor(private readonly db: ScopedDbService) {}

  async recentSales(scope: TenantScope, limit = 50): Promise<SyncedSaleRow[]> {
    return this.db.runInScope(scope, async (em) => {
      const rows = await em
        .getRepository(Sale)
        .createQueryBuilder('s')
        .innerJoin(Branch, 'b', 'b.id = s.branch_id')
        .leftJoin('sale_line', 'l', 'l.sale_id = s.id')
        .select([
          's.id AS id',
          's.branch_id AS "branchId"',
          'b.name AS "branchName"',
          's.cashier_id AS "cashierId"',
          's.total_santim AS "totalSantim"',
          's.sold_at AS "soldAt"',
          's.created_at AS "syncedAt"',
          'count(l.id) AS "lineCount"',
        ])
        .where('s.deleted_at IS NULL')
        .groupBy('s.id, b.name')
        .orderBy('s.sold_at', 'DESC')
        .limit(limit)
        .getRawMany();

      return rows.map((r) => ({
        id: r.id,
        branchId: r.branchId,
        branchName: r.branchName,
        cashierId: r.cashierId,
        totalSantim: Number(r.totalSantim),
        soldAt: new Date(r.soldAt).toISOString(),
        syncedAt: new Date(r.syncedAt).toISOString(),
        lineCount: Number(r.lineCount),
      }));
    });
  }

  /**
   * Oversell observations (guardian G5, NFR-7).
   *
   * Surfaced as a first-class report, not buried in logs: every row is stock that the
   * system believes went below zero, which means a physical count somewhere is wrong and
   * someone has to go and look.
   */
  async oversells(scope: TenantScope, limit = 50) {
    return this.db.runInScope(scope, (em) =>
      em
        .getRepository(OversellEvent)
        .find({ order: { observedAt: 'DESC' }, take: limit }),
    );
  }
}
