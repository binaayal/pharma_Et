import { Injectable } from '@nestjs/common';
import { ScopedDbService } from '../../common/db/scoped-db.service';
import type { TenantScope } from '../../common/db/tenant-scope';
import { Branch, OversellEvent, Sale } from '../../entities';
import { resolveBranchFilter } from '../../common/auth/branch-scope';
import { CashUpService, type ShiftReconciliation } from '../cashup/cash-up.service';
import { SalesSummaryService, type SalesSummary } from './sales-summary.service';
import { StockReportService, type StockReport } from './stock-report.service';

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
  constructor(
    private readonly db: ScopedDbService,
    private readonly cashUp: CashUpService,
    private readonly salesSummary: SalesSummaryService,
    private readonly stockReport: StockReportService,
  ) {}

  /**
   * Daily sales summary (AC-8.2), consolidated and per branch.
   *
   * The window is half-open — `from` inclusive, `to` exclusive — so that consecutive days
   * tile exactly and a sale rung up at midnight is counted once rather than twice or never.
   */
  async salesSummaryReport(
    scope: TenantScope,
    options: { from: Date; to: Date; branchId?: string },
  ): Promise<SalesSummary> {
    const branchIds = resolveBranchFilter(scope, options.branchId);
    return this.db.runInScope(scope, (em) =>
      this.salesSummary.summarise(em, { from: options.from, to: options.to, branchIds }),
    );
  }

  /** Stock and expiry alerting (BR-3.4). */
  async stock(
    scope: TenantScope,
    options: { branchId?: string; expiringWithinDays: number },
  ): Promise<StockReport> {
    const branchIds = resolveBranchFilter(scope, options.branchId);
    return this.db.runInScope(scope, (em) =>
      this.stockReport.report(em, { branchIds, expiringWithinDays: options.expiringWithinDays }),
    );
  }

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
   * The Z-report for one shift (FR-8 report 1, AC-8.1).
   *
   * Vision §2.1.1: the owner's primary anti-shrinkage control. It reports both expected
   * figures — the one the terminal showed the cashier and the one the server recomputes —
   * because when they differ, that difference is the finding (ADR-012 §3).
   */
  async cashUpReport(scope: TenantScope, shiftId: string): Promise<ShiftReconciliation> {
    return this.db.runInScope(scope, (em) => this.cashUp.reconcile(em, shiftId));
  }

  /**
   * Every recent shift with its reconciliation, for the owner's oversight view.
   *
   * A shift that has closed without a cash-up shows up here with nulls, on purpose: an
   * unreconciled till is precisely what an owner needs to notice, and omitting it would
   * make the report quietly complicit.
   */
  async cashUpSummary(
    scope: TenantScope,
    branchId?: string,
    limit = 30,
  ): Promise<ShiftReconciliation[]> {
    return this.db.runInScope(scope, async (em) => {
      const ids = await this.cashUp.recentShifts(em, branchId, limit);
      const out: ShiftReconciliation[] = [];
      for (const id of ids) out.push(await this.cashUp.reconcile(em, id));
      return out;
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
      em.getRepository(OversellEvent).find({ order: { observedAt: 'DESC' }, take: limit }),
    );
  }
}
