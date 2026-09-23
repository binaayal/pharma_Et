import { Column, Entity, JoinColumn, ManyToOne, OneToMany } from 'typeorm';
import { bigintTransformer } from '../common/transformers/numeric.transformer';
import { SyncedEntity } from './base.entity';

/** Stock in (FR-7 base). Supplier is free-form in V1; a supplier entity is deferred. */
@Entity('goods_receipt')
export class GoodsReceipt extends SyncedEntity {
  @Column('uuid', { name: 'branch_id' })
  branchId: string;

  @Column('text', { name: 'supplier_name' })
  supplierName: string;

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
}
