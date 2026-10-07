import { Injectable } from '@nestjs/common';
import type { EntityManager } from 'typeorm';
import type { SupplierPaymentPayload, SupplierPayload } from '@pharmaet/contracts';
import { Shift, Supplier, SupplierPayment } from '../../entities';
import type { OperationMeta } from '../credit/credit.service';
import { ChangeSeqService } from '../inventory/change-seq.service';

/**
 * Suppliers and what is owed to them (FR-18, ADR-038).
 *
 * The mirror image of the customer credit ledger (`CreditService`, ADR-034): there the
 * pharmacy is owed, here it owes. The same three things happen, each one method, each
 * called inside the transaction of the operation that caused it:
 *
 *   - a supplier is created;
 *   - a delivery arrives not wholly paid for, and the pharmacy owes more;
 *   - a payment is made, and it owes less.
 *
 * **The balance on the supplier row is a running figure, not the truth.** The truth is the
 * rows: `owed_santim` on that supplier's goods receipts, less every `supplier_payment`.
 * `verify` recomputes it, and guardian G4 holds the two together.
 */
@Injectable()
export class PayablesService {
  constructor(private readonly changeSeq: ChangeSeqService) {}

  async createSupplier(
    em: EntityManager,
    meta: OperationMeta,
    payload: SupplierPayload,
  ): Promise<void> {
    await em.getRepository(Supplier).insert({
      id: meta.entityId,
      tenantId: meta.tenantId,
      name: payload.name.trim(),
      phone: payload.phone?.trim() || null,
      note: payload.note?.trim() || null,
      balanceSantim: 0,
      createdBranchId: meta.branchId,
      createdBy: meta.actorId,
      terminalId: meta.terminalId,
      // Bumped so every other terminal learns the supplier exists on its next pull.
      changeSeq: await this.changeSeq.next(em, meta.tenantId),
      deletedAt: null,
    });
  }

  /**
   * Adds the unpaid part of a delivery to what its supplier is owed.
   *
   * Called for every receipt that names a supplier, even with nothing owing: it is also the
   * check that the supplier exists, and the lock that orders two terminals receiving from
   * one supplier at once. An unknown supplier throws, which rejects the receipt into the
   * terminal's attention queue. In order that cannot happen — the supplier's own operation
   * carries a lower `terminalSeq` — so when it does, something was lost.
   */
  async addOwed(
    em: EntityManager,
    tenantId: string,
    supplierId: string,
    amountSantim: number,
  ): Promise<void> {
    await this.move(em, tenantId, supplierId, amountSantim);
  }

  async recordPayment(
    em: EntityManager,
    meta: OperationMeta,
    payload: SupplierPaymentPayload,
  ): Promise<void> {
    // A payment naming a till that never arrived would be cash gone from a drawer no
    // cash-up accounts for.
    if (payload.shiftId) {
      const shift = await em.getRepository(Shift).findOne({ where: { id: payload.shiftId } });
      if (!shift) {
        throw new Error(
          `supplier payment references shift ${payload.shiftId}, which has not arrived`,
        );
      }
    }

    await this.move(em, meta.tenantId, payload.supplierId, -payload.amountSantim);

    await em.getRepository(SupplierPayment).insert({
      id: meta.entityId,
      tenantId: meta.tenantId,
      branchId: meta.branchId,
      supplierId: payload.supplierId,
      amountSantim: payload.amountSantim,
      method: payload.method,
      paidAt: new Date(payload.paidAt),
      shiftId: payload.shiftId,
      paidBy: payload.paidBy,
      terminalId: meta.terminalId,
      note: payload.note?.trim() || null,
      changeSeq: 0,
      deletedAt: null,
    });
  }

  /**
   * Moves a balance by a signed amount, under a row lock — for the reason, and with the
   * lock mode, that `CreditService.move` uses: two terminals of one pharmacy can sync at
   * the same moment, and the row a receipt's foreign key references must not be fought over.
   */
  private async move(
    em: EntityManager,
    tenantId: string,
    supplierId: string,
    deltaSantim: number,
  ): Promise<void> {
    const supplier = await em
      .getRepository(Supplier)
      .createQueryBuilder('s')
      .setLock('for_no_key_update')
      .where('s.id = :id', { id: supplierId })
      .getOne();
    if (!supplier) throw new Error(`unknown supplier ${supplierId}`);

    if (deltaSantim === 0) return;

    supplier.balanceSantim += deltaSantim;
    supplier.changeSeq = await this.changeSeq.next(em, tenantId);
    await em.getRepository(Supplier).save(supplier);
  }

  /**
   * Suppliers whose running balance disagrees with their rows. Empty is the only acceptable
   * answer; anything else is a money defect (G4).
   */
  async verify(
    em: EntityManager,
  ): Promise<Array<{ supplierId: string; balance: number; rows: number }>> {
    const out: Array<{ supplier_id: string; balance: string; rows: string }> = await em.query(`
      SELECT s.id AS supplier_id,
             s.balance_santim AS balance,
             coalesce(d.owed, 0) - coalesce(p.paid, 0) AS rows
        FROM supplier s
        LEFT JOIN (
              SELECT supplier_id, sum(owed_santim) AS owed
                FROM goods_receipt
               WHERE supplier_id IS NOT NULL AND deleted_at IS NULL
               GROUP BY supplier_id
             ) d ON d.supplier_id = s.id
        LEFT JOIN (
              SELECT supplier_id, sum(amount_santim) AS paid
                FROM supplier_payment
               WHERE deleted_at IS NULL
               GROUP BY supplier_id
             ) p ON p.supplier_id = s.id
       WHERE s.balance_santim <> coalesce(d.owed, 0) - coalesce(p.paid, 0)
    `);
    return out.map((r) => ({
      supplierId: r.supplier_id,
      balance: Number(r.balance),
      rows: Number(r.rows),
    }));
  }
}
