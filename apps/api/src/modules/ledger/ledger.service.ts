import { Injectable } from '@nestjs/common';
import {
  normalisePrescriptionNumber,
  prescriptionValidOn,
  PSYCHOTROPIC_RULES,
  type Operation,
} from '@pharmaet/contracts';
import type { EntityManager } from 'typeorm';
import { uuidv7 } from 'uuidv7';
import { firstRow } from '../../common/db/raw-query';
import { ScopedDbService } from '../../common/db/scoped-db.service';
import type { TenantScope } from '../../common/db/tenant-scope';
import { DomainEvent, Payment, Product, Sale, SaleLine } from '../../entities';
import { ComplianceSwitch } from './compliance-switch';

export type ControlledEventType =
  | 'controlled.received'
  | 'controlled.dispensed'
  | 'controlled.adjusted';

export interface LedgerEntry {
  id: string;
  seq: number;
  eventType: ControlledEventType;
  branchId: string;
  branchName: string;
  productId: string;
  productName: string;
  delta: number;
  actorId: string;
  actorName: string | null;
  occurredAt: string;
  recordedAt: string;
  payload: Record<string, unknown>;
}

/** Ethiopia keeps one offset all year, so a prescription's calendar day is UTC+3's day. */
const ADDIS_OFFSET_MS = 3 * 3600 * 1000;
const localDate = (instant: Date) =>
  new Date(instant.getTime() + ADDIS_OFFSET_MS).toISOString().slice(0, 10);

/**
 * The controlled-substance ledger (FR-6, ADR-004; built ahead of A-1 by ADR-024).
 *
 * Every controlled action is an append-only event on the `controlled_stock` stream — one
 * stream per product, ordered by `seq` — and current stock is a projection over those
 * events, updated in the same transaction and rebuildable from them. Nothing here updates or
 * deletes an event; the database would refuse it anyway (G3).
 */
@Injectable()
export class LedgerService {
  constructor(
    private readonly db: ScopedDbService,
    readonly switchboard: ComplianceSwitch,
  ) {}

  /** Appends one event and folds it into the projection, inside the caller's transaction. */
  async append(
    em: EntityManager,
    scope: TenantScope,
    event: {
      type: ControlledEventType;
      branchId: string;
      productId: string;
      delta: number;
      payload: Record<string, unknown>;
      occurredAt: Date;
      terminalId?: string | null;
      opId?: string | null;
    },
  ): Promise<{ id: string; seq: number }> {
    const next = firstRow<{ seq: string }>(
      await em.query(
        `SELECT coalesce(max(seq), 0) + 1 AS seq FROM event
          WHERE tenant_id = $1 AND stream = 'controlled_stock' AND stream_id = $2`,
        [scope.tenantId, event.productId],
      ),
    );
    const seq = Number(next?.seq ?? 1);
    const id = uuidv7();
    const row = em.getRepository(DomainEvent).create({
      id,
      tenantId: scope.tenantId,
      branchId: event.branchId,
      stream: 'controlled_stock',
      streamId: event.productId,
      seq,
      eventType: event.type,
      payload: { ...event.payload, productId: event.productId, delta: event.delta },
      actorId: scope.userId,
      terminalId: event.terminalId ?? null,
      occurredAt: event.occurredAt,
      recordedAt: new Date(),
      opId: event.opId ?? null,
    });
    await em.getRepository(DomainEvent).save(row);

    await em.query(
      `INSERT INTO controlled_stock_view (id, tenant_id, branch_id, product_id, qty_on_hand, as_of_seq)
       VALUES ($1, $2, $3, $4, $5, $6)
       ON CONFLICT (tenant_id, branch_id, product_id) DO UPDATE
         SET qty_on_hand = controlled_stock_view.qty_on_hand + EXCLUDED.qty_on_hand,
             as_of_seq   = greatest(controlled_stock_view.as_of_seq, EXCLUDED.as_of_seq),
             updated_at  = now(),
             row_version = controlled_stock_view.row_version + 1`,
      [uuidv7(), scope.tenantId, event.branchId, event.productId, event.delta, seq],
    );
    return { id, seq };
  }

  /** The product, which must exist and be controlled, or the operation is refused. */
  private async controlledProduct(em: EntityManager, productId: string): Promise<Product> {
    const product = await em.getRepository(Product).findOne({ where: { id: productId } });
    if (!product) throw new Error('unknown product');
    if (!product.isControlled) {
      throw new Error('this product is not controlled; sell it through the standard path');
    }
    return product;
  }

  /**
   * A controlled dispense (FR-4 §4a–4b). The rules are checked here as well as at the till:
   * the till checks so they hold offline, the server so a terminal cannot opt out of them.
   * BR-4.2 — a violation is refused, never warned.
   */
  async dispense(
    em: EntityManager,
    scope: TenantScope,
    operation: Extract<Operation, { entityType: 'controlled_dispense' }>,
  ): Promise<void> {
    this.switchboard.assertOn();
    const { payload } = operation;
    const branchId = operation.branchId;
    if (!branchId) throw new Error('a dispense must name its branch');
    await this.controlledProduct(em, payload.productId);

    const dispensedAt = new Date(payload.dispensedAt);
    const rx = payload.prescription;
    const key = normalisePrescriptionNumber(rx.number);
    if (PSYCHOTROPIC_RULES.dedicatedPrescriptionRequired && key.length === 0) {
      throw new Error('a psychotropic dispense needs the dedicated prescription number');
    }

    // AC-4.3 — an expired prescription is rejected.
    const { valid, daysUsed } = prescriptionValidOn(rx.issuedOn, localDate(dispensedAt));
    if (!valid) {
      throw new Error(
        daysUsed < 0
          ? 'the prescription is dated after the dispense'
          : `the prescription expired: ${daysUsed} days old, valid for ${PSYCHOTROPIC_RULES.psychotropicValidityDays}`,
      );
    }

    // AC-4.2 — one psychotropic substance per prescription, across every branch and terminal
    // of the pharmacy. The same substance again (a split dispense) is the same substance.
    const others = await em.query(
      `SELECT DISTINCT payload->>'productId' AS product
         FROM event
        WHERE tenant_id = $1 AND stream = 'controlled_stock'
          AND event_type = 'controlled.dispensed'
          AND payload->>'prescriptionKey' = $2
          AND payload->>'productId' <> $3`,
      [scope.tenantId, key, payload.productId],
    );
    if (others.length >= PSYCHOTROPIC_RULES.maxPsychotropicSubstancesPerPrescription) {
      throw new Error(
        'this prescription has already been used for another psychotropic substance — only one is allowed per prescription',
      );
    }

    // It is a sale too: the money belongs to the till's cash-up (BR-8.2).
    await em.getRepository(Sale).insert({
      id: operation.entityId,
      tenantId: scope.tenantId,
      branchId,
      shiftId: payload.shiftId,
      cashierId: payload.cashierId,
      terminalId: operation.terminalId,
      totalSantim: payload.lineTotalSantim,
      soldAt: dispensedAt,
      changeSeq: 0,
      deletedAt: null,
    });
    await em.getRepository(SaleLine).insert({
      id: payload.lineId,
      tenantId: scope.tenantId,
      saleId: operation.entityId,
      productId: payload.productId,
      batchId: null,
      qty: payload.qty,
      unitPriceSantim: payload.unitPriceSantim,
      lineTotalSantim: payload.lineTotalSantim,
      changeSeq: 0,
      deletedAt: null,
    });
    for (const p of payload.payments) {
      await em.getRepository(Payment).insert({
        id: p.id,
        tenantId: scope.tenantId,
        saleId: operation.entityId,
        method: p.method,
        amountSantim: p.amountSantim,
        changeSeq: 0,
        deletedAt: null,
      });
    }

    await this.append(em, scope, {
      type: 'controlled.dispensed',
      branchId,
      productId: payload.productId,
      delta: -payload.qty,
      occurredAt: dispensedAt,
      terminalId: operation.terminalId,
      opId: operation.opId,
      payload: {
        saleId: operation.entityId,
        qty: payload.qty,
        prescriptionNumber: rx.number,
        prescriptionKey: key,
        prescriber: rx.prescriber,
        issuedOn: rx.issuedOn,
        validityDaysUsed: daysUsed,
        validityDays: PSYCHOTROPIC_RULES.psychotropicValidityDays,
        rules: PSYCHOTROPIC_RULES.status,
        dispensedBy: payload.cashierId,
      },
    });
  }

  /** A compensating correction (FR-6 main flow 4). The original event is never touched. */
  async adjust(
    em: EntityManager,
    scope: TenantScope,
    operation: Extract<Operation, { entityType: 'controlled_adjustment' }>,
  ): Promise<void> {
    this.switchboard.assertOn();
    const { payload } = operation;
    const branchId = operation.branchId;
    if (!branchId) throw new Error('an adjustment must name its branch');
    await this.controlledProduct(em, payload.productId);

    if (payload.correctsEventId) {
      const [target] = await em.query(
        `SELECT 1 FROM event WHERE id = $1 AND tenant_id = $2 AND stream = 'controlled_stock'`,
        [payload.correctsEventId, scope.tenantId],
      );
      if (!target) throw new Error('the event being corrected is not in this ledger');
    }

    await this.append(em, scope, {
      type: 'controlled.adjusted',
      branchId,
      productId: payload.productId,
      delta: payload.delta,
      occurredAt: new Date(payload.countedAt),
      terminalId: operation.terminalId,
      opId: operation.opId,
      payload: {
        reason: payload.reason,
        note: payload.note,
        correctsEventId: payload.correctsEventId,
        rules: PSYCHOTROPIC_RULES.status,
      },
    });
  }

  /** A controlled line in a goods receipt becomes an event, not a batch (docs/04 §5.4). */
  async receive(
    em: EntityManager,
    scope: TenantScope,
    line: {
      branchId: string;
      productId: string;
      qty: number;
      lotNo: string;
      expiryDate: string;
      goodsReceiptId: string;
      supplierName: string;
      receivedAt: Date;
      terminalId: string;
      opId: string;
    },
  ): Promise<void> {
    this.switchboard.assertOn();
    await this.append(em, scope, {
      type: 'controlled.received',
      branchId: line.branchId,
      productId: line.productId,
      delta: line.qty,
      occurredAt: line.receivedAt,
      terminalId: line.terminalId,
      opId: line.opId,
      payload: {
        qty: line.qty,
        lotNo: line.lotNo,
        expiryDate: line.expiryDate,
        goodsReceiptId: line.goodsReceiptId,
        supplierName: line.supplierName,
      },
    });
  }

  // ------------------------------------------------------------------------- reads

  /** AC-6.2 — the complete, ordered history for a date range. */
  async entries(
    scope: TenantScope,
    options: { from: Date; to: Date; branchIds: string[] | null; productId?: string },
  ): Promise<LedgerEntry[]> {
    return this.db.runInScope(scope, async (em) => {
      const params: unknown[] = [options.from, options.to];
      let filter = '';
      if (options.branchIds !== null) {
        params.push(options.branchIds);
        filter += ` AND e.branch_id = ANY($${params.length}::uuid[])`;
      }
      if (options.productId) {
        params.push(options.productId);
        filter += ` AND e.stream_id = $${params.length}`;
      }
      const rows = await em.query(
        `SELECT e.id, e.seq, e.event_type AS "eventType", e.branch_id AS "branchId",
                b.name AS "branchName", e.stream_id AS "productId", p.name AS "productName",
                (e.payload->>'delta')::bigint AS delta, e.actor_id AS "actorId",
                u.display_name AS "actorName", e.occurred_at AS "occurredAt",
                e.recorded_at AS "recordedAt", e.payload
           FROM event e
           JOIN product p ON p.id = e.stream_id
           JOIN branch b ON b.id = e.branch_id
           LEFT JOIN app_user u ON u.id = e.actor_id
          WHERE e.stream = 'controlled_stock'
            AND e.occurred_at >= $1 AND e.occurred_at < $2 ${filter}
          ORDER BY e.occurred_at, e.stream_id, e.seq`,
        params,
      );
      return rows.map((r: Record<string, unknown>) => ({
        ...r,
        seq: Number(r.seq),
        delta: Number(r.delta),
        occurredAt: new Date(r.occurredAt as string).toISOString(),
        recordedAt: new Date(r.recordedAt as string).toISOString(),
      })) as LedgerEntry[];
    });
  }

  /** Current controlled stock — the projection (BR-3.3). */
  async stock(scope: TenantScope, branchIds: string[] | null) {
    return this.db.runInScope(scope, async (em) => {
      const params: unknown[] = [];
      let filter = '';
      if (branchIds !== null) {
        params.push(branchIds);
        filter = `AND v.branch_id = ANY($1::uuid[])`;
      }
      const rows = await em.query(
        `SELECT v.branch_id AS "branchId", b.name AS "branchName", v.product_id AS "productId",
                p.name AS "productName", v.qty_on_hand AS "qtyOnHand", v.as_of_seq AS "asOfSeq"
           FROM controlled_stock_view v
           JOIN product p ON p.id = v.product_id
           JOIN branch b ON b.id = v.branch_id
          WHERE v.deleted_at IS NULL ${filter}
          ORDER BY p.name, b.name`,
        params,
      );
      return rows.map((r: Record<string, unknown>) => ({
        ...r,
        qtyOnHand: Number(r.qtyOnHand),
        asOfSeq: Number(r.asOfSeq),
      }));
    });
  }

  /** BR-6.3 — the ledger in a form a person can read and an inspector can file. */
  async exportCsv(
    scope: TenantScope,
    options: { from: Date; to: Date; branchIds: string[] | null },
  ): Promise<string> {
    const rows = await this.entries(scope, options);
    const cell = (v: unknown) => `"${String(v ?? '').replace(/"/g, '""')}"`;
    const header = [
      'occurred_at_utc', 'branch', 'product', 'event', 'quantity_change', 'prescription',
      'prescriber', 'prescription_issued', 'by', 'reason_or_supplier', 'event_id', 'seq',
    ];
    const lines = rows.map((r) =>
      [
        r.occurredAt,
        r.branchName,
        r.productName,
        r.eventType.replace('controlled.', ''),
        r.delta,
        r.payload.prescriptionNumber,
        r.payload.prescriber,
        r.payload.issuedOn,
        r.actorName ?? r.actorId,
        r.payload.reason ?? r.payload.supplierName,
        r.id,
        r.seq,
      ]
        .map(cell)
        .join(','),
    );
    return [
      `# PharmaEt controlled-substance ledger. Rules status: ${PSYCHOTROPIC_RULES.status} (A-1 unverified until recorded in compliance-sign-off.md).`,
      header.join(','),
      ...lines,
    ].join('\n');
  }

  /**
   * Recomputes the projection from the events alone and compares — the check that the
   * events, not the table, are the truth (docs/04 §8 "projection integrity").
   */
  async verifyProjection(em: EntityManager, tenantId: string) {
    return em.query(
      `WITH truth AS (
         SELECT branch_id, stream_id AS product_id, sum((payload->>'delta')::bigint) AS qty
           FROM event WHERE tenant_id = $1 AND stream = 'controlled_stock'
          GROUP BY branch_id, stream_id)
       SELECT t.branch_id, t.product_id, t.qty AS events, v.qty_on_hand AS projection
         FROM truth t
         FULL JOIN controlled_stock_view v
           ON v.tenant_id = $1 AND v.branch_id = t.branch_id AND v.product_id = t.product_id
        WHERE coalesce(t.qty, 0) <> coalesce(v.qty_on_hand, 0)`,
      [tenantId],
    );
  }
}
