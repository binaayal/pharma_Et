import { Column, Entity, PrimaryColumn } from 'typeorm';
import { bigintTransformer } from '../common/transformers/numeric.transformer';

/**
 * The idempotency ledger (ADR-006).
 *
 * UNIQUE(tenant_id, op_id) is what makes a retried push safe. A terminal that loses the
 * connection mid-batch retries the whole batch; every already-applied operation comes back
 * `duplicate` instead of being applied twice. This table is the reason guardian G2 can
 * assert exactly-once (AC-9.2).
 */
@Entity('applied_op')
export class AppliedOp {
  @PrimaryColumn('uuid', { name: 'tenant_id' })
  tenantId: string;

  @PrimaryColumn('uuid', { name: 'op_id' })
  opId: string;

  @Column('uuid', { name: 'entity_id' })
  entityId: string;

  @Column('text', { name: 'entity_type' })
  entityType: string;

  @Column('uuid', { name: 'terminal_id' })
  terminalId: string;

  @Column('bigint', { name: 'terminal_seq', transformer: bigintTransformer })
  terminalSeq: number;

  @Column('timestamptz', { name: 'applied_at', default: () => 'now()' })
  appliedAt: Date;
}

/**
 * Per-tenant monotonic counter, bumped on every reference-data write; it is the delta-pull
 * cursor (docs/04 §7.2).
 */
@Entity('tenant_change_seq')
export class TenantChangeSeq {
  @PrimaryColumn('uuid', { name: 'tenant_id' })
  tenantId: string;

  @Column('bigint', { default: 0, transformer: bigintTransformer })
  value: number;
}

/**
 * Oversell observations (BR-3.2, guardian G5, NFR-7).
 *
 * An oversell is a real business event, not a log line: stock went negative, so something
 * physical needs reconciling. It is recorded as a row precisely so it can be counted,
 * reported, and noticed — the failure mode we refuse is the silent one.
 */
@Entity('oversell_event')
export class OversellEvent {
  @PrimaryColumn('uuid')
  id: string;

  @Column('uuid', { name: 'tenant_id' })
  tenantId: string;

  @Column('uuid', { name: 'branch_id' })
  branchId: string;

  @Column('uuid', { name: 'product_id' })
  productId: string;

  @Column('uuid', { name: 'batch_id', nullable: true })
  batchId: string | null;

  @Column('uuid', { name: 'sale_id' })
  saleId: string;

  /** How far below zero this sale drove the batch. Always negative. */
  @Column('bigint', { name: 'resulting_qty', transformer: bigintTransformer })
  resultingQty: number;

  @Column('timestamptz', { name: 'observed_at', default: () => 'now()' })
  observedAt: Date;
}
