import { Column, Entity } from 'typeorm';
import { bigintTransformer } from '../common/transformers/numeric.transformer';
import { SyncedEntity } from './base.entity';

/**
 * A catalog item.
 *
 * `isControlled` is the switch between the system's two persistence models (ADR-004):
 * standard drugs carry mutable stock rows, controlled substances have no mutable stock at
 * all — their quantity is a projection over the append-only ledger (BR-3.3).
 */
@Entity('product')
export class Product extends SyncedEntity {
  @Column('text')
  name: string;

  /** Base unit. Pack conversions are resolved at product definition, not at sale time. */
  @Column('text')
  unit: string;

  @Column('boolean', { name: 'is_controlled', default: false })
  isControlled: boolean;

  @Column('text', { name: 'psychotropic_class', nullable: true })
  psychotropicClass: string | null;

  /**
   * Current price, denormalised from `product_price` for fast reads and for the pull
   * payload. Price history remains authoritative in `product_price`.
   */
  @Column('bigint', { name: 'current_price_santim', transformer: bigintTransformer })
  currentPriceSantim: number;
}
