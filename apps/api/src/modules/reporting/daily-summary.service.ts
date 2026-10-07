import { Injectable } from '@nestjs/common';
import type { EntityManager } from 'typeorm';
import { CashUpService } from '../cashup/cash-up.service';
import { SalesSummaryService } from './sales-summary.service';

/** A product running low: how many base units are left across its batches. */
export interface LowStockRow {
  productId: string;
  productName: string;
  unit: string;
  onHand: number;
}

/** One till session that touched the day. */
export interface DayShift {
  shiftId: string;
  branchName: string;
  userName: string;
  openedAt: string;
  /** Null while the till is still open. */
  closedAt: string | null;
  /** Null until the drawer has been counted. */
  countedSantim: number | null;
  /** What the cashier was shown and agreed to (ADR-012 §3). */
  expectedSantim: number | null;
  /** `counted − expected`. Negative is cash missing. */
  varianceSantim: number | null;
}

export interface DailySummary {
  from: string;
  to: string;
  sales: {
    saleCount: number;
    grossSantim: number;
    cashSantim: number;
    otherTenderSantim: number;
    creditSantim: number;
    itemsSold: number;
  };
  cash: {
    /** Drawers counted in the window. */
    countedShifts: number;
    countedSantim: number;
    /** The sum of every shortfall, as a positive number. Overages do not offset it. */
    shortageSantim: number;
    /** The sum of every overage. */
    overageSantim: number;
    /** Tills opened in the window and not yet counted. */
    openShifts: number;
  };
  shifts: DayShift[];
  credit: {
    /** Taken against debts in the window, by any tender. */
    repaidSantim: number;
    /** Everything customers owe the pharmacy right now. Not windowed: a debt is a balance. */
    owedSantim: number;
    customersOwing: number;
  };
  stock: {
    lowCount: number;
    /** The lowest few, for the line an owner actually reads. */
    low: LowStockRow[];
    /** Batches in stock that expire within 60 days. */
    expiringBatches: number;
    /** Batches driven below zero and not yet recounted (BR-3.2). */
    oversoldBatches: number;
  };
  /** Things done in the window that an owner would want to have been told about. */
  attention: {
    priceChanges: number;
    stockWriteOffs: number;
    expiredDispenses: number;
  };
  /** When the newest sale in the window reached the server (BR-8.1). */
  lastSyncedAt: string | null;
}

/** At or below this many base units, a product is "running low". The phone uses the same. */
export const LOW_STOCK_AT = 20;

/**
 * The end-of-day summary (FR-17, ADR-035).
 *
 * One answer to the question an owner who is not behind the counter asks every evening:
 * *how did today go, and is anything wrong?* Sales, the drawer, who was on, what is owed,
 * what is running out, and what was done that they should know about.
 *
 * Everything here is read from what is already recorded — sales, cash-ups, the credit
 * ledger, stock, the audit trail. Nothing new is stored, which is why this is a report and
 * not a controlled artifact: it can be wrong only by adding up wrongly, and the tests hold
 * each figure to the rows it came from.
 *
 * It reflects **synced** data (BR-8.1). A till offline since noon is missing from the
 * afternoon, and `lastSyncedAt` is how the screen says so.
 */
@Injectable()
export class DailySummaryService {
  constructor(
    private readonly salesSummary: SalesSummaryService,
    private readonly cashUp: CashUpService,
  ) {}

  async summarise(
    em: EntityManager,
    options: { from: Date; to: Date; branchIds: string[] | null },
  ): Promise<DailySummary> {
    const { from, to, branchIds } = options;

    const sales = await this.salesSummary.summarise(em, { from, to, branchIds });
    const shifts = await this.shiftsTouching(em, from, to, branchIds);
    const counted = shifts.filter((s) => s.varianceSantim !== null);
    const repaidSantim = await this.repaid(em, from, to, branchIds);

    // Tenant-wide by design (ADR-034 §4): a customer owes the pharmacy, not a branch.
    const [owed] = await em.query(
      `SELECT coalesce(sum(balance_santim) FILTER (WHERE balance_santim > 0), 0)::bigint AS total,
              count(*) FILTER (WHERE balance_santim > 0)::int AS customers
         FROM customer WHERE deleted_at IS NULL`,
    );

    const low = await this.lowStock(em, branchIds);
    const batches = await this.batchCounts(em, branchIds);
    const audit = await this.attention(em, from, to, branchIds);

    const shortage = counted
      .filter((s) => (s.varianceSantim ?? 0) < 0)
      .reduce((sum, s) => sum - (s.varianceSantim ?? 0), 0);
    const overage = counted
      .filter((s) => (s.varianceSantim ?? 0) > 0)
      .reduce((sum, s) => sum + (s.varianceSantim ?? 0), 0);

    return {
      from: from.toISOString(),
      to: to.toISOString(),
      sales: sales.total,
      cash: {
        countedShifts: counted.length,
        countedSantim: counted.reduce((sum, s) => sum + (s.countedSantim ?? 0), 0),
        // Kept apart, never netted: 50 missing from one till and 50 extra in another is
        // two findings, and a net of zero would report none.
        shortageSantim: shortage,
        overageSantim: overage,
        openShifts: shifts.filter((s) => s.closedAt === null).length,
      },
      shifts,
      credit: {
        repaidSantim,
        owedSantim: Number(owed.total),
        customersOwing: Number(owed.customers),
      },
      stock: {
        lowCount: low.length,
        low: low.slice(0, 8).map((r) => ({
          productId: r.id,
          productName: r.name,
          unit: r.unit,
          onHand: Number(r.on_hand),
        })),
        expiringBatches: Number(batches.expiring),
        oversoldBatches: Number(batches.oversold),
      },
      attention: {
        priceChanges: Number(audit.price_changes),
        stockWriteOffs: Number(audit.write_offs),
        expiredDispenses: Number(audit.expired),
      },
      lastSyncedAt: sales.lastSyncedAt,
    };
  }

  // Each query below binds every value ($1, $2…). The one thing spliced into the SQL text
  // is `branchFilter`: a constant fragment with its own placeholder, present or absent —
  // never a value. That shape is what `test/unit/security.spec.ts` allows, and why each
  // query has its own small method: the fragment names a different column in each.

  /**
   * Tills that were open at any point in the window: opened before it ended, and not closed
   * before it began. A shift opened yesterday and counted this morning belongs to today's
   * drawer.
   */
  private async shiftsTouching(
    em: EntityManager,
    from: Date,
    to: Date,
    branchIds: string[] | null,
  ): Promise<DayShift[]> {
    const params: unknown[] = [from.toISOString(), to.toISOString()];
    let branchFilter = '';
    if (branchIds !== null) {
      params.push(branchIds);
      branchFilter = 'AND s.branch_id = ANY($3::uuid[])';
    }
    const rows: Array<{ id: string }> = await em.query(
      `SELECT s.id
         FROM shift s
        WHERE s.deleted_at IS NULL
          AND s.opened_at < $2
          AND (s.closed_at IS NULL OR s.closed_at >= $1)
          ${branchFilter}
        ORDER BY s.opened_at`,
      params,
    );

    const shifts: DayShift[] = [];
    for (const { id } of rows) {
      const r = await this.cashUp.reconcile(em, id);
      shifts.push({
        shiftId: r.shiftId,
        branchName: r.branchName,
        userName: r.userName,
        openedAt: r.openedAt,
        closedAt: r.closedAt,
        countedSantim: r.countedSantim,
        expectedSantim: r.terminalExpectedSantim,
        varianceSantim: r.varianceSantim,
      });
    }
    return shifts;
  }

  private async repaid(
    em: EntityManager,
    from: Date,
    to: Date,
    branchIds: string[] | null,
  ): Promise<number> {
    const params: unknown[] = [from.toISOString(), to.toISOString()];
    let branchFilter = '';
    if (branchIds !== null) {
      params.push(branchIds);
      branchFilter = 'AND branch_id = ANY($3::uuid[])';
    }
    const [row] = await em.query(
      `SELECT coalesce(sum(amount_santim), 0)::bigint AS total
         FROM credit_payment
        WHERE deleted_at IS NULL AND paid_at >= $1 AND paid_at < $2
          ${branchFilter}`,
      params,
    );
    return Number(row.total);
  }

  private async lowStock(
    em: EntityManager,
    branchIds: string[] | null,
  ): Promise<Array<{ id: string; name: string; unit: string; on_hand: string }>> {
    const params: unknown[] = [LOW_STOCK_AT];
    let branchFilter = '';
    if (branchIds !== null) {
      params.push(branchIds);
      branchFilter = 'AND b.branch_id = ANY($2::uuid[])';
    }
    return em.query(
      `SELECT p.id, p.name, p.unit, coalesce(sum(b.qty_on_hand), 0)::bigint AS on_hand
         FROM product p
         LEFT JOIN stock_batch b
                ON b.product_id = p.id AND b.deleted_at IS NULL ${branchFilter}
        WHERE p.deleted_at IS NULL AND p.is_controlled = false
        GROUP BY p.id, p.name, p.unit
       HAVING coalesce(sum(b.qty_on_hand), 0) <= $1
        ORDER BY coalesce(sum(b.qty_on_hand), 0), p.name`,
      params,
    );
  }

  private async batchCounts(
    em: EntityManager,
    branchIds: string[] | null,
  ): Promise<{ expiring: number; oversold: number }> {
    const params: unknown[] = [];
    let branchFilter = '';
    if (branchIds !== null) {
      params.push(branchIds);
      branchFilter = 'AND b.branch_id = ANY($1::uuid[])';
    }
    const [row] = await em.query(
      `SELECT count(*) FILTER (
                WHERE b.qty_on_hand > 0
                  AND b.expiry_date >= CURRENT_DATE
                  AND b.expiry_date <= CURRENT_DATE + 60)::int AS expiring,
              count(*) FILTER (WHERE b.qty_on_hand < 0)::int   AS oversold
         FROM stock_batch b
        WHERE b.deleted_at IS NULL ${branchFilter}`,
      params,
    );
    return row;
  }

  private async attention(
    em: EntityManager,
    from: Date,
    to: Date,
    branchIds: string[] | null,
  ): Promise<{ price_changes: number; write_offs: number; expired: number }> {
    const params: unknown[] = [from.toISOString(), to.toISOString()];
    let branchFilter = '';
    if (branchIds !== null) {
      params.push(branchIds);
      // A price change belongs to the pharmacy, not a branch, and carries no branch: a
      // manager is still told about it.
      branchFilter = 'AND (branch_id IS NULL OR branch_id = ANY($3::uuid[]))';
    }
    const [row] = await em.query(
      `SELECT count(*) FILTER (WHERE event_type IN ('audit.price_changed', 'audit.packs_changed'))::int
                AS price_changes,
              count(*) FILTER (
                WHERE event_type = 'audit.stock_adjusted'
                  AND (payload->>'delta')::bigint < 0
                  AND payload->>'reason' <> 'recount')::int AS write_offs,
              count(*) FILTER (WHERE event_type = 'audit.expired_dispense')::int AS expired
         FROM event
        WHERE stream = 'audit' AND occurred_at >= $1 AND occurred_at < $2
          ${branchFilter}`,
      params,
    );
    return row;
  }
}
