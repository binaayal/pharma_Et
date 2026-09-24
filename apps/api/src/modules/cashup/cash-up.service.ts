import { Injectable } from '@nestjs/common';
import type { EntityManager } from 'typeorm';
import { firstRow } from '../../common/db/raw-query';
import { AppUser, Branch, CashUp, Shift } from '../../entities';

export interface ShiftReconciliation {
  shiftId: string;
  branchId: string;
  /** Named, because the report is read by a person: an id fragment is not "who" or "where". */
  branchName: string;
  userId: string;
  userName: string;
  openedAt: string;
  closedAt: string | null;
  openingFloatSantim: number;
  cashTakenSantim: number;
  /** Opening float + cash taken, recomputed from what has actually synced. */
  serverExpectedSantim: number;
  saleCount: number;
  /** Null until the cashier has counted the drawer. */
  countedSantim: number | null;
  /** What the terminal showed the cashier at count time; never recomputed. */
  terminalExpectedSantim: number | null;
  varianceSantim: number | null;
  /**
   * `serverExpected − terminalExpected`. Non-zero means the terminal counted against a
   * different picture of the day than the server now has — almost always sales that were
   * still queued. Surfaced rather than reconciled away (ADR-012 §3).
   */
  expectationGapSantim: number | null;
  countedAt: string | null;
  note: string | null;
}

/**
 * Per-shift cash reconciliation (FR-8, BR-8.2).
 *
 * Vision §2.1.1 calls this the owner's primary anti-shrinkage control and the strongest
 * single reason to adopt the product, so it is worth being precise about what it computes.
 */
@Injectable()
export class CashUpService {
  /**
   * Expected cash for a shift, from the server's point of view.
   *
   *     opening float + cash payments on sales belonging to this shift
   *
   * **Only `cash` payments count.** A sale settled by another recorded tender never reached
   * the drawer, so including it would manufacture a shortfall and train the owner to ignore
   * the variance — the exact failure that makes a shrinkage control worthless.
   *
   * Soft-deleted sales are excluded; nothing is hard-deleted, so this has to be explicit.
   */
  async serverExpected(
    em: EntityManager,
    shiftId: string,
  ): Promise<{ expectedSantim: number; cashTakenSantim: number; saleCount: number }> {
    const shift = await em.getRepository(Shift).findOne({ where: { id: shiftId } });
    if (!shift) throw new Error(`unknown shift ${shiftId}`);

    const row = firstRow<{ cash: string; sales: string }>(
      await em.query(
        `SELECT coalesce(sum(p.amount_santim), 0)::bigint AS cash,
                count(DISTINCT s.id)::bigint            AS sales
           FROM sale s
           JOIN payment p ON p.sale_id = s.id
          WHERE s.shift_id = $1
            AND s.deleted_at IS NULL
            AND p.deleted_at IS NULL
            AND p.method = 'cash'`,
        [shiftId],
      ),
    );

    const cashTakenSantim = Number(row?.cash ?? 0);
    return {
      cashTakenSantim,
      saleCount: Number(row?.sales ?? 0),
      expectedSantim: shift.openingFloatSantim + cashTakenSantim,
    };
  }

  /** The Z-report for one shift (AC-8.1). */
  async reconcile(em: EntityManager, shiftId: string): Promise<ShiftReconciliation> {
    const shift = await em.getRepository(Shift).findOneOrFail({ where: { id: shiftId } });
    const { expectedSantim, cashTakenSantim, saleCount } = await this.serverExpected(em, shiftId);
    const cashUp = await em
      .getRepository(CashUp)
      .findOne({ where: { shiftId, deletedAt: null as never } });
    // Deliberately not filtered on deleted_at: a dismissed cashier's shortfall still has a
    // name, and it is exactly the one an owner will want to read.
    const [user, branch] = await Promise.all([
      em.getRepository(AppUser).findOne({ where: { id: shift.userId } }),
      em.getRepository(Branch).findOne({ where: { id: shift.branchId } }),
    ]);

    return {
      shiftId: shift.id,
      branchId: shift.branchId,
      branchName: branch?.name ?? shift.branchId,
      userId: shift.userId,
      userName: user?.displayName ?? shift.userId,
      openedAt: shift.openedAt.toISOString(),
      closedAt: shift.closedAt?.toISOString() ?? null,
      openingFloatSantim: shift.openingFloatSantim,
      cashTakenSantim,
      serverExpectedSantim: expectedSantim,
      saleCount,
      countedSantim: cashUp?.countedSantim ?? null,
      terminalExpectedSantim: cashUp?.expectedSantim ?? null,
      varianceSantim: cashUp?.varianceSantim ?? null,
      expectationGapSantim: cashUp ? expectedSantim - cashUp.expectedSantim : null,
      countedAt: cashUp?.countedAt.toISOString() ?? null,
      note: cashUp?.note ?? null,
    };
  }

  /** Every shift at a branch, most recent first, for the owner's oversight view. */
  async recentShifts(em: EntityManager, branchId?: string, limit = 30): Promise<string[]> {
    const rows = await em
      .getRepository(Shift)
      .createQueryBuilder('s')
      .select('s.id', 'id')
      .where('s.deleted_at IS NULL')
      .andWhere(branchId ? 's.branch_id = :branchId' : '1=1', { branchId })
      .orderBy('s.opened_at', 'DESC')
      .limit(limit)
      .getRawMany();
    return rows.map((r: { id: string }) => r.id);
  }
}
