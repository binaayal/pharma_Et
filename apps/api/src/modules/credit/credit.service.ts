import { Injectable } from '@nestjs/common';
import type { EntityManager } from 'typeorm';
import type { CreditPaymentPayload, CustomerPayload } from '@pharmaet/contracts';
import { CreditPayment, Customer, Shift } from '../../entities';
import { ChangeSeqService } from '../inventory/change-seq.service';

export interface OperationMeta {
  entityId: string;
  tenantId: string;
  branchId: string;
  actorId: string;
  terminalId: string;
}

/**
 * The customer credit ledger — ዕዳ (FR-16, ADR-034).
 *
 * Three things happen to a debt, and each is one method here, called inside the transaction
 * of the operation that caused it:
 *
 *   - a customer is created;
 *   - a sale puts some of its total on credit, and the customer owes more;
 *   - a repayment is taken, and the customer owes less.
 *
 * **The balance on the customer row is a running figure, not the truth.** The truth is the
 * rows: every `credit` payment on that customer's sales, less every `credit_payment`.
 * `verify` recomputes it, and guardian G4 asserts the two agree after every sequence it can
 * think of. The running figure exists because a terminal needs a balance on every pull and
 * must not have to be sent a customer's entire history to get one.
 *
 * Nothing here ever refuses a sale for being on credit, or for a balance being high. Whether
 * to extend credit is the judgment of the person at the counter; the system's job is to
 * record it and to say who did (BR-3.2's principle, applied to money owed).
 */
@Injectable()
export class CreditService {
  constructor(private readonly changeSeq: ChangeSeqService) {}

  async createCustomer(
    em: EntityManager,
    meta: OperationMeta,
    payload: CustomerPayload,
  ): Promise<void> {
    await em.getRepository(Customer).insert({
      id: meta.entityId,
      tenantId: meta.tenantId,
      name: payload.name.trim(),
      phone: payload.phone?.trim() || null,
      note: payload.note?.trim() || null,
      balanceSantim: 0,
      createdBranchId: meta.branchId,
      createdBy: meta.actorId,
      terminalId: meta.terminalId,
      // Bumped so every other terminal learns the customer exists on its next pull.
      changeSeq: await this.changeSeq.next(em, meta.tenantId),
      deletedAt: null,
    });
  }

  /**
   * Adds the credit part of a sale to what its customer owes.
   *
   * Throws if the customer is unknown, which rejects the sale into the terminal's attention
   * queue rather than recording a debt owed by nobody. In order that cannot happen — the
   * customer's own operation carries a lower `terminalSeq` than the sale that names it —
   * so when it does, something was lost, and that is worth a human looking at.
   */
  async addDebt(
    em: EntityManager,
    tenantId: string,
    customerId: string,
    amountSantim: number,
  ): Promise<void> {
    await this.move(em, tenantId, customerId, amountSantim);
  }

  async recordPayment(
    em: EntityManager,
    meta: OperationMeta,
    payload: CreditPaymentPayload,
  ): Promise<void> {
    // A repayment naming a till that never arrived would be cash no cash-up accounts for.
    if (payload.shiftId) {
      const shift = await em.getRepository(Shift).findOne({ where: { id: payload.shiftId } });
      if (!shift) {
        throw new Error(`repayment references shift ${payload.shiftId}, which has not arrived`);
      }
    }

    await this.move(em, meta.tenantId, payload.customerId, -payload.amountSantim);

    await em.getRepository(CreditPayment).insert({
      id: meta.entityId,
      tenantId: meta.tenantId,
      branchId: meta.branchId,
      customerId: payload.customerId,
      amountSantim: payload.amountSantim,
      method: payload.method,
      paidAt: new Date(payload.paidAt),
      shiftId: payload.shiftId,
      receivedBy: payload.receivedBy,
      terminalId: meta.terminalId,
      note: payload.note?.trim() || null,
      changeSeq: 0,
      deletedAt: null,
    });
  }

  /**
   * Moves a balance by a signed amount, under a row lock.
   *
   * Locked because two terminals of one pharmacy can sync at the same moment, each with a
   * sale for the same organisation. Read-then-write without the lock would lose one of the
   * two debts — silently, and in the pharmacy's disfavour.
   */
  private async move(
    em: EntityManager,
    tenantId: string,
    customerId: string,
    deltaSantim: number,
  ): Promise<void> {
    const customer = await em
      .getRepository(Customer)
      .createQueryBuilder('c')
      // NO KEY UPDATE: the balance is changing, not the id. It does not block — or wait
      // on — the shared lock a sale's foreign key takes on this row.
      .setLock('for_no_key_update')
      .where('c.id = :id', { id: customerId })
      .getOne();
    if (!customer) throw new Error(`unknown customer ${customerId}`);

    // A sale that names a customer but puts nothing on credit moves nothing — and so tells
    // the terminals nothing; the lock above is all it needed.
    if (deltaSantim === 0) return;

    customer.balanceSantim += deltaSantim;
    customer.changeSeq = await this.changeSeq.next(em, tenantId);
    await em.getRepository(Customer).save(customer);
  }

  /**
   * Customers whose running balance disagrees with their rows. Empty is the only acceptable
   * answer; anything else is a money defect (G4).
   */
  async verify(
    em: EntityManager,
  ): Promise<Array<{ customerId: string; balance: number; rows: number }>> {
    const out: Array<{ customer_id: string; balance: string; rows: string }> = await em.query(`
      SELECT c.id AS customer_id,
             c.balance_santim AS balance,
             coalesce(d.owed, 0) - coalesce(p.paid, 0) AS rows
        FROM customer c
        LEFT JOIN (
              SELECT s.customer_id, sum(pay.amount_santim) AS owed
                FROM sale s
                JOIN payment pay ON pay.sale_id = s.id AND pay.method = 'credit'
               WHERE s.customer_id IS NOT NULL
                 AND s.deleted_at IS NULL AND pay.deleted_at IS NULL
               GROUP BY s.customer_id
             ) d ON d.customer_id = c.id
        LEFT JOIN (
              SELECT customer_id, sum(amount_santim) AS paid
                FROM credit_payment
               WHERE deleted_at IS NULL
               GROUP BY customer_id
             ) p ON p.customer_id = c.id
       WHERE c.balance_santim <> coalesce(d.owed, 0) - coalesce(p.paid, 0)
    `);
    return out.map((r) => ({
      customerId: r.customer_id,
      balance: Number(r.balance),
      rows: Number(r.rows),
    }));
  }
}
