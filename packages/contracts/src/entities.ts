import { z } from 'zod';
import { isoDate, quantity, santim, utcTimestamp, uuidv7 } from './primitives.js';

/**
 * Payloads for the entities a terminal can write offline.
 *
 * Phase 0 (the walking skeleton, docs/04 §13) carries `sale` and `goods_receipt` only.
 * Controlled-substance `event` payloads arrive in Phase 2, behind the A-1 compliance gate —
 * do not add them here early (docs/06-delivery-plan.md §2).
 */

export const saleLinePayload = z.object({
  id: uuidv7,
  productId: uuidv7,
  /** FEFO-selected batch for a standard drug. Null only where no batch applies. */
  batchId: uuidv7.nullable(),
  qty: quantity.positive(),
  unitPriceSantim: santim.nonnegative(),
  lineTotalSantim: santim.nonnegative(),
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
