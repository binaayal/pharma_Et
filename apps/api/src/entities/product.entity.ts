import { Column, Entity } from 'typeorm';
import { bigintTransformer } from '../common/transformers/numeric.transformer';
import { SyncedEntity } from './base.entity';

/**
 * One pack as stored on the row. The same shape as the contract's `ProductPack`, declared
 * here rather than imported: the data source compiles the entities to run migrations, and
 * that happens in places where the contracts package has not been built yet (the rollback
 * and coverage jobs). An entity that needs a build step to load would make "apply the
 * migrations" depend on something other than the migrations.
 */
export interface StoredPack {
  name: string;
  size: number;
  priceSantim: number;
}

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

  /** Base unit — what stock is counted in. The packs below are defined against it. */
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

  /**
   * The packs this product is also received and sold in, each with its own price (FR-11,
   * ADR-030). Empty for a product sold only in its base unit.
   *
   * A list on the row rather than a table: it is read whole on every pull, written whole on
   * every edit, and never queried by its contents. Its history is the audit log's
   * `audit.packs_changed`, which records the list before and after.
   */
  @Column('jsonb', { default: () => "'[]'::jsonb" })
  packs: StoredPack[];

  /**
   * The barcodes that identify this product at the counter, in canonical form (FR-13,
   * ADR-031). Several, because one medicine comes from several manufacturers. No barcode
   * belongs to two products of one pharmacy — held by `ManagementService.setBarcodes`.
   */
  @Column('jsonb', { default: () => "'[]'::jsonb" })
  barcodes: string[];
}
