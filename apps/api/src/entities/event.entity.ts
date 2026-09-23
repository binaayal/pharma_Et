import { Column, Entity, PrimaryColumn } from 'typeorm';
import { bigintTransformer } from '../common/transformers/numeric.transformer';

/**
 * An immutable record that something happened (docs/04 §5.6, ADR-004).
 *
 * Deliberately **not** a `SyncedEntity`. It has no `updated_at`, no `deleted_at` and no
 * `row_version`, because every one of those columns describes a mutation this table does not
 * permit. Giving it a `deleted_at` would suggest a delete exists to be soft; it does not,
 * and a tombstone here is a new event, not a flag on an old one.
 *
 * The database refuses UPDATE, DELETE and TRUNCATE outright, including for the owner role
 * (see the EventStore migration). This class is the shape; the guarantee lives one layer
 * down, where a bug in this file cannot reach it.
 */
@Entity('event')
export class DomainEvent {
  @PrimaryColumn('uuid')
  id: string;

  @Column('uuid', { name: 'tenant_id' })
  tenantId: string;

  @Column('uuid', { name: 'branch_id', nullable: true })
  branchId: string | null;

  /**
   * What this log is for. `audit` is the general who-did-what (Vision §2.1.1).
   * `controlled_stock` is reserved and unused until A-1 clears (ADR-015).
   */
  @Column('text')
  stream: 'audit' | 'controlled_stock';

  /** The aggregate this event concerns — a product, a user, a branch. */
  @Column('uuid', { name: 'stream_id' })
  streamId: string;

  /**
   * Position within the stream, from 1, with no gaps. A gap in an audit trail cannot be
   * distinguished from a deletion, which is the one thing this table must be able to
   * rule out.
   */
  @Column('bigint', { transformer: bigintTransformer })
  seq: number;

  @Column('text', { name: 'event_type' })
  eventType: string;

  @Column('jsonb', { default: {} })
  payload: Record<string, unknown>;

  @Column('uuid', { name: 'actor_id' })
  actorId: string;

  @Column('uuid', { name: 'terminal_id', nullable: true })
  terminalId: string | null;

  /** When it happened. */
  @Column('timestamptz', { name: 'occurred_at' })
  occurredAt: Date;

  /** When we heard about it. The gap between the two is the offline window at work. */
  @Column('timestamptz', { name: 'recorded_at' })
  recordedAt: Date;

  @Column('uuid', { name: 'op_id', nullable: true })
  opId: string | null;
}
