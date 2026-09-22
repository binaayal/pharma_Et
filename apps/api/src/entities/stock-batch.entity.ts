import { Column, Entity } from 'typeorm';
import { bigintTransformer } from '../common/transformers/numeric.transformer';
import { SyncedEntity } from './base.entity';

/**
 * Standard-drug stock, at batch/lot granularity with an expiry date (BR-3.1) — which is
 * what makes FEFO selection and expiry alerting possible at all.
 *
 * `qtyOnHand` MAY GO NEGATIVE, by design. A sale is never blocked by a stock count
 * (BR-3.2): an offline terminal cannot know the true count, and refusing the sale would
 * stop the counter, which is the one thing this product exists to prevent. Oversell is
 * detected, counted, and surfaced for physical reconciliation — never silently swallowed
 * (guardian G5, ADR-002).
 *
 * Controlled substances never appear in this table.
 */
@Entity('stock_batch')
export class StockBatch extends SyncedEntity {
  @Column('uuid', { name: 'branch_id' })
  branchId: string;

  @Column('uuid', { name: 'product_id' })
  productId: string;

  @Column('text', { name: 'lot_no' })
  lotNo: string;

  @Column('date', { name: 'expiry_date' })
  expiryDate: string;

  @Column('bigint', { name: 'qty_on_hand', transformer: bigintTransformer })
  qtyOnHand: number;
}
