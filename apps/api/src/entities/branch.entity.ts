import { Column, Entity } from 'typeorm';
import { SyncedEntity } from './base.entity';

/** A physical store. A tenant always has at least one (BR-1.1). */
@Entity('branch')
export class Branch extends SyncedEntity {
  @Column('text')
  name: string;

  @Column('text', { nullable: true })
  address: string | null;
}
