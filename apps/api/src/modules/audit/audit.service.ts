import { Injectable, Logger } from '@nestjs/common';
import type { EntityManager } from 'typeorm';
import { uuidv7 } from 'uuidv7';
import { firstRow } from '../../common/db/raw-query';
import type { TenantScope } from '../../common/db/tenant-scope';
import { DomainEvent } from '../../entities';

/**
 * The audit event types this system records.
 *
 * A closed union, not free text. An audit log whose vocabulary anyone can extend in passing
 * becomes unqueryable within a year — you cannot ask "show me every price change" if three
 * spellings of that exist. Adding a type is a deliberate edit here.
 *
 * **No `controlled.*` types.** Those are the regulated subset and wait for A-1 (ADR-015).
 */
export const AUDIT_EVENT_TYPES = [
  'audit.price_changed',
  'audit.product_created',
  'audit.user_created',
  'audit.user_deactivated',
  'audit.branch_created',
  'audit.branch_updated',
  'audit.stock_adjusted',
  // E-4.2 / ADR-020. Written whenever a sale names a batch that had already expired, whether
  // or not anybody authorised it — the unauthorised case is the one most worth having, because
  // it leaves expired stock on the books at full quantity while the medicine is in a bag.
  'audit.expired_dispense',
  // Billing (FR-1). Recorded in the TENANT's own trail even when the actor is a platform
  // admin: an action by us that the affected pharmacy cannot see is exactly what BR-2.2
  // exists to prevent, and a suspension nobody can find a record of is a support call.
  'audit.payment_proof_submitted',
  'audit.payment_accepted',
  'audit.payment_rejected',
  'audit.subscription_changed',
  'audit.tenant_onboarded',
] as const;

export type AuditEventType = (typeof AUDIT_EVENT_TYPES)[number];

export interface AuditEntry {
  id: string;
  seq: number;
  eventType: AuditEventType | string;
  streamId: string;
  actorId: string;
  branchId: string | null;
  payload: Record<string, unknown>;
  occurredAt: string;
  recordedAt: string;
}

/**
 * The general action audit log — who did what, when (Vision §2.1.1).
 *
 * Not a compliance feature. Vision calls owner trust in staff "the product", and a price
 * changed at 11pm by somebody who should not have is a finding an owner wants whether or not
 * a controlled substance was involved. It runs on the same append-only infrastructure the
 * controlled-substance ledger will use (ADR-004), which is the point: by the time the
 * regulated subset arrives, the store underneath it has been carrying real traffic.
 *
 * **Writing an audit event is part of the transaction that caused it.** If the price change
 * commits, so does the record of it; if the record fails, the change rolls back. An audit log
 * written afterwards, on a best-effort basis, is missing exactly the entries somebody had a
 * reason to want missing.
 */
@Injectable()
export class AuditService {
  private readonly logger = new Logger(AuditService.name);

  /**
   * Appends an event to a stream.
   *
   * `seq` is allocated by reading the stream's current maximum inside the caller's
   * transaction. The UNIQUE(tenant, stream, stream_id, seq) constraint makes a lost update
   * impossible: two concurrent appends to one stream cannot both win, and the loser fails
   * loudly rather than silently overwriting a position.
   */
  async record(
    em: EntityManager,
    scope: TenantScope,
    event: {
      type: AuditEventType;
      streamId: string;
      payload: Record<string, unknown>;
      branchId?: string | null;
      occurredAt?: Date;
      terminalId?: string | null;
      opId?: string | null;
    },
  ): Promise<void> {
    const next = firstRow<{ seq: string }>(
      await em.query(
        `SELECT coalesce(max(seq), 0) + 1 AS seq
           FROM event
          WHERE tenant_id = $1 AND stream = 'audit' AND stream_id = $2`,
        [scope.tenantId, event.streamId],
      ),
    );

    // save() rather than insert(): TypeORM's insert() narrows a jsonb column to a
    // deep-partial type, which a free-form payload cannot satisfy. save() on a new entity
    // is still a single INSERT — and the table forbids UPDATE at the database, so there is
    // no upsert hiding behind it.
    const row = em.getRepository(DomainEvent).create({
      id: uuidv7(),
      tenantId: scope.tenantId,
      branchId: event.branchId ?? null,
      stream: 'audit',
      streamId: event.streamId,
      seq: Number(next?.seq ?? 1),
      eventType: event.type,
      payload: event.payload,
      actorId: scope.userId,
      terminalId: event.terminalId ?? null,
      occurredAt: event.occurredAt ?? new Date(),
      recordedAt: new Date(),
      opId: event.opId ?? null,
    });
    await em.getRepository(DomainEvent).save(row);
  }

  /**
   * The audit trail, most recent first.
   *
   * Reading is unrestricted within the tenant by design: an audit log that can be filtered
   * into silence by the person being audited is not one. Who may *open* it is the FR-2
   * matrix's business, and that check lives at the controller.
   */
  async list(
    em: EntityManager,
    options: { streamId?: string; actorId?: string; eventType?: string; limit: number },
  ): Promise<AuditEntry[]> {
    const query = em
      .getRepository(DomainEvent)
      .createQueryBuilder('e')
      .where("e.stream = 'audit'")
      .orderBy('e.occurred_at', 'DESC')
      .addOrderBy('e.seq', 'DESC')
      .limit(options.limit);

    if (options.streamId) query.andWhere('e.stream_id = :streamId', { streamId: options.streamId });
    if (options.actorId) query.andWhere('e.actor_id = :actorId', { actorId: options.actorId });
    if (options.eventType) {
      query.andWhere('e.event_type = :eventType', { eventType: options.eventType });
    }

    const rows = await query.getMany();
    return rows.map((e) => ({
      id: e.id,
      seq: e.seq,
      eventType: e.eventType,
      streamId: e.streamId,
      actorId: e.actorId,
      branchId: e.branchId,
      payload: e.payload,
      occurredAt: e.occurredAt.toISOString(),
      recordedAt: e.recordedAt.toISOString(),
    }));
  }

  /**
   * Verifies a stream has no gaps.
   *
   * A gap is indistinguishable from a deletion, and "the log has not been tampered with" is
   * the only claim an audit log really makes. The database forbids DELETE outright, so a gap
   * would mean something stranger — a failed insert that consumed a position, or a restore
   * from a partial backup — and either is worth knowing about before an auditor finds it.
   */
  async verifyContinuity(
    em: EntityManager,
    streamId: string,
  ): Promise<{ intact: boolean; expected: number; found: number; missing: number[] }> {
    const rows = await em.query(
      `SELECT seq FROM event
        WHERE stream = 'audit' AND stream_id = $1
        ORDER BY seq`,
      [streamId],
    );
    const seqs = rows.map((r: { seq: string }) => Number(r.seq));
    const expected = seqs.length === 0 ? 0 : Math.max(...seqs);
    const present = new Set(seqs);
    const missing: number[] = [];
    for (let i = 1; i <= expected; i++) if (!present.has(i)) missing.push(i);

    if (missing.length > 0) {
      this.logger.error(`audit stream ${streamId} has gaps at ${missing.join(', ')}`);
    }
    return { intact: missing.length === 0, expected, found: seqs.length, missing };
  }
}
