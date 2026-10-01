import {
  BadRequestException,
  GoneException,
  Injectable,
  Logger,
  NotFoundException,
} from '@nestjs/common';
import type { EntityManager } from 'typeorm';
import { uuidv7 } from 'uuidv7';
import { TenantStatusService } from '../../common/auth/tenant-status';
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
    private readonly tenantStatus: TenantStatusService,
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
    if (proof.imageDeletedAt) {
      throw new GoneException('this screenshot was deleted after the payment was decided');
    }
    return { buffer: await this.storage.get(proof.storageKey), contentType: proof.contentType };
  }

  /**
   * Deletes a decided proof's screenshot for good (ADR-028), keeping the billing record.
   *
   * Only once decided: deleting the evidence before the decision would leave a pending
   * proof nobody can verify. Idempotent — deleting twice is not an error.
   */
  async deleteProofImage(adminId: string, proofId: string) {
    const proof = await this.db.runAsPlatform(`look up payment proof ${proofId}`, (em) =>
      em.getRepository(PaymentProof).findOne({ where: { id: proofId } }),
    );
    if (!proof) throw new NotFoundException('payment proof not found');
    if (proof.result === 'pending') {
      throw new BadRequestException('decide on this payment before deleting its screenshot');
    }
    if (proof.imageDeletedAt) return { id: proof.id, imageDeletedAt: proof.imageDeletedAt };

    await this.storage.remove(proof.storageKey);
    const deletedAt = new Date();
    await this.db.runAsPlatform(`mark payment proof ${proofId} image deleted`, async (em) => {
      await em.getRepository(PaymentProof).update({ id: proof.id }, { imageDeletedAt: deletedAt });
      await this.recordPlatformEvent(
        em,
        proof.tenantId,
        adminId,
        'audit.payment_proof_image_deleted',
        {
          proofId: proof.id,
          result: proof.result,
        },
      );
    });
    return { id: proof.id, imageDeletedAt: deletedAt.toISOString() };
  }

  /** Every decided proof whose screenshot is still stored — the console's "free space" list. */
  async decidedProofsWithImages() {
    const rows = await this.db.runAsPlatform('count decided screenshots still stored', (em) =>
      em.query(
        `SELECT p.id, p.byte_size AS "byteSize" FROM payment_proof p
          WHERE p.result <> 'pending' AND p.image_deleted_at IS NULL`,
      ),
    );
    return rows.map((r: { id: string; byteSize: string }) => ({
      id: r.id,
      byteSize: Number(r.byteSize),
    }));
  }

  /** Deletes every decided proof's screenshot that is still stored. */
  async purgeDecidedImages(adminId: string) {
    const decided = await this.decidedProofsWithImages();
    for (const proof of decided) await this.deleteProofImage(adminId, proof.id);
    return {
      deleted: decided.length,
      bytesFreed: decided.reduce((sum: number, p: { byteSize: number }) => sum + p.byteSize, 0),
    };
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
    decision: { accept: boolean; reason?: string; periodDays?: number; deleteImage?: boolean },
  ) {
    const result = await this.decide(adminId, proofId, decision);
    // After the decision has committed: a failed delete must never undo a payment decision.
    // The console's "free space" action catches anything left behind.
    if (decision.deleteImage) {
      await this.deleteProofImage(adminId, proofId).catch((error) =>
        this.logger.warn(`screenshot for ${proofId} not deleted: ${error}`),
      );
    }
    return { ...result, imageDeleted: Boolean(decision.deleteImage) };
  }

  private async decide(
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

  /**
   * Forcefully deactivates a pharmacy for a policy breach (ADR-025).
   *
   * Every request from the tenant is refused from the next one on — sign-in, refresh, reads
   * and sync alike — and a terminal that hears it wipes its offline sign-in. Nothing is
   * deleted: the tenant's records stay exactly as they are, and so does its subscription,
   * so reactivating puts the account back as it was.
   *
   * The reason is required and is shown to the owner verbatim. A deactivation the owner
   * cannot explain to themselves is a dispute before it is a support call.
   */
  async deactivateTenant(adminId: string, tenantId: string, reason: string) {
    const why = reason.trim();
    if (why.length < 10) {
      throw new BadRequestException('say why, in words the owner will be shown (10+ characters)');
    }

    const result = await this.db.runAsPlatform(`deactivate tenant ${tenantId}`, async (em) => {
      const tenant = await em.getRepository(Tenant).findOne({ where: { id: tenantId } });
      if (!tenant || tenant.deletedAt) throw new NotFoundException('no such pharmacy');
      if (tenant.status === 'deactivated') {
        // Deactivating twice would overwrite who did it and why — the record a dispute
        // turns on. Reactivate first if the reason needs to change.
        throw new BadRequestException('this pharmacy is already deactivated');
      }

      const previousStatus = tenant.status;
      tenant.status = 'deactivated';
      tenant.deactivatedAt = new Date();
      tenant.deactivatedReason = why;
      tenant.deactivatedBy = adminId;
      await em.getRepository(Tenant).save(tenant);

      await this.recordPlatformEvent(em, tenantId, adminId, 'audit.tenant_deactivated', {
        previousStatus,
        reason: why,
      });
      return {
        tenantId,
        status: tenant.status,
        deactivatedAt: tenant.deactivatedAt.toISOString(),
        deactivatedReason: why,
      };
    });

    this.tenantStatus.forget(tenantId);
    this.logger.warn(`tenant ${tenantId}: DEACTIVATED by platform admin ${adminId}`);
    return result;
  }

  /** Lifts a deactivation. The account comes back exactly as it was left. */
  async reactivateTenant(adminId: string, tenantId: string, note?: string) {
    const result = await this.db.runAsPlatform(`reactivate tenant ${tenantId}`, async (em) => {
      const tenant = await em.getRepository(Tenant).findOne({ where: { id: tenantId } });
      if (!tenant || tenant.deletedAt) throw new NotFoundException('no such pharmacy');
      if (tenant.status !== 'deactivated') {
        throw new BadRequestException('this pharmacy is not deactivated');
      }

      const previousReason = tenant.deactivatedReason;
      tenant.status = 'active';
      tenant.deactivatedAt = null;
      tenant.deactivatedReason = null;
      tenant.deactivatedBy = null;
      await em.getRepository(Tenant).save(tenant);

      await this.recordPlatformEvent(em, tenantId, adminId, 'audit.tenant_reactivated', {
        previousReason,
        note: note?.trim() || null,
      });
      return { tenantId, status: tenant.status };
    });

    this.tenantStatus.forget(tenantId);
    this.logger.warn(`tenant ${tenantId}: reactivated by platform admin ${adminId}`);
    return result;
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
    return this.db.runAsPlatform(`onboard tenant ${input.code}`, (em) =>
      this.createTenantIn(em, adminId, input),
    );
  }

  /**
   * The onboarding itself, inside a transaction the caller owns — so approving a sign-up
   * request and opening its account commit together or not at all (ADR-022).
   */
  async createTenantIn(
    em: EntityManager,
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
    {
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
    }
  }

  async listTenants() {
    const rows = await this.db.runAsPlatform('list tenants for the platform console', (em) =>
      em.query(
        `SELECT t.id, t.name, t.code, t.status, t.created_at AS "createdAt",
                t.deactivated_at AS "deactivatedAt",
                t.deactivated_reason AS "deactivatedReason",
                s.state AS "subscriptionState",
                s.current_period_end AS "currentPeriodEnd",
                s.suspended_reason AS "suspendedReason",
                s.price_santim AS "priceSantim",
                (SELECT count(*)::int FROM payment_proof p
                  WHERE p.tenant_id = t.id AND p.result = 'pending') AS "pendingProofs",
                (SELECT count(*)::int FROM branch b
                  WHERE b.tenant_id = t.id AND b.deleted_at IS NULL) AS "branchCount",
                (SELECT string_agg(b.name, ', ' ORDER BY b.name) FROM branch b
                  WHERE b.tenant_id = t.id AND b.deleted_at IS NULL) AS "branchNames",
                (SELECT u.display_name FROM app_user u
                  WHERE u.tenant_id = t.id AND u.role = 'owner' AND u.deleted_at IS NULL
                  ORDER BY u.created_at LIMIT 1) AS "ownerName",
                (SELECT r.phone FROM signup_request r
                  WHERE r.tenant_id_created = t.id LIMIT 1) AS "ownerPhone"
           FROM tenant t
           LEFT JOIN subscription s ON s.tenant_id = t.id
          WHERE t.deleted_at IS NULL
          ORDER BY t.name`,
      ),
    );

    return rows.map((r: Record<string, unknown>) => ({
      ...r,
      createdAt: new Date(r.createdAt as string).toISOString(),
      priceSantim: r.priceSantim === null ? null : Number(r.priceSantim),
      pendingProofs: Number(r.pendingProofs),
      currentPeriodEnd: r.currentPeriodEnd
        ? new Date(r.currentPeriodEnd as string).toISOString()
        : null,
      deactivatedAt: r.deactivatedAt ? new Date(r.deactivatedAt as string).toISOString() : null,
    }));
  }

  /**
   * One pharmacy, as the platform sees it (prototype screen 24).
   *
   * Branch names, staff counts and how recently each branch's data arrived — operational
   * health, not business data. Sales figures stay behind BR-2.2: "last sync" is when a
   * record landed, never what it said.
   */
  async tenantDetail(id: string) {
    const tenant = (await this.listTenants()).find((t: { id: unknown }) => t.id === id);
    if (!tenant) throw new NotFoundException('no such pharmacy');

    const branches = await this.db.runAsPlatform('branch health for the platform console', (em) =>
      em.query(
        `SELECT b.id, b.name, b.address,
                (SELECT count(DISTINCT ub.user_id)::int FROM user_branch ub
                   JOIN app_user u ON u.id = ub.user_id AND u.deleted_at IS NULL
                  WHERE ub.branch_id = b.id AND ub.deleted_at IS NULL) AS "staffCount",
                (SELECT max(s.created_at) FROM sale s WHERE s.branch_id = b.id) AS "lastSyncAt"
           FROM branch b
          WHERE b.tenant_id = $1 AND b.deleted_at IS NULL
          ORDER BY b.name`,
        [id],
      ),
    );
    const [lastPayment] = await this.db.runAsPlatform('last verified payment', (em) =>
      em.query(
        `SELECT verified_at AS "verifiedAt", amount_santim AS "amountSantim"
           FROM payment_proof WHERE tenant_id = $1 AND result = 'accepted'
          ORDER BY verified_at DESC LIMIT 1`,
        [id],
      ),
    );

    return {
      ...tenant,
      branches: branches.map((b: Record<string, unknown>) => ({
        ...b,
        lastSyncAt: b.lastSyncAt ? new Date(b.lastSyncAt as string).toISOString() : null,
      })),
      lastPaymentAt: lastPayment?.verifiedAt
        ? new Date(lastPayment.verifiedAt).toISOString()
        : null,
    };
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
