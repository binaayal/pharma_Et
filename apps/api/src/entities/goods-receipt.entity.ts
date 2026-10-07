import { Column, Entity, JoinColumn, ManyToOne, OneToMany } from 'typeorm';
import { bigintTransformer } from '../common/transformers/numeric.transformer';
import { SyncedEntity } from './base.entity';

/** Stock in (FR-7 base), and what of it is still owed to the supplier (FR-18). */
@Entity('goods_receipt')
export class GoodsReceipt extends SyncedEntity {
  @Column('uuid', { name: 'branch_id' })
  branchId: string;

  /** The supplier's name as written on the day. Kept even when `supplierId` is set. */
  @Column('text', { name: 'supplier_name' })
  supplierName: string;

  /** Which supplier (FR-18, ADR-038). Null on a receipt from before suppliers existed. */
  @Column('uuid', { name: 'supplier_id', nullable: true })
  supplierId: string | null;

  /** The part of this delivery not paid for when it arrived. Zero: paid on delivery. */
  @Column('bigint', { name: 'owed_santim', default: 0, transformer: bigintTransformer })
  owedSantim: number;

  @Column('timestamptz', { name: 'received_at' })
  receivedAt: Date;

  @Column('uuid', { name: 'terminal_id' })
  terminalId: string;

  @OneToMany(() => GoodsReceiptLine, (line) => line.receipt, { cascade: ['insert'] })
  lines: GoodsReceiptLine[];
}

@Entity('goods_receipt_line')
export class GoodsReceiptLine extends SyncedEntity {
  @Column('uuid', { name: 'goods_receipt_id' })
  goodsReceiptId: string;

  @ManyToOne(() => GoodsReceipt, (receipt) => receipt.lines)
  @JoinColumn({ name: 'goods_receipt_id' })
  receipt: GoodsReceipt;

  @Column('uuid', { name: 'product_id' })
  productId: string;

  @Column('text', { name: 'lot_no' })
  lotNo: string;

  @Column('date', { name: 'expiry_date' })
  expiryDate: string;

  @Column('bigint', { transformer: bigintTransformer })
  qty: number;

  @Column('bigint', { name: 'cost_santim', transformer: bigintTransformer })
  costSantim: number;

  /** Base units in one unit of `qty` when received by the pack (FR-11). Null = base unit. */
  @Column('integer', { name: 'pack_size', nullable: true })
  packSize: number | null;
}
