import { Column, Entity } from 'typeorm';
import { bigintTransformer } from '../common/transformers/numeric.transformer';
import { SyncedEntity } from './base.entity';

/**
 * A staff member's till session (docs/04 §5.4).
 *
 * The unit a cash-up reconciles. Opened and closed on the terminal, offline — a pharmacy
 * closes its till at the end of the day, which is frequently when the power is out.
 */
@Entity('shift')
export class Shift extends SyncedEntity {
  @Column('uuid', { name: 'branch_id' })
  branchId: string;

  @Column('uuid', { name: 'user_id' })
  userId: string;

  @Column('uuid', { name: 'terminal_id' })
  terminalId: string;

  @Column('timestamptz', { name: 'opened_at' })
  openedAt: Date;

  /** Null while open. A shift closes exactly once. */
  @Column('timestamptz', { name: 'closed_at', nullable: true })
  closedAt: Date | null;

  /**
   * What was in the drawer before trading started. Part of the expected figure — omitting
   * it would report a variance equal to the float on every shift, and a control that is
   * always wrong is a control that gets ignored.
   */
  @Column('bigint', { name: 'opening_float_santim', transformer: bigintTransformer })
  openingFloatSantim: number;
}

/**
 * The Z-report (FR-8, BR-8.2): counted cash against what the system expected.
 *
 * Two expected figures live here, deliberately (ADR-012 §3):
 *
 *   - `expectedSantim` is what the TERMINAL computed and showed the cashier. It is never
 *     recomputed. Rewriting the number a person was asked to reconcile against destroys the
 *     only evidence of what they actually agreed to.
 *   - `serverExpectedSantim` is what the SERVER recomputes from synced sales on arrival.
 *     When the two differ it is usually because sales were still queued — and that
 *     divergence is itself worth showing, not smoothing away.
 */
@Entity('cash_up')
export class CashUp extends SyncedEntity {
  @Column('uuid', { name: 'shift_id' })
  shiftId: string;

  @Column('uuid', { name: 'branch_id' })
  branchId: string;

  @Column('uuid', { name: 'user_id' })
  userId: string;

  @Column('timestamptz', { name: 'counted_at' })
  countedAt: Date;

  @Column('bigint', { name: 'expected_santim', transformer: bigintTransformer })
  expectedSantim: number;

  @Column('bigint', { name: 'counted_santim', transformer: bigintTransformer })
  countedSantim: number;

  /** `counted − expected`. Negative means cash is missing. */
  @Column('bigint', { name: 'variance_santim', transformer: bigintTransformer })
  varianceSantim: number;

  @Column('bigint', {
    name: 'server_expected_santim',
    nullable: true,
    transformer: bigintTransformer,
  })
  serverExpectedSantim: number | null;

  /** The cashier's own explanation, if they gave one. Free text, never parsed. */
  @Column('text', { nullable: true })
  note: string | null;
}
