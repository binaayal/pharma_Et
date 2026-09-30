import { Column, Entity, PrimaryColumn } from 'typeorm';

/**
 * A pharmacy business, and the isolation boundary of the whole system (ADR-003).
 *
 * `tenant` itself is not tenant-scoped data — it IS the tenant — so it does not extend
 * SyncedEntity.
 */
export type TenantStatus = 'active' | 'closed' | 'deactivated';

@Entity('tenant')
export class Tenant {
  @PrimaryColumn('uuid')
  id: string;

  @Column('text')
  name: string;

  /**
   * Short, human-typeable code issued at onboarding. Login quotes it because authentication
   * happens before any tenant scope exists (see LoginRequest in @pharmaet/contracts).
   */
  @Column('text')
  code: string;

  /**
   * Operational state of the business record. Subscription state lives separately.
   *
   * `deactivated` is the platform's forced stop for a policy breach (ADR-025) — unlike a
   * suspended subscription (ADR-016), it refuses every request, sign-in included.
   */
  @Column('text', { default: 'active' })
  status: TenantStatus;

  @Column('timestamptz', { name: 'deactivated_at', nullable: true })
  deactivatedAt: Date | null;

  /** Shown to the owner verbatim. Required whenever `status` is `deactivated`. */
  @Column('text', { name: 'deactivated_reason', nullable: true })
  deactivatedReason: string | null;

  /** The platform admin who did it. Never a tenant user. */
  @Column('uuid', { name: 'deactivated_by', nullable: true })
  deactivatedBy: string | null;

  @Column('timestamptz', { name: 'created_at', default: () => 'now()' })
  createdAt: Date;

  @Column('timestamptz', { name: 'deleted_at', nullable: true })
  deletedAt: Date | null;
}
