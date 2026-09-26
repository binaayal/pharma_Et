import { z } from 'zod';
import { isoDate, quantity, santim, utcTimestamp, uuidv7 } from './primitives.js';

/**
 * Payloads for the entities a terminal can write offline.
 *
 * The controlled-substance payloads at the end of this file (contract 1.4.0) were built ahead
 * of A-1 by owner decision (ADR-024) and are refused by the server until its
 * `CONTROLLED_DISPENSING` switch is on — which waits for A-1 to be verified.
 */

export const saleLinePayload = z.object({
  id: uuidv7,
  productId: uuidv7,
  /** FEFO-selected batch for a standard drug. Null only where no batch applies. */
  batchId: uuidv7.nullable(),
  qty: quantity.positive(),
  unitPriceSantim: santim.nonnegative(),
  lineTotalSantim: santim.nonnegative(),
  /**
   * Who authorised dispensing from an already-expired batch (E-4.2, ADR-020).
   *
   * Null in the ordinary case, and null too when nobody authorised it — a cashier may
   * complete the sale without the `expiry.override` capability, they simply cannot attribute
   * it to the expired batch. Either way the server audits the dispense, because it knows the
   * batch's expiry date without being told.
   *
   * Added in contract 1.3.0. A 1.2.0 terminal never sets it and its sales apply unchanged.
   */
  expiryOverrideBy: uuidv7.nullable().optional(),
});
export type SaleLinePayload = z.infer<typeof saleLinePayload>;

export const paymentPayload = z.object({
  id: uuidv7,
  /** V1 has no payment-gateway integration; other tenders are recorded, not settled. */
  method: z.enum(['cash', 'other_recorded']),
  amountSantim: santim.nonnegative(),
});
export type PaymentPayload = z.infer<typeof paymentPayload>;

export const salePayload = z
  .object({
    shiftId: uuidv7.nullable(),
    cashierId: uuidv7,
    soldAt: utcTimestamp,
    totalSantim: santim.nonnegative(),
    lines: z.array(saleLinePayload).min(1),
    payments: z.array(paymentPayload),
  })
  .refine((s) => s.lines.reduce((sum, l) => sum + l.lineTotalSantim, 0) === s.totalSantim, {
    message: 'sale total must equal the sum of its line totals (G4)',
    path: ['totalSantim'],
  })
  .refine((s) => s.lines.every((l) => l.qty * l.unitPriceSantim === l.lineTotalSantim), {
    message: 'each line total must equal qty * unit price (G4)',
    path: ['lines'],
  });
export type SalePayload = z.infer<typeof salePayload>;

export const goodsReceiptLinePayload = z.object({
  id: uuidv7,
  productId: uuidv7,
  lotNo: z.string().min(1).max(64),
  expiryDate: isoDate,
  qty: quantity.positive(),
  costSantim: santim.nonnegative(),
});
export type GoodsReceiptLinePayload = z.infer<typeof goodsReceiptLinePayload>;

export const goodsReceiptPayload = z.object({
  /** Free-form supplier in V1 (FR-7 base); a supplier entity is deferred. */
  supplierName: z.string().min(1).max(200),
  receivedAt: utcTimestamp,
  lines: z.array(goodsReceiptLinePayload).min(1),
});
export type GoodsReceiptPayload = z.infer<typeof goodsReceiptPayload>;

/* -------------------------------------------------------------------------- */
/* Shift & cash-up (FR-8) — contract v1.1.0, ADR-012 §4                        */
/* -------------------------------------------------------------------------- */

/**
 * A staff member's till session.
 *
 * Opened and closed on the terminal, offline. The opening float is what was in the drawer
 * before trading started, and it is part of the expected figure — a cash-up that ignored it
 * would report a variance equal to the float on every single shift, which is how a control
 * gets switched off for being noisy.
 */
export const shiftPayload = z.object({
  userId: uuidv7,
  openedAt: utcTimestamp,
  /** Null while the shift is open. A shift is closed exactly once. */
  closedAt: utcTimestamp.nullable(),
  openingFloatSantim: santim.nonnegative(),
});
export type ShiftPayload = z.infer<typeof shiftPayload>;

/**
 * The Z-report: counted cash against what the system expected (BR-8.2, AC-8.1).
 *
 * This is a record of something a person did at a moment in time. `expectedSantim` is what
 * the terminal computed and **showed the cashier** — it is deliberately not recomputed or
 * corrected later, because rewriting the number somebody was asked to reconcile against
 * would destroy the only evidence of what they actually agreed to (ADR-012 §3). The server
 * recomputes its own figure separately, for audit.
 */
export const cashUpPayload = z
  .object({
    shiftId: uuidv7,
    userId: uuidv7,
    countedAt: utcTimestamp,
    /** Opening float + cash taken, as the terminal knew it at count time. */
    expectedSantim: santim,
    /** What was physically in the drawer. */
    countedSantim: santim.nonnegative(),
    /**
     * `counted − expected`. Negative means cash is missing, which is the number the whole
     * feature exists to surface, so it is stored explicitly rather than derived on read —
     * a derived figure can silently change when the inputs are reinterpreted.
     */
    varianceSantim: santim,
    /** The cashier's explanation, if they offered one. Free text, never parsed. */
    note: z.string().max(500).nullable(),
  })
  .refine((c) => c.countedSantim - c.expectedSantim === c.varianceSantim, {
    message: 'variance must equal counted minus expected (G4)',
    path: ['varianceSantim'],
  });
export type CashUpPayload = z.infer<typeof cashUpPayload>;

/* -------------------------------------------------------------------------- */
/* Stock adjustment (FR-3, docs/04 §5.3) — contract v1.2.0                     */
/* -------------------------------------------------------------------------- */

/**
 * Why a count was corrected.
 *
 * A closed list, not free text. BR-3.2 promises that an oversell is "flagged for physical
 * reconciliation", and a reconciliation report is only useful if the reasons can be counted:
 * "shrinkage happened 40 times this quarter" is a finding, "somebody typed something 40
 * different ways" is not.
 *
 * `recount` is the honest default for "the shelf and the system disagreed and the shelf
 * won" — which is what most corrections actually are, and pretending otherwise by forcing a
 * cause produces invented causes.
 */
export const adjustmentReason = z.enum([
  'recount',
  'damage',
  'expiry_writeoff',
  'theft_or_loss',
  'receipt_correction',
  'other',
]);
export type AdjustmentReason = z.infer<typeof adjustmentReason>;

export const stockAdjustmentPayload = z
  .object({
    batchId: uuidv7,
    productId: uuidv7,
    /**
     * Signed change to the count: negative writes stock off, positive adds it back.
     *
     * The delta is recorded, never the resulting total. A terminal that has been offline
     * holds a count the server may already disagree with, so sending "set it to 40" would
     * silently discard whatever happened in between. A delta composes; an absolute does not.
     */
    delta: quantity,
    reason: adjustmentReason,
    /** Required for anything but a recount — see the refinement below. */
    note: z.string().max(500).nullable(),
    countedAt: utcTimestamp,
    /** What the terminal believed the count was, for reconstructing the decision later. */
    previousQtyOnHand: quantity,
  })
  .refine((a) => a.delta !== 0, {
    message: 'an adjustment of zero records nothing; omit it instead',
    path: ['delta'],
  })
  .refine((a) => a.reason === 'recount' || (a.note !== null && a.note.trim().length > 0), {
    // Loss, damage and theft are the entries an owner will actually read. An unexplained
    // write-off is indistinguishable from a covered-up one, so the note is required
    // wherever the reason implies somebody knows more than the number shows.
    message: 'this reason requires a note explaining it',
    path: ['note'],
  });
export type StockAdjustmentPayload = z.infer<typeof stockAdjustmentPayload>;

/** The dedicated psychotropic prescription paper (FR-4 §4a). */
export const prescriptionPayload = z.object({
  /** The number printed on the dedicated prescription paper. */
  number: z.string().trim().min(1).max(64),
  prescriber: z.string().trim().min(1).max(120),
  /** Calendar date the prescription was written — validity counts from here (AC-4.3). */
  issuedOn: isoDate,
});
export type PrescriptionPayload = z.infer<typeof prescriptionPayload>;

/**
 * A controlled-substance dispense (FR-4 §4a–4b, FR-6; contract 1.4.0, ADR-024).
 *
 * One product per operation, so "one psychotropic per prescription" is structural on the
 * wire as well as checked. It is also a sale — the customer pays, and the cash belongs to
 * the till's cash-up — so it carries its own line total and payments, and the server
 * writes the sale and the ledger event in one transaction.
 */
export const controlledDispensePayload = z
  .object({
    shiftId: uuidv7.nullable(),
    cashierId: uuidv7,
    dispensedAt: utcTimestamp,
    productId: uuidv7,
    /** The sale line's id, so the sale and its ledger event reference each other. */
    lineId: uuidv7,
    qty: quantity.positive(),
    unitPriceSantim: santim.nonnegative(),
    lineTotalSantim: santim.nonnegative(),
    prescription: prescriptionPayload,
    payments: z.array(paymentPayload).min(1),
  })
  .refine((d) => d.qty * d.unitPriceSantim === d.lineTotalSantim, {
    message: 'line total must equal qty * unit price (G4)',
    path: ['lineTotalSantim'],
  })
  .refine((d) => d.payments.reduce((sum, p) => sum + p.amountSantim, 0) === d.lineTotalSantim, {
    message: 'payments must add up to the line total (G4)',
    path: ['payments'],
  });
export type ControlledDispensePayload = z.infer<typeof controlledDispensePayload>;

/**
 * A compensating correction to controlled stock (FR-6 main flow 4, AC-6.1). Never an edit:
 * the original event stays, and this one explains the difference.
 */
export const controlledAdjustmentPayload = z
  .object({
    productId: uuidv7,
    delta: quantity,
    reason: adjustmentReason,
    note: z.string().trim().min(1).max(500),
    /** The ledger event this corrects, when it corrects one. */
    correctsEventId: uuidv7.nullable(),
    countedAt: utcTimestamp,
  })
  .refine((a) => a.delta !== 0, {
    message: 'an adjustment of zero records nothing; omit it instead',
    path: ['delta'],
  });
export type ControlledAdjustmentPayload = z.infer<typeof controlledAdjustmentPayload>;
