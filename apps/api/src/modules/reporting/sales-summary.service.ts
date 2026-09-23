import { Injectable } from '@nestjs/common';
import type { EntityManager } from 'typeorm';

export interface BranchSalesRow {
  branchId: string;
  branchName: string;
  saleCount: number;
  grossSantim: number;
  cashSantim: number;
  otherTenderSantim: number;
  itemsSold: number;
}

export interface SalesSummary {
  from: string;
  to: string;
  branches: BranchSalesRow[];
  /** The consolidated figures AC-8.2 requires alongside the per-branch ones. */
  total: {
    saleCount: number;
    grossSantim: number;
    cashSantim: number;
    otherTenderSantim: number;
    itemsSold: number;
  };
  /**
   * When the most recent sale in this window actually reached the server.
   *
   * Reports reflect **synced** data (BR-8.1), and on this product that is a meaningful
   * caveat rather than boilerplate: a branch whose terminal has been offline since Tuesday
   * will show a plausible, complete-looking, wrong total. Null when the window holds
   * nothing.
   */
  lastSyncedAt: string | null;
}

/**
 * Daily sales summary (FR-8 report 2, AC-8.2).
 *
 * Consolidated and per-branch in one response, because the owner's question is almost never
 * one or the other — it is "how did we do, and which shop is the reason".
 */
@Injectable()
export class SalesSummaryService {
  async summarise(
    em: EntityManager,
    options: { from: Date; to: Date; branchIds: string[] | null },
  ): Promise<SalesSummary> {
    const params: unknown[] = [options.from.toISOString(), options.to.toISOString()];
    let branchFilter = '';
    if (options.branchIds !== null) {
      params.push(options.branchIds);
      branchFilter = `AND s.branch_id = ANY($${params.length}::uuid[])`;
    }

    // One pass, grouped by branch. Payments are aggregated in a sub-select rather than
    // joined directly: a sale with two payment rows would otherwise multiply its own
    // line-item count, and the item total would silently double.
    const rows = await em.query(
      `
      SELECT b.id                                            AS "branchId",
             b.name                                          AS "branchName",
             count(DISTINCT s.id)::int                        AS "saleCount",
             coalesce(sum(s.total_santim), 0)::bigint         AS "grossSantim",
             coalesce(sum(pay.cash), 0)::bigint               AS "cashSantim",
             coalesce(sum(pay.other), 0)::bigint              AS "otherTenderSantim",
             coalesce(sum(items.qty), 0)::bigint              AS "itemsSold",
             max(s.created_at)                                AS "lastSyncedAt"
        FROM sale s
        JOIN branch b ON b.id = s.branch_id
        LEFT JOIN LATERAL (
              SELECT sum(p.amount_santim) FILTER (WHERE p.method = 'cash')  AS cash,
                     sum(p.amount_santim) FILTER (WHERE p.method <> 'cash') AS other
                FROM payment p
               WHERE p.sale_id = s.id AND p.deleted_at IS NULL
             ) pay ON true
        LEFT JOIN LATERAL (
              SELECT sum(l.qty) AS qty
                FROM sale_line l
               WHERE l.sale_id = s.id AND l.deleted_at IS NULL
             ) items ON true
       WHERE s.deleted_at IS NULL
         AND s.sold_at >= $1 AND s.sold_at < $2
         ${branchFilter}
       GROUP BY b.id, b.name
       ORDER BY b.name
      `,
      params,
    );

    const branches: BranchSalesRow[] = rows.map((r: Record<string, string | number | null>) => ({
      branchId: r.branchId as string,
      branchName: r.branchName as string,
      saleCount: Number(r.saleCount),
      grossSantim: Number(r.grossSantim),
      cashSantim: Number(r.cashSantim),
      otherTenderSantim: Number(r.otherTenderSantim),
      itemsSold: Number(r.itemsSold),
    }));

    const lastSyncedAt = rows
      .map((r: { lastSyncedAt: string | null }) => r.lastSyncedAt)
      .filter(Boolean)
      .sort()
      .pop();

    return {
      from: options.from.toISOString(),
      to: options.to.toISOString(),
      branches,
      total: {
        saleCount: branches.reduce((n, b) => n + b.saleCount, 0),
        grossSantim: branches.reduce((n, b) => n + b.grossSantim, 0),
        cashSantim: branches.reduce((n, b) => n + b.cashSantim, 0),
        otherTenderSantim: branches.reduce((n, b) => n + b.otherTenderSantim, 0),
        itemsSold: branches.reduce((n, b) => n + b.itemsSold, 0),
      },
      lastSyncedAt: lastSyncedAt ? new Date(lastSyncedAt).toISOString() : null,
    };
  }
}
