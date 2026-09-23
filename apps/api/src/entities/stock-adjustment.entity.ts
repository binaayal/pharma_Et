import { Column, Entity } from 'typeorm';
import { bigintTransformer } from '../common/transformers/numeric.transformer';
import { SyncedEntity } from './base.entity';

/**
 * A manual correction to a stock count (FR-3, docs/04 §5.3).
 *
 * The act BR-3.2 promises when it says an oversell is "flagged for physical
 * reconciliation": somebody counted the shelf, the shelf won, and this is the record of
 * that having happened and why.
 */
@Entity('stock_adjustment')
export class StockAdjustment extends SyncedEntity {
  @Column('uuid', { name: 'branch_id' })
  branchId: string;

  @Column('uuid', { name: 'batch_id' })
  batchId: string;

  @Column('uuid', { name: 'product_id' })
  productId: string;

  @Column('uuid', { name: 'actor_id' })
  actorId: string;

  @Column('uuid', { name: 'terminal_id', nullable: true })
  terminalId: string | null;

  /** Signed change. Negative writes stock off; positive adds it back. */
  @Column('bigint', { transformer: bigintTransformer })
  delta: number;

  @Column('text')
  reason:
    'recount' | 'damage' | 'expiry_writeoff' | 'theft_or_loss' | 'receipt_correction' | 'other';

  @Column('text', { nullable: true })
  note: string | null;

  /** What the terminal believed the count was. Keeps the decision reconstructable. */
  @Column('bigint', { name: 'previous_qty_on_hand', transformer: bigintTransformer })
  previousQtyOnHand: number;

  @Column('timestamptz', { name: 'counted_at' })
  countedAt: Date;
}
