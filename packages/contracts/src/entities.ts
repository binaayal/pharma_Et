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
