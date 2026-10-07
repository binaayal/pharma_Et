import { Column, Entity } from 'typeorm';
import { bigintTransformer } from '../common/transformers/numeric.transformer';
import { SyncedEntity } from './base.entity';

/** A supplier, and what the pharmacy owes them (FR-18, ADR-038). */
@Entity('supplier')
export class Supplier extends SyncedEntity {
  @Column('text')
  name: string;

  @Column('text', { nullable: true })
  phone: string | null;

  @Column('text', { nullable: true })
  note: string | null;

  /**
   * What the pharmacy owes this supplier, in santim; negative when it has paid ahead.
   *
   * Maintained in the transaction that records the delivery or the payment, and
   * recomputable from those rows (`PayablesService.verify`). Every change bumps `change_seq`,
   * which is how the new figure reaches the terminals.
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

/** Money paid to a supplier against what is owed (FR-18). */
@Entity('supplier_payment')
export class SupplierPayment extends SyncedEntity {
  @Column('uuid', { name: 'branch_id' })
  branchId: string;

  @Column('uuid', { name: 'supplier_id' })
  supplierId: string;

  @Column('bigint', { name: 'amount_santim', transformer: bigintTransformer })
  amountSantim: number;

  @Column('text')
  method: 'cash' | 'other_recorded';

  @Column('timestamptz', { name: 'paid_at' })
  paidAt: Date;

  /** The till the cash came out of. Cash here comes off that shift's expected cash. */
  @Column('uuid', { name: 'shift_id', nullable: true })
  shiftId: string | null;

  @Column('uuid', { name: 'paid_by' })
  paidBy: string;

  @Column('uuid', { name: 'terminal_id', nullable: true })
  terminalId: string | null;

  @Column('text', { nullable: true })
  note: string | null;
}
