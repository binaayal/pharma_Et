import {
  Column,
  CreateDateColumn,
  Entity,
  PrimaryColumn,
  UpdateDateColumn,
  VersionColumn,
} from 'typeorm';
import { bigintTransformer } from '../common/transformers/numeric.transformer';

/**
 * Where one person's end-of-day summary is delivered on Telegram (FR-17, ADR-039).
 *
 * Not a synced entity: no terminal ever sees it. It is server-side plumbing between an
 * owner and a chat.
 */
@Entity('telegram_link')
export class TelegramLink {
  @PrimaryColumn('uuid')
  id: string;

  @Column('uuid', { name: 'tenant_id' })
  tenantId: string;

  @Column('uuid', { name: 'user_id' })
  userId: string;

  /** The chat the summary goes to. A string: Telegram ids outgrow a JS number's safe range. */
  @Column('bigint', { name: 'chat_id', nullable: true })
  chatId: string | null;

  /** SHA-256 of the one-time linking code. The code itself is never stored. */
  @Column('text', { name: 'code_hash', nullable: true })
  codeHash: string | null;

  @Column('timestamptz', { name: 'code_expires_at', nullable: true })
  codeExpiresAt: Date | null;

  /** Which language to write to this person in — a delivery preference (BR-10.2). */
  @Column('text', { name: 'message_language', default: 'en' })
  locale: 'en' | 'am';

  @Column('timestamptz', { name: 'linked_at', nullable: true })
  linkedAt: Date | null;

  /** The shop's day (YYYY-MM-DD) the last summary was sent for. */
  @Column('date', { name: 'last_sent_for', nullable: true })
  lastSentFor: string | null;

  @CreateDateColumn({ name: 'created_at', type: 'timestamptz' })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'timestamptz' })
  updatedAt: Date;

  @Column('timestamptz', { name: 'deleted_at', nullable: true })
  deletedAt: Date | null;

  /** Carried by every tenant table (docs/04 §2). */
  @VersionColumn({ name: 'row_version' })
  rowVersion: number;

  /** Always 0: no terminal pulls this table. Present so the convention has no exceptions. */
  @Column('bigint', { name: 'change_seq', default: 0, transformer: bigintTransformer })
  changeSeq: number;
}
