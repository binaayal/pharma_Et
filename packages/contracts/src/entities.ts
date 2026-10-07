import { z } from 'zod';
import { isoDate, quantity, santim, utcTimestamp, uuidv7 } from './primitives.js';

/**
 * Payloads for the entities a terminal can write offline.
 *
 * The controlled-substance payloads at the end of this file (contract 1.4.0) were built ahead
 * of A-1 by owner decision (ADR-024) and are refused by the server until its
 * `CONTROLLED_DISPENSING` switch is on — which waits for A-1 to be verified.
 */

/* -------------------------------------------------------------------------- */
/* Sell units (FR-11, ADR-030) — contract v1.5.0                               */
/* -------------------------------------------------------------------------- */

/** The most base units one pack may hold. A bound, so a typo cannot move a year of stock. */
export const MAX_PACK_SIZE = 100_000;

/** How many packs one product may define. Strip, box, carton — nobody needs a fifth. */
export const MAX_PACKS_PER_PRODUCT = 4;

/**
 * Base units in one unit of a line's `qty`, when the line was rung up in a pack.
 *
 * Absent or null means the line is in the product's base unit, which is every line a
 * pre-1.5.0 terminal has ever sent. Starts at 2: a "pack" of one is the base unit.
 */
export const packSize = z
  .number()
  .int()
  .min(2)
  .max(MAX_PACK_SIZE)
  .describe('Base units in one unit of qty; absent means the base unit');

/**
 * A unit a product can be received and sold in, beside its base unit (FR-11).
 *
 * A pack carries **its own price** rather than deriving one, because a box is routinely
 * cheaper than its tablets added up, and a box price is not in general a whole number of
 * santim per tablet — 100.00 for 30 has no exact tablet price at all.
 */
export const productPack = z.object({
  /** What the counter calls it: "strip", "box". Shown on the cart line and the receipt. */
  name: z.string().trim().min(1).max(40),
  size: packSize,
  priceSantim: santim.nonnegative(),
  /**
   * What one of these sells for to a wholesale customer — a clinic, an organisation
   * (FR-19, ADR-037). Absent or null means the pack has no wholesale price, and a
   * wholesale sale charges the ordinary one. Stated, never derived, like every price here.
   *
   * Added in contract 1.8.0.
   */
  wholesalePriceSantim: santim.nonnegative().nullable().optional(),
});
export type ProductPack = z.infer<typeof productPack>;

/* -------------------------------------------------------------------------- */
/* Price tiers (FR-19, ADR-037) — contract v1.8.0                              */
/* -------------------------------------------------------------------------- */

/**
 * Which price list a sale was rung up on.
 *
 * `retail` is the walk-in customer and every sale before this existed. `wholesale` is the
 * clinic or organisation that buys at the other price. The tier is a fact about the sale,
 * recorded so that a report can say how much went out at wholesale — the prices themselves
 * are on the lines, as they always were, and are not recomputed from the tier.
 */
export const priceTier = z.enum(['retail', 'wholesale']);
export type PriceTier = z.infer<typeof priceTier>;

/** A product's packs: at most a handful, no two alike in name or in size. */
export const productPacks = z
  .array(productPack)
  .max(MAX_PACKS_PER_PRODUCT)
  .refine((packs) => new Set(packs.map((p) => p.name.toLowerCase())).size === packs.length, {
    message: 'two packs cannot share a name',
  })
  .refine((packs) => new Set(packs.map((p) => p.size)).size === packs.length, {
    message: 'two packs cannot hold the same number of units',
  });

/**
 * What a line does to stock, in base units.
 *
 * The one place the multiplication lives on the server and in the dashboard. Stock is always
 * counted in the base unit (docs/04 §3); a line's `qty` is in the unit it was rung up in.
 */
export function baseQuantity(line: { qty: number; packSize?: number | null }): number {
  return line.qty * (line.packSize ?? 1);
}

/* -------------------------------------------------------------------------- */
/* Barcodes (FR-13, ADR-031) — contract v1.6.0                                 */
/* -------------------------------------------------------------------------- */

/** How many barcodes one product may carry: the same medicine from several makers. */
export const MAX_BARCODES_PER_PRODUCT = 12;

/**
 * A barcode in the one form it is stored and compared in.
 *
 * The same trade item is printed as 8, 12 or 13 digits on a retail box (EAN-8, UPC-A,
 * EAN-13) and as 14 inside a GS1 DataMatrix. GS1 defines them as one number: the shorter
 * forms are the GTIN-14 with leading zeros dropped. So an all-digit code of those lengths is
 * left-padded to 14, and a box linked by scanning its EAN-13 is found again when its
 * DataMatrix is scanned at the next delivery.
 *
 * Anything else — a wholesaler's own Code 128 label — is kept exactly as read, trimmed.
 *
 * Implemented a second time in Dart (`apps/mobile/lib/core/gs1.dart`), because the till
 * matches a scan with no network. `BARCODE_VECTORS` below is run against both.
 */
export function canonicalBarcode(raw: string): string {
  const code = raw.trim();
  return /^(\d{8}|\d{12}|\d{13})$/.test(code) ? code.padStart(14, '0') : code;
}

/** Inputs and the canonical form each must produce, for both implementations. */
export const BARCODE_VECTORS: ReadonlyArray<readonly [input: string, canonical: string]> = [
  ['6291100080014', '06291100080014'], // EAN-13
  ['06291100080014', '06291100080014'], // already GTIN-14
  ['036000291452', '00036000291452'], // UPC-A
  ['96385074', '00000096385074'], // EAN-8
  [' 6291100080014 ', '06291100080014'],
  ['SHELF-0042', 'SHELF-0042'], // an in-house label: not a GTIN, kept as read
  ['12345', '12345'], // digits, but no GTIN is this long
  ['123456789', '123456789'],
];

/** A stored barcode: already canonical, printable, no spaces. */
export const barcode = z
  .string()
  .regex(/^[\x21-\x7e]{4,48}$/, 'a barcode is 4 to 48 printable characters with no spaces')
  .refine((code) => canonicalBarcode(code) === code, {
    message: 'a GTIN is stored as 14 digits (use canonicalBarcode)',
  });

export const productBarcodes = z
  .array(barcode)
  .max(MAX_BARCODES_PER_PRODUCT)
  .refine((codes) => new Set(codes).size === codes.length, {
    message: 'the same barcode is listed twice',
  });

export const saleLinePayload = z.object({
  id: uuidv7,
  productId: uuidv7,
  /** FEFO-selected batch for a standard drug. Null only where no batch applies. */
  batchId: uuidv7.nullable(),
  /**
   * How many were sold **in the unit they were sold in** — tablets, or boxes when
   * `packSize` is set. Stock moves by `qty × packSize` ({@link baseQuantity}).
   */
  qty: quantity.positive(),
  /** The price of one unit of `qty`: a tablet's price, or a box's. */
  unitPriceSantim: santim.nonnegative(),
  lineTotalSantim: santim.nonnegative(),
  /**
   * Set when the line was sold as a pack (FR-11, ADR-030): the base units in one of them.
   *
   * The money invariant is untouched — `lineTotal = qty × unitPrice` still holds exactly,
   * in the pack's own price — which is why the pack is recorded on the line rather than
   * multiplied out. A box at 100.00 for 30 tablets has no whole-santim tablet price.
   *
   * The terminal's figure is the record. It is not checked against the product's current
   * packs: a till offline for days may hold yesterday's, and that sale still happened.
   *
   * Added in contract 1.5.0. A 1.4.0 terminal never sets it and its sales apply unchanged.
   */
  packSize: packSize.nullable().optional(),
  /** What the pack was called at the counter, for the receipt. Never parsed. */
  packName: z.string().trim().min(1).max(40).nullable().optional(),
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
  /**
   * V1 has no payment-gateway integration; other tenders are recorded, not settled.
   *
   * `credit` (contract 1.7.0, FR-16, ADR-034) is the part of a sale **not paid yet**: it
   * is owed by the sale's `customerId`. It is a payment row so that a sale's payments still
   * add up to its total — money received now and money promised, one list — and it never
   * counts toward a cash-up, because it never reached the drawer.
   */
  method: z.enum(['cash', 'other_recorded', 'credit']),
  amountSantim: santim.nonnegative(),
});
export type PaymentPayload = z.infer<typeof paymentPayload>;

const creditOf = (payments: ReadonlyArray<{ method: string; amountSantim: number }>): number =>
  payments.reduce((sum, p) => (p.method === 'credit' ? sum + p.amountSantim : sum), 0);

export const salePayload = z
  .object({
    shiftId: uuidv7.nullable(),
    cashierId: uuidv7,
    soldAt: utcTimestamp,
    totalSantim: santim.nonnegative(),
    lines: z.array(saleLinePayload).min(1),
    payments: z.array(paymentPayload),
    /**
     * Who owes the `credit` part of this sale (FR-16, ADR-034). Required whenever a payment
     * is on credit — a debt owed by nobody cannot be collected — and otherwise absent.
     *
     * Added in contract 1.7.0. A 1.6.0 terminal never sends it or a credit payment.
     */
    customerId: uuidv7.nullable().optional(),
    /**
     * The price list this sale was rung up on (FR-19, ADR-037). Absent or null is `retail`
     * — which is what every sale from a pre-1.8.0 terminal is.
     */
    priceTier: priceTier.nullable().optional(),
  })
  .refine((s) => s.lines.reduce((sum, l) => sum + l.lineTotalSantim, 0) === s.totalSantim, {
    message: 'sale total must equal the sum of its line totals (G4)',
    path: ['totalSantim'],
  })
  .refine((s) => s.lines.every((l) => l.qty * l.unitPriceSantim === l.lineTotalSantim), {
    message: 'each line total must equal qty * unit price (G4)',
    path: ['lines'],
  })
  .refine((s) => creditOf(s.payments) === 0 || Boolean(s.customerId), {
    message: 'a sale on credit must name the customer who owes it (FR-16)',
    path: ['customerId'],
  })
  .refine(
    (s) =>
      creditOf(s.payments) === 0 ||
      s.payments.reduce((sum, p) => sum + p.amountSantim, 0) === s.totalSantim,
    {
      // Held only where credit is involved, so nothing a 1.6.0 terminal sends is judged by
      // a rule it never knew. With credit it has to hold: the credit row IS the debt, and a
      // debt that is not "the total, less what was paid" is a number nobody can explain.
      message: 'with credit, the payments must add up to the sale total (G4)',
      path: ['payments'],
    },
  );

export type SalePayload = z.infer<typeof salePayload>;

/** The part of a sale that was put on credit: what its customer now owes for it. */
export function creditPortion(sale: { payments: ReadonlyArray<PaymentPayload> }): number {
  return creditOf(sale.payments);
}

/* -------------------------------------------------------------------------- */
/* Customer credit ledger — ዕዳ (FR-16, ADR-034) — contract v1.7.0              */
/* -------------------------------------------------------------------------- */

/**
 * A customer who may buy on credit: a regular, a clinic, an organisation.
 *
 * Created **at the counter**, offline — the first time someone asks to pay later is not a
 * moment to go and find a network. The id is minted on the terminal like every other
 * (ADR-006), so the credit sale that follows can name it before the server has heard of
 * either.
 *
 * Deliberately little. This is who owes money, not a patient record: no date of birth, no
 * address, nothing about what they are treated for (docs/01 §2.3).
 */
export const customerPayload = z.object({
  name: z.string().trim().min(1).max(120),
  /** For asking to be paid. Free text: local numbers are written many ways. */
  phone: z.string().trim().max(40).nullable(),
  /** "Pays at month end", "staff of the clinic next door". Never parsed. */
  note: z.string().trim().max(300).nullable(),
  createdAt: utcTimestamp,
});
export type CustomerPayload = z.infer<typeof customerPayload>;

/**
 * Money received against what a customer owes (FR-16).
 *
 * Its own operation, not a sale: nothing leaves the shelf. It reduces the customer's
 * balance, and when it is cash it went into the drawer — so it counts toward the cash-up
 * of the shift it was taken in, exactly as a cash sale does. Leaving it out would make
 * every repayment show up as unexplained extra cash.
 *
 * May exceed the balance: someone paying 500 against a debt of 480 is common, and the
 * honest record is that they are now 20 ahead.
 */
export const creditPaymentPayload = z.object({
  customerId: uuidv7,
  amountSantim: santim.positive(),
  /** How it was paid. Never `credit` — a debt is not settled with another debt. */
  method: z.enum(['cash', 'other_recorded']),
  paidAt: utcTimestamp,
  /** The open till it was taken in, so cash reaches the right cash-up (BR-8.2). */
  shiftId: uuidv7.nullable(),
  receivedBy: uuidv7,
  note: z.string().trim().max(300).nullable(),
});
export type CreditPaymentPayload = z.infer<typeof creditPaymentPayload>;

export const goodsReceiptLinePayload = z.object({
  id: uuidv7,
  productId: uuidv7,
  lotNo: z.string().min(1).max(64),
  expiryDate: isoDate,
  /** How many arrived, in the unit they were counted in — boxes when `packSize` is set. */
  qty: quantity.positive(),
  /** What one unit of `qty` cost: a box's cost when received by the box. */
  costSantim: santim.nonnegative(),
  /**
   * Set when the line was received in packs (FR-11, ADR-030). The batch is credited
   * `qty × packSize` base units. Kept on the line, not multiplied out, for the same reason
   * as on a sale: the invoice says 5 boxes at 120.00, and that is what must be recoverable.
   *
   * Added in contract 1.5.0.
   */
  packSize: packSize.nullable().optional(),
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
