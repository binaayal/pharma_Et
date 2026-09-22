import { Column, Entity } from 'typeorm';
import { SyncedEntity } from './base.entity';

/**
 * Which branches a user may act in. Owners are all-branch by role and need no rows here;
 * branch managers and cashiers are scoped by these rows (docs/04 §5.1).
 */
@Entity('user_branch')
export class UserBranch extends SyncedEntity {
  @Column('uuid', { name: 'user_id' })
  userId: string;

  @Column('uuid', { name: 'branch_id' })
  branchId: string;
}
