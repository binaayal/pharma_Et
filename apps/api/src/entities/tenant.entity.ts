import { Column, Entity, PrimaryColumn } from 'typeorm';

/**
 * A pharmacy business, and the isolation boundary of the whole system (ADR-003).
 *
 * `tenant` itself is not tenant-scoped data — it IS the tenant — so it does not extend
 * SyncedEntity.
 */
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

  /** Operational state of the business record. Subscription state lives separately. */
  @Column('text', { default: 'active' })
  status: 'active' | 'closed';

  @Column('timestamptz', { name: 'created_at', default: () => 'now()' })
  createdAt: Date;

  @Column('timestamptz', { name: 'deleted_at', nullable: true })
  deletedAt: Date | null;
}
