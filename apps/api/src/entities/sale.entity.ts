import { Column, Entity, JoinColumn, ManyToOne, OneToMany } from 'typeorm';
import { bigintTransformer } from '../common/transformers/numeric.transformer';
import { SyncedEntity } from './base.entity';

/**
 * A completed sale. Created on the terminal, offline-first, and normally reaches the server
 * through /sync/push rather than a direct POST (docs/04 §9).
 */
@Entity('sale')
export class Sale extends SyncedEntity {
  @Column('uuid', { name: 'branch_id' })
  branchId: string;

  @Column('uuid', { name: 'shift_id', nullable: true })
  shiftId: string | null;

  @Column('uuid', { name: 'cashier_id' })
  cashierId: string;

  /** Integer santim. Guardian G4 asserts this equals the sum of its line totals. */
  @Column('bigint', { name: 'total_santim', transformer: bigintTransformer })
  totalSantim: number;

  @Column('timestamptz', { name: 'sold_at' })
  soldAt: Date;

  /** The terminal that rang it — forensics for a sync dispute (BR-4.3). */
  @Column('uuid', { name: 'terminal_id' })
  terminalId: string;

  @OneToMany(() => SaleLine, (line) => line.sale, { cascade: ['insert'] })
  lines: SaleLine[];

  @OneToMany(() => Payment, (payment) => payment.sale, { cascade: ['insert'] })
  payments: Payment[];
}

@Entity('sale_line')
export class SaleLine extends SyncedEntity {
  @Column('uuid', { name: 'sale_id' })
  saleId: string;

  @ManyToOne(() => Sale, (sale) => sale.lines)
  @JoinColumn({ name: 'sale_id' })
  sale: Sale;

  @Column('uuid', { name: 'product_id' })
  productId: string;

  /** The FEFO-selected batch for a standard drug. */
  @Column('uuid', { name: 'batch_id', nullable: true })
  batchId: string | null;

  @Column('bigint', { transformer: bigintTransformer })
  qty: number;

  @Column('bigint', { name: 'unit_price_santim', transformer: bigintTransformer })
  unitPriceSantim: number;

  @Column('bigint', { name: 'line_total_santim', transformer: bigintTransformer })
  lineTotalSantim: number;
}

@Entity('payment')
export class Payment extends SyncedEntity {
  @Column('uuid', { name: 'sale_id' })
  saleId: string;

  @ManyToOne(() => Sale, (sale) => sale.payments)
  @JoinColumn({ name: 'sale_id' })
  sale: Sale;

  /** V1 has no gateway integration; non-cash tenders are recorded, not settled (Vision §4). */
  @Column('text')
  method: 'cash' | 'other_recorded';

  @Column('bigint', { name: 'amount_santim', transformer: bigintTransformer })
  amountSantim: number;
}
