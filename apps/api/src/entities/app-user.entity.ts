import { Column, Entity } from 'typeorm';
import { SyncedEntity } from './base.entity';

export type UserRole = 'owner' | 'branch_manager' | 'cashier';

/**
 * A user inside a tenant. The Platform Admin is deliberately NOT modelled here: it is a
 * separate identity outside tenant scope (docs/04 §5.1, BR-2.2), so that no bug in tenant
 * code can ever mint platform authority.
 */
@Entity('app_user')
export class AppUser extends SyncedEntity {
  @Column('text')
  username: string;

  @Column('text', { name: 'display_name' })
  displayName: string;

  @Column('text')
  role: UserRole;

  /** Argon2id hash of the counter PIN. Never the PIN itself, online or on the device. */
  @Column('text', { name: 'pin_hash', nullable: true })
  pinHash: string | null;

  @Column('text', { name: 'password_hash', nullable: true })
  passwordHash: string | null;
}
