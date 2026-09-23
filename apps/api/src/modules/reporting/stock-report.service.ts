import { Injectable } from '@nestjs/common';
import type { EntityManager } from 'typeorm';

/**
 * Renders a Postgres `date` as a plain ISO calendar date.
 *
 * The driver hands back a JS `Date` for a `date` column, and `String(...)` on that yields
 * `"Thu Dec 31 2026 ..."` — so slicing ten characters off it produces `"Thu Dec 3"`, which
 * is not a date at all and is exactly the kind of thing that looks fine until somebody
 * sorts by it. `toISOString()` is safe here because a `date` comes back at UTC midnight.
 */
function isoDate(value: unknown): string {
  if (value instanceof Date) return value.toISOString().slice(0, 10);
  return String(value).slice(0, 10);
}

export interface StockRow {
  batchId: string;
  branchId: string;
  branchName: string;
  productId: string;
  productName: string;
  unit: string;
  lotNo: string;
  expiryDate: string;
  qtyOnHand: number;
  /** Negative while expired, so one number orders the whole list by urgency. */
  daysToExpiry: number;
  status: 'expired' | 'expiring' | 'oversold' | 'ok';
  valueSantim: number;
}

export interface StockReport {
  asOf: string;
  expiringWithinDays: number;
  rows: StockRow[];
  summary: {
    expiredBatches: number;
    expiringBatches: number;
    oversoldBatches: number;
    /** Money sitting on shelves that is already worthless, or about to be. */
    expiredValueSantim: number;
    expiringValueSantim: number;
  };
}

/**
 * Current stock and expiry alerting (FR-8 report 3, BR-3.4).
 *
 * Vision §1.1 names the losses this is aimed at directly: stockouts, dead stock, and drugs
 * expiring on the shelf and written off. So the report leads with what is about to be lost
 * and what it is worth, rather than with an inventory listing — an owner who has to compute
 * the cost themselves will not look twice.
 *
 * Controlled substances are absent, as they must be: their stock is a projection over the
 * append-only ledger (BR-3.3), which does not exist until Phase 2 clears the A-1 gate.
 * Showing them here from some other source would be inventing a number.
 */
@Injectable()
export class StockReportService {
  async report(
    em: EntityManager,
    options: { branchIds: string[] | null; expiringWithinDays: number },
  ): Promise<StockReport> {
    const params: unknown[] = [options.expiringWithinDays];
    let branchFilter = '';
    if (options.branchIds !== null) {
      params.push(options.branchIds);
      branchFilter = `AND sb.branch_id = ANY($${params.length}::uuid[])`;
    }

    const rows = await em.query(
      `
      SELECT sb.id                                      AS "batchId",
             sb.branch_id                               AS "branchId",
             b.name                                     AS "branchName",
             sb.product_id                              AS "productId",
             p.name                                     AS "productName",
             p.unit                                     AS "unit",
             sb.lot_no                                  AS "lotNo",
             sb.expiry_date                             AS "expiryDate",
             sb.qty_on_hand                             AS "qtyOnHand",
             (sb.expiry_date - CURRENT_DATE)            AS "daysToExpiry",
             -- Valued at the current selling price: what the pharmacy stands to lose if it
             -- expires, not what it cost. The owner's question is "how much am I about to
             -- throw away", and cost price would understate it.
             (sb.qty_on_hand * p.current_price_santim)  AS "valueSantim"
        FROM stock_batch sb
        JOIN product p ON p.id = sb.product_id
        JOIN branch  b ON b.id = sb.branch_id
       WHERE sb.deleted_at IS NULL
         AND p.deleted_at IS NULL
         AND p.is_controlled = false
         AND (
              -- Anything worth acting on: expiring soon, already expired, or oversold.
              -- A healthy batch with months left is noise on an alerting report.
              sb.expiry_date <= CURRENT_DATE + ($1 || ' days')::interval
              OR sb.qty_on_hand < 0
         )
         ${branchFilter}
       ORDER BY sb.qty_on_hand < 0 DESC, sb.expiry_date ASC
      `,
      params,
    );

    const mapped: StockRow[] = rows.map((r: Record<string, unknown>) => {
      const qtyOnHand = Number(r.qtyOnHand);
      const daysToExpiry = Number(r.daysToExpiry);
      return {
        batchId: r.batchId as string,
        branchId: r.branchId as string,
        branchName: r.branchName as string,
        productId: r.productId as string,
        productName: r.productName as string,
        unit: r.unit as string,
        lotNo: r.lotNo as string,
        expiryDate: isoDate(r.expiryDate),
        qtyOnHand,
        daysToExpiry,
        // Oversold outranks expiry: a negative count means the physical shelf and the
        // system disagree, and somebody has to go and look before any expiry decision
        // based on that count means anything (BR-3.2, guardian G5).
        status:
          qtyOnHand < 0
            ? 'oversold'
            : daysToExpiry < 0
              ? 'expired'
              : daysToExpiry <= options.expiringWithinDays
                ? 'expiring'
                : 'ok',
        valueSantim: Number(r.valueSantim),
      };
    });

    const expired = mapped.filter((r) => r.status === 'expired');
    const expiring = mapped.filter((r) => r.status === 'expiring');

    return {
      asOf: new Date().toISOString(),
      expiringWithinDays: options.expiringWithinDays,
      rows: mapped,
      summary: {
        expiredBatches: expired.length,
        expiringBatches: expiring.length,
        oversoldBatches: mapped.filter((r) => r.status === 'oversold').length,
        expiredValueSantim: expired.reduce((n, r) => n + r.valueSantim, 0),
        expiringValueSantim: expiring.reduce((n, r) => n + r.valueSantim, 0),
      },
    };
  }
}
