import { Column, CreateDateColumn, Entity, PrimaryColumn, UpdateDateColumn } from 'typeorm';
import { bigintTransformer } from '../common/transformers/numeric.transformer';

export type SubscriptionState = 'pending' | 'active' | 'suspended';
export type PaymentProofResult = 'pending' | 'accepted' | 'rejected';

/**
 * Us. Deliberately **not** a tenant user (docs/04 §5.1, BR-2.2).
 *
 * No `tenant_id`, no RLS policy, a separate login and a distinct token type. That
 * separation is what makes "a Platform Admin has no default access to tenant data" a
 * structural fact rather than a promise: there is no token that is both, so there is no
 * code path that can accidentally treat one as the other.
 *
 * Created by migration or by an operator, never through the API. An endpoint that mints
 * platform identities is an escalation path however carefully it is guarded.
 */
@Entity('platform_admin')
export class PlatformAdmin {
  @PrimaryColumn('uuid')
  id: string;

  @Column('text')
  email: string;

  @Column('text', { name: 'display_name' })
  displayName: string;

  @Column('text', { name: 'password_hash' })
  passwordHash: string;

  @CreateDateColumn({ name: 'created_at', type: 'timestamptz' })
  createdAt: Date;

  @Column('timestamptz', { name: 'deleted_at', nullable: true })
  deletedAt: Date | null;
}

/**
 * A tenant's standing with us (docs/04 §5.8).
 *
 * `suspended` does **not** mean the pharmacy stops working. It blocks management writes and
 * nothing else — records already made still sync, reference data still pulls, reports still
 * read. ADR-016 sets out why: refusing a queued sale because a subscription lapsed destroys
 * a pharmacy's trading records over a billing dispute.
 */
@Entity('subscription')
export class Subscription {
  @PrimaryColumn('uuid')
  id: string;

  @Column('uuid', { name: 'tenant_id' })
  tenantId: string;

  @Column('text')
  state: SubscriptionState;

  /** Null while pending — nothing has been paid for, so no period has an end. */
  @Column('timestamptz', { name: 'current_period_end', nullable: true })
  currentPeriodEnd: Date | null;

  /** ETB 1,000/month at the time of writing (Vision §4), in santim. */
  @Column('bigint', { name: 'price_santim', transformer: bigintTransformer })
  priceSantim: number;

  /** Why, in the words the owner will be shown. A suspension with no reason is a support call. */
  @Column('text', { name: 'suspended_reason', nullable: true })
  suspendedReason: string | null;

  @CreateDateColumn({ name: 'created_at', type: 'timestamptz' })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'timestamptz' })
  updatedAt: Date;
}

/**
 * A screenshot of a payment, awaiting a human (Vision §4).
 *
 * The image lives in object storage; this row holds a reference. Screenshots in a relational
 * column bloat every backup and every restore drill, and the restore drill is a GA gate
 * (`06` §11).
 */
@Entity('payment_proof')
export class PaymentProof {
  @PrimaryColumn('uuid')
  id: string;

  @Column('uuid', { name: 'tenant_id' })
  tenantId: string;

  @Column('text', { name: 'storage_key' })
  storageKey: string;

  @Column('text', { name: 'content_type' })
  contentType: string;

  @Column('bigint', { name: 'byte_size', transformer: bigintTransformer })
  byteSize: number;

  @Column('uuid', { name: 'submitted_by' })
  submittedBy: string;

  @Column('timestamptz', { name: 'submitted_at' })
  submittedAt: Date;

  /** What the tenant says they paid. Checked by a human against the image. */
  @Column('bigint', { name: 'amount_santim', transformer: bigintTransformer })
  amountSantim: number;

  @Column('text', { nullable: true })
  note: string | null;

  @Column('text')
  result: PaymentProofResult;

  @Column('uuid', { name: 'verified_by', nullable: true })
  verifiedBy: string | null;

  @Column('timestamptz', { name: 'verified_at', nullable: true })
  verifiedAt: Date | null;

  /** Required on a rejection: without it the tenant cannot fix whatever was wrong. */
  @Column('text', { name: 'rejection_reason', nullable: true })
  rejectionReason: string | null;

  @CreateDateColumn({ name: 'created_at', type: 'timestamptz' })
  createdAt: Date;

  @UpdateDateColumn({ name: 'updated_at', type: 'timestamptz' })
  updatedAt: Date;
}
