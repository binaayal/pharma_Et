import { Column, Entity } from 'typeorm';
import { bigintTransformer } from '../common/transformers/numeric.transformer';
import { SyncedEntity } from './base.entity';

/**
 * A customer who may buy on credit (FR-16, ADR-034).
 *
 * Who owes the pharmacy money — not a patient record. No date of birth, no address, nothing
 * about treatment (docs/01 §2.3).
 */
@Entity('customer')
export class Customer extends SyncedEntity {
  @Column('text')
  name: string;

  @Column('text', { nullable: true })
  phone: string | null;

  @Column('text', { nullable: true })
  note: string | null;

  /**
   * What the customer owes, in santim; negative when they have paid ahead.
   *
   * Maintained in the transaction that records the credit sale or the repayment, and
   * recomputable from those rows (`CreditService.verify`). Every change bumps `change_seq`,
   * which is how the new balance reaches the terminals.
   */
  @Column('bigint', { name: 'balance_santim', default: 0, transformer: bigintTransformer })
  balanceSantim: number;

  @Column('uuid', { name: 'created_branch_id', nullable: true })
  createdBranchId: string | null;

  @Column('uuid', { name: 'created_by', nullable: true })
  createdBy: string | null;

  @Column('uuid', { name: 'terminal_id', nullable: true })
  terminalId: string | null;
}

/** Money received against what a customer owes (FR-16). */
@Entity('credit_payment')
export class CreditPayment extends SyncedEntity {
  @Column('uuid', { name: 'branch_id' })
  branchId: string;

  @Column('uuid', { name: 'customer_id' })
  customerId: string;

  @Column('bigint', { name: 'amount_santim', transformer: bigintTransformer })
  amountSantim: number;

  @Column('text')
  method: 'cash' | 'other_recorded';

  @Column('timestamptz', { name: 'paid_at' })
  paidAt: Date;

  /** The till it was taken in. Cash here counts toward that shift's cash-up (BR-8.2). */
  @Column('uuid', { name: 'shift_id', nullable: true })
  shiftId: string | null;

  @Column('uuid', { name: 'received_by' })
  receivedBy: string;

  @Column('uuid', { name: 'terminal_id', nullable: true })
  terminalId: string | null;

  @Column('text', { nullable: true })
  note: string | null;
}
