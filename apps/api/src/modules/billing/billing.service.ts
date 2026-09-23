import { BadRequestException, Injectable, Logger, NotFoundException } from '@nestjs/common';
import type { EntityManager } from 'typeorm';
import { uuidv7 } from 'uuidv7';
import { ScopedDbService } from '../../common/db/scoped-db.service';
import type { TenantScope } from '../../common/db/tenant-scope';
import { PaymentProof, Subscription, type SubscriptionState, Tenant } from '../../entities';
import { AuditService } from '../audit/audit.service';
import { ProofStorageService } from './proof-storage.service';

export interface SubscriptionView {
  state: SubscriptionState;
  currentPeriodEnd: string | null;
  priceSantim: number;
  suspendedReason: string | null;
  daysRemaining: number | null;
  pendingProofCount: number;
}

/**
 * Subscriptions and the manual payment loop (FR-1, Vision §4).
 *
 * There is no payment gateway in V1 and there will not be one for six months or more. A
 * tenant pays ETB 1,000/month, submits a screenshot, and a human looks at it. Everything
 * here serves that loop and nothing pretends to be more automated than it is.
 */
@Injectable()
export class BillingService {
  private readonly logger = new Logger(BillingService.name);

  constructor(
    private readonly db: ScopedDbService,
    private readonly audit: AuditService,
    private readonly storage: ProofStorageService,
  ) {}

  /* ------------------------------------------------------ the tenant's view */

  async mySubscription(scope: TenantScope): Promise<SubscriptionView> {
    return this.db.runInScope(scope, async (em) => {
      const subscription = await em
        .getRepository(Subscription)
        .findOne({ where: { tenantId: scope.tenantId } });
      if (!subscription) throw new NotFoundException('no subscription for this tenant');

      const pending = await em
        .getRepository(PaymentProof)
        .count({ where: { tenantId: scope.tenantId, result: 'pending' } });

      return {
        state: subscription.state,
        currentPeriodEnd: subscription.currentPeriodEnd?.toISOString() ?? null,
        priceSantim: subscription.priceSantim,
        suspendedReason: subscription.suspendedReason,
        // Shown to the owner so "renew soon" is a date they can act on rather than a
        // surprise on the morning everything stops.
        daysRemaining: subscription.currentPeriodEnd
          ? Math.ceil((subscription.currentPeriodEnd.getTime() - Date.now()) / 86_400_000)
          : null,
        pendingProofCount: pending,
      };
    });
  }

  /**
   * The owner submits a screenshot (Vision §4).
   *
   * Permitted while suspended, because it is the one action that ends a suspension
   * (ADR-016).
   */
  async submitProof(
    scope: TenantScope,
    file: { buffer: Buffer; mimetype: string; size: number },
    input: { amountSantim: number; note?: string },
  ): Promise<{ id: string; result: string }> {
    if (!Number.isInteger(input.amountSantim) || input.amountSantim <= 0) {
      throw new BadRequestException('amountSantim must be a positive whole number of santim');
    }

    const stored = await this.storage.put(scope.tenantId, file);

    return this.db.runInScope(scope, async (em) => {
      const id = uuidv7();
      await em.getRepository(PaymentProof).insert({
        id,
        tenantId: scope.tenantId,
        storageKey: stored.storageKey,
        contentType: stored.contentType,
        byteSize: stored.byteSize,
        submittedBy: scope.userId,
        submittedAt: new Date(),
        amountSantim: input.amountSantim,
        note: input.note ?? null,
        result: 'pending',
        verifiedBy: null,
        verifiedAt: null,
        rejectionReason: null,
      });

      await this.audit.record(em, scope, {
        type: 'audit.payment_proof_submitted',
        streamId: id,
        payload: { amountSantim: input.amountSantim, note: input.note ?? null },
      });

      return { id, result: 'pending' };
    });
  }

  async myProofs(scope: TenantScope) {
    return this.db.runInScope(scope, async (em) => {
      const rows = await em
        .getRepository(PaymentProof)
        .find({ order: { submittedAt: 'DESC' }, take: 24 });
      return rows.map((p) => ({
        id: p.id,
        amountSantim: p.amountSantim,
        submittedAt: p.submittedAt.toISOString(),
        result: p.result,
        verifiedAt: p.verifiedAt?.toISOString() ?? null,
        // The tenant sees why it was rejected — without it they cannot fix whatever
        // was wrong, and the next submission is a guess.
        rejectionReason: p.rejectionReason,
        note: p.note,
      }));
    });
  }

  /* --------------------------------------------------- the platform's view */

  /**
   * Every pending proof, oldest first — the human work queue.
   *
   * Runs on the platform connection, which crosses tenants by design and is logged for it
   * (BR-2.2). It reads billing rows only; no sale, no shift, no clinical data.
   */
  async pendingProofs(limit = 100) {
    const rows = await this.db.runAsPlatform('list pending payment proofs for verification', (em) =>
      em.query(
        `SELECT p.id, p.tenant_id AS "tenantId", t.name AS "tenantName", t.code AS "tenantCode",
                p.amount_santim AS "amountSantim", p.submitted_at AS "submittedAt",
                p.note, p.content_type AS "contentType", p.byte_size AS "byteSize",
                s.state AS "subscriptionState"
           FROM payment_proof p
           JOIN tenant t ON t.id = p.tenant_id
           LEFT JOIN subscription s ON s.tenant_id = p.tenant_id
          WHERE p.result = 'pending'
          ORDER BY p.submitted_at ASC
          LIMIT $1`,
        [limit],
      ),
    );

    // A raw query bypasses the entity transformers, so Postgres hands bigint back as a
    // STRING. Left alone, this endpoint would return money as text while every other
    // endpoint returns a number — and a client adding two of them would concatenate rather
    // than sum. The same trap as a `date` column arriving as a Date object.
    return rows.map((r: Record<string, unknown>) => ({
      ...r,
      amountSantim: Number(r.amountSantim),
      byteSize: Number(r.byteSize),
      submittedAt: new Date(r.submittedAt as string).toISOString(),
    }));
  }

  /** The screenshot itself, for the admin who is about to decide on it. */
  async proofImage(proofId: string): Promise<{ buffer: Buffer; contentType: string }> {
    const proof = await this.db.runAsPlatform('read a payment proof image', (em) =>
      em.getRepository(PaymentProof).findOne({ where: { id: proofId } }),
    );
    if (!proof) throw new NotFoundException('payment proof not found');
    return { buffer: await this.storage.get(proof.storageKey), contentType: proof.contentType };
  }

  /**
   * A human decides (Vision §4).
   *
   * Accepting extends the period by a month from whichever is later — now, or the existing
   * end. Extending from *now* would silently shorten the subscription of anyone who pays
   * early, which is exactly the customer you least want to penalise.
   */
  async decideProof(
    adminId: string,
    proofId: string,
    decision: { accept: boolean; reason?: string; periodDays?: number },
  ) {
    if (!decision.accept && !decision.reason?.trim()) {
      throw new BadRequestException('a rejection must say why');
    }

    return this.db.runAsPlatform(`verify payment proof ${proofId}`, async (em) => {
      const proof = await em.getRepository(PaymentProof).findOne({ where: { id: proofId } });
      if (!proof) throw new NotFoundException('payment proof not found');
      if (proof.result !== 'pending') {
        // Deciding twice would overwrite who decided and when, which is exactly the record
        // a dispute turns on.
        throw new BadRequestException(`this proof was already ${proof.result}`);
      }

      proof.result = decision.accept ? 'accepted' : 'rejected';
      proof.verifiedBy = adminId;
      proof.verifiedAt = new Date();
      proof.rejectionReason = decision.accept ? null : decision.reason!.trim();
      await em.getRepository(PaymentProof).save(proof);

      if (!decision.accept) {
        await this.recordPlatformEvent(em, proof.tenantId, adminId, 'audit.payment_rejected', {
          proofId: proof.id,
          amountSantim: proof.amountSantim,
          reason: proof.rejectionReason,
        });
        return { id: proof.id, result: proof.result, subscription: null };
      }

      const subscription = await em
        .getRepository(Subscription)
        .findOne({ where: { tenantId: proof.tenantId } });
      if (!subscription) throw new NotFoundException('no subscription for that tenant');

      const days = decision.periodDays ?? 30;
      const from =
        subscription.currentPeriodEnd && subscription.currentPeriodEnd > new Date()
          ? subscription.currentPeriodEnd
          : new Date();

      const previousState = subscription.state;
      subscription.state = 'active';
      subscription.currentPeriodEnd = new Date(from.getTime() + days * 86_400_000);
      subscription.suspendedReason = null;
      await em.getRepository(Subscription).save(subscription);

      await this.recordPlatformEvent(em, proof.tenantId, adminId, 'audit.payment_accepted', {
        proofId: proof.id,
        amountSantim: proof.amountSantim,
        previousState,
        currentPeriodEnd: subscription.currentPeriodEnd.toISOString(),
      });

      return {
        id: proof.id,
        result: proof.result,
        subscription: {
          state: subscription.state,
          currentPeriodEnd: subscription.currentPeriodEnd.toISOString(),
        },
      };
    });
  }

  /** Suspend or reactivate, by hand. */
  async setSubscriptionState(
    adminId: string,
    tenantId: string,
    state: 'active' | 'suspended',
    reason?: string,
  ) {
    if (state === 'suspended' && !reason?.trim()) {
      // An owner who is suddenly blocked deserves to be told why, in the app, without
      // having to telephone anybody.
      throw new BadRequestException('a suspension must say why — the tenant is shown this');
    }

    return this.db.runAsPlatform(`set subscription state for tenant ${tenantId}`, async (em) => {
      const subscription = await em.getRepository(Subscription).findOne({ where: { tenantId } });
      if (!subscription) throw new NotFoundException('no subscription for that tenant');

      const previousState = subscription.state;
      subscription.state = state;
      subscription.suspendedReason = state === 'suspended' ? reason!.trim() : null;
      if (state === 'active' && !subscription.currentPeriodEnd) {
        // The check constraint requires a period on an active subscription, and an active
        // row with no end is indistinguishable from one that lapsed months ago.
        subscription.currentPeriodEnd = new Date(Date.now() + 30 * 86_400_000);
      }
      await em.getRepository(Subscription).save(subscription);

      await this.recordPlatformEvent(em, tenantId, adminId, 'audit.subscription_changed', {
        previousState,
        state,
        reason: subscription.suspendedReason,
      });

      this.logger.warn(`tenant ${tenantId}: subscription ${previousState} -> ${state}`);
      return { tenantId, state, suspendedReason: subscription.suspendedReason };
    });
  }

  /** Onboards a pharmacy: tenant, its subscription, and its first owner. */
  async createTenant(
    adminId: string,
    input: {
      name: string;
      code: string;
      ownerUsername: string;
      ownerDisplayName: string;
      ownerPin: string;
    },
  ) {
    const argon2 = await import('argon2');

    return this.db.runAsPlatform(`onboard tenant ${input.code}`, async (em) => {
      const existing = await em
        .getRepository(Tenant)
        .findOne({ where: { code: input.code.toLowerCase() } });
      if (existing) throw new BadRequestException(`the code "${input.code}" is already taken`);

      const tenantId = uuidv7();
      await em.getRepository(Tenant).insert({
        id: tenantId,
        name: input.name.trim(),
        code: input.code.trim().toLowerCase(),
        status: 'active',
        deletedAt: null,
      });
      await em.query(`INSERT INTO tenant_change_seq (tenant_id, value) VALUES ($1, 0)`, [tenantId]);

      // Starts `pending`, not `active`: nobody has paid yet. Pending is not suspended — the
      // pharmacy can set itself up and start trading while the first payment is arranged,
      // which is the difference between onboarding and a locked door.
      await em.getRepository(Subscription).insert({
        id: uuidv7(),
        tenantId,
        state: 'pending',
        currentPeriodEnd: null,
        priceSantim: 100_000,
        suspendedReason: null,
      });

      const ownerId = uuidv7();
      await em.query(
        `INSERT INTO app_user (id, tenant_id, username, display_name, role, pin_hash, change_seq)
         VALUES ($1, $2, $3, $4, 'owner', $5, 1)`,
        [
          ownerId,
          tenantId,
          input.ownerUsername.trim().toLowerCase(),
          input.ownerDisplayName.trim(),
          await argon2.hash(input.ownerPin, { type: argon2.argon2id }),
        ],
      );

      await this.recordPlatformEvent(em, tenantId, adminId, 'audit.tenant_onboarded', {
        name: input.name,
        code: input.code,
        ownerUsername: input.ownerUsername,
      });

      return { tenantId, code: input.code.toLowerCase(), ownerId, subscriptionState: 'pending' };
    });
  }

  async listTenants() {
    const rows = await this.db.runAsPlatform('list tenants for the platform console', (em) =>
      em.query(
        `SELECT t.id, t.name, t.code, t.status,
                s.state AS "subscriptionState",
                s.current_period_end AS "currentPeriodEnd",
                s.suspended_reason AS "suspendedReason",
                (SELECT count(*)::int FROM payment_proof p
                  WHERE p.tenant_id = t.id AND p.result = 'pending') AS "pendingProofs"
           FROM tenant t
           LEFT JOIN subscription s ON s.tenant_id = t.id
          WHERE t.deleted_at IS NULL
          ORDER BY t.name`,
      ),
    );

    return rows.map((r: Record<string, unknown>) => ({
      ...r,
      pendingProofs: Number(r.pendingProofs),
      currentPeriodEnd: r.currentPeriodEnd
        ? new Date(r.currentPeriodEnd as string).toISOString()
        : null,
    }));
  }

  /**
   * Writes an audit event for an action taken by a **platform admin**, inside the tenant's
   * own trail.
   *
   * The tenant gets to see what we did to them. An action by us that is invisible to the
   * pharmacy it affects is precisely the kind of thing BR-2.2 exists to prevent, and a
   * suspension the owner cannot find a record of is a support call at best.
   *
   * The actor is the platform admin's id, which is not an `app_user` — the event table does
   * not reference that table for exactly this reason.
   */
  private async recordPlatformEvent(
    em: EntityManager,
    tenantId: string,
    adminId: string,
    type: string,
    payload: Record<string, unknown>,
  ): Promise<void> {
    await this.audit.record(
      em,
      { tenantId, userId: adminId, role: 'owner', branchIds: [] },
      { type: type as never, streamId: tenantId, payload: { ...payload, byPlatformAdmin: true } },
    );
  }
}
