import { describe, expect, it } from 'vitest';
import {
  CONTRACT_VERSION,
  SUPPORTED_CONTRACT_VERSIONS,
  BARCODE_VECTORS,
  MAX_PACK_SIZE,
  barcode,
  baseQuantity,
  canonicalBarcode,
  creditPaymentPayload,
  creditPortion,
  receiptCost,
  supplierPayload,
  supplierPaymentPayload,
  supplierRef,
  customerPayload,
  customerRef,
  productBarcodes,
  priceTier,
  pullResponse,
  cashUpPayload,
  goodsReceiptPayload,
  operation,
  productPacks,
  productRef,
  pushRequest,
  salePayload,
  santim,
  shiftPayload,
  uuidv7,
} from '../src/index.js';

const OP = '01930000-0000-7000-8000-000000000001';
const TERMINAL = '01930000-0000-7000-8000-000000000002';
const TENANT = '01930000-0000-7000-8000-000000000003';
const BRANCH = '01930000-0000-7000-8000-000000000004';
const ACTOR = '01930000-0000-7000-8000-000000000005';
const SALE = '01930000-0000-7000-8000-000000000006';
const LINE = '01930000-0000-7000-8000-000000000007';
const PRODUCT = '01930000-0000-7000-8000-000000000008';
const BATCH = '01930000-0000-7000-8000-000000000009';

const validSale = {
  shiftId: null,
  cashierId: ACTOR,
  soldAt: '2026-09-22T08:30:00Z',
  totalSantim: 4500,
  lines: [
    {
      id: LINE,
      productId: PRODUCT,
      batchId: BATCH,
      qty: 3,
      unitPriceSantim: 1500,
      lineTotalSantim: 4500,
    },
  ],
  payments: [{ id: OP, method: 'cash' as const, amountSantim: 4500 }],
};

const validOperation = {
  opId: OP,
  terminalId: TERMINAL,
  terminalSeq: 1,
  entityId: SALE,
  opType: 'create' as const,
  baseVersion: null,
  tenantId: TENANT,
  branchId: BRANCH,
  actorId: ACTOR,
  clientTs: '2026-09-22T08:30:01Z',
  entityType: 'sale' as const,
  payload: validSale,
};

describe('identifiers (ADR-006)', () => {
  it('accepts a UUIDv7', () => {
    expect(uuidv7.safeParse(OP).success).toBe(true);
  });

  it('rejects a UUIDv4 — offline writes need time-ordered, client-mintable ids', () => {
    expect(uuidv7.safeParse('9f1b0c2e-6b1a-4c3d-8f2a-1b2c3d4e5f60').success).toBe(false);
  });
});

describe('money (guardian G4)', () => {
  it('rejects a fractional amount, so no float can reach money math', () => {
    expect(santim.safeParse(19.99).success).toBe(false);
  });

  it('accepts an integer count of santim', () => {
    expect(santim.safeParse(1999).success).toBe(true);
  });

  it('rejects a sale whose total does not equal the sum of its lines', () => {
    const bad = { ...validSale, totalSantim: 4400 };
    expect(salePayload.safeParse(bad).success).toBe(false);
  });

  it('rejects a line whose total is not qty * unit price', () => {
    const bad = {
      ...validSale,
      lines: [{ ...validSale.lines[0], lineTotalSantim: 5000 }],
      totalSantim: 5000,
    };
    expect(salePayload.safeParse(bad).success).toBe(false);
  });
});

describe('sync envelope (docs/04 §7, controlled artifact)', () => {
  it('parses a well-formed sale operation', () => {
    expect(operation.safeParse(validOperation).success).toBe(true);
  });

  it('rejects an operation with no idempotency key', () => {
    const { opId: _drop, ...rest } = validOperation;
    expect(operation.safeParse(rest).success).toBe(false);
  });

  it('rejects an unknown entity type rather than accepting an untyped payload', () => {
    expect(
      operation.safeParse({ ...validOperation, entityType: 'controlled_dispense' }).success,
    ).toBe(false);
  });

  it('has no "delete" op type — nothing is ever physically removed (ADR-002/004)', () => {
    expect(operation.safeParse({ ...validOperation, opType: 'delete' }).success).toBe(false);
    expect(operation.safeParse({ ...validOperation, opType: 'tombstone' }).success).toBe(true);
  });

  it('caps a push batch so one terminal cannot submit an unbounded payload', () => {
    const ops = Array.from({ length: 501 }, (_, i) => ({ ...validOperation, terminalSeq: i }));
    expect(pushRequest.safeParse({ terminalId: TERMINAL, operations: ops }).success).toBe(false);
  });

  it('defaults the contract version so an old client is still identifiable', () => {
    const parsed = pushRequest.parse({ terminalId: TERMINAL, operations: [validOperation] });
    expect(parsed.contractVersion).toBe(CONTRACT_VERSION);
  });
});

describe('contract versioning (ADR-009)', () => {
  it('always supports the current version', () => {
    expect(SUPPORTED_CONTRACT_VERSIONS).toContain(CONTRACT_VERSION);
  });
});

/* -------------------------------------------------------------------------- */
/* Contract v1.1.0 — shift & cash-up (FR-8, ADR-012)                           */
/* -------------------------------------------------------------------------- */

describe('cash-up (FR-8, BR-8.2)', () => {
  const base = {
    shiftId: BRANCH,
    userId: ACTOR,
    countedAt: '2026-09-23T17:00:00Z',
    expectedSantim: 45000,
    countedSantim: 44200,
    varianceSantim: -800,
    note: 'short by one 8 birr sale, checking receipts',
  };

  it('accepts a shortfall — a negative variance is the whole point of the feature', () => {
    expect(cashUpPayload.safeParse(base).success).toBe(true);
  });

  it('accepts an overage', () => {
    expect(
      cashUpPayload.safeParse({ ...base, countedSantim: 45500, varianceSantim: 500 }).success,
    ).toBe(true);
  });

  it('rejects a variance that does not equal counted minus expected', () => {
    // Otherwise a client could report a clean till while the numbers say otherwise, which
    // is precisely the fraud the control exists to catch.
    expect(cashUpPayload.safeParse({ ...base, varianceSantim: 0 }).success).toBe(false);
  });

  it('rejects a negative counted amount — you cannot count less than nothing', () => {
    expect(
      cashUpPayload.safeParse({ ...base, countedSantim: -100, varianceSantim: -45100 }).success,
    ).toBe(false);
  });

  it('rejects fractional money', () => {
    expect(
      cashUpPayload.safeParse({ ...base, countedSantim: 44200.5, varianceSantim: -799.5 }).success,
    ).toBe(false);
  });
});

describe('shift', () => {
  const open = {
    userId: ACTOR,
    openedAt: '2026-09-23T06:00:00Z',
    closedAt: null,
    openingFloatSantim: 20000,
  };

  it('accepts an open shift', () => {
    expect(shiftPayload.safeParse(open).success).toBe(true);
  });

  it('accepts a closed shift', () => {
    expect(shiftPayload.safeParse({ ...open, closedAt: '2026-09-23T17:00:00Z' }).success).toBe(
      true,
    );
  });

  it('rejects a negative opening float', () => {
    expect(shiftPayload.safeParse({ ...open, openingFloatSantim: -1 }).success).toBe(false);
  });
});

describe('envelope v1.1.0 (ADR-012)', () => {
  const shiftOp = {
    ...validOperation,
    entityType: 'shift' as const,
    payload: {
      userId: ACTOR,
      openedAt: '2026-09-23T06:00:00Z',
      closedAt: null,
      openingFloatSantim: 20000,
    },
  };

  it('carries the new entity types', () => {
    expect(operation.safeParse(shiftOp).success).toBe(true);
  });

  it('still carries the v1.0.0 types unchanged — additive means additive', () => {
    expect(operation.safeParse(validOperation).success).toBe(true);
  });

  it('keeps 1.0.0 inside the support window (ADR-009)', () => {
    // A terminal offline since before this release reconnects speaking 1.0.0. Dropping it
    // would mean its queued sales have nowhere to go.
    expect(SUPPORTED_CONTRACT_VERSIONS).toContain('1.0.0');
    expect(SUPPORTED_CONTRACT_VERSIONS).toContain('1.1.0');
  });

  it('rejects a shift payload sent under the wrong entity type', () => {
    expect(operation.safeParse({ ...shiftOp, entityType: 'sale' }).success).toBe(false);
  });
});

describe('envelope v1.5.0 — sell units (FR-11, ADR-030)', () => {
  const boxLine = {
    ...validSale.lines[0],
    qty: 2,
    // 100.00 for a box of 30: there is no whole-santim tablet price that makes this.
    unitPriceSantim: 10_000,
    lineTotalSantim: 20_000,
    packSize: 30,
    packName: 'box',
  };
  const boxSale = { ...validSale, totalSantim: 20_000, lines: [boxLine] };

  it("accepts a line sold as a pack, at the pack's own price", () => {
    expect(salePayload.safeParse(boxSale).success).toBe(true);
  });

  it('keeps the money invariant in the unit sold — qty × unit price, exactly (G4)', () => {
    const wrong = {
      ...boxSale,
      lines: [{ ...boxLine, lineTotalSantim: 19_999 }],
      totalSantim: 19_999,
    };
    expect(salePayload.safeParse(wrong).success).toBe(false);
  });

  it('moves stock by qty × pack size, and by qty alone without one', () => {
    expect(baseQuantity(boxLine)).toBe(60);
    expect(baseQuantity(validSale.lines[0])).toBe(3);
    expect(baseQuantity({ qty: 3, packSize: null })).toBe(3);
  });

  it('still accepts a 1.4.0 line unchanged — no pack fields at all (ADR-009)', () => {
    expect(salePayload.safeParse(validSale).success).toBe(true);
    expect(operation.safeParse(validOperation).success).toBe(true);
  });

  it('accepts explicit nulls, which is what the generated Dart sends', () => {
    const nulls = {
      ...validSale,
      lines: [{ ...validSale.lines[0], packSize: null, packName: null }],
    };
    expect(salePayload.safeParse(nulls).success).toBe(true);
  });

  it('rejects a pack of one, of zero, and a fractional pack', () => {
    for (const packSize of [1, 0, -5, 2.5, MAX_PACK_SIZE + 1]) {
      const bad = { ...boxSale, lines: [{ ...boxLine, packSize }] };
      expect(salePayload.safeParse(bad).success, `packSize ${packSize}`).toBe(false);
    }
  });

  it('accepts a receipt counted in boxes at a box cost', () => {
    const receipt = {
      supplierName: 'EPSS',
      receivedAt: '2026-10-07T08:00:00Z',
      lines: [
        {
          id: LINE,
          productId: PRODUCT,
          lotNo: 'L1',
          expiryDate: '2027-12-31',
          qty: 5,
          costSantim: 9_000,
          packSize: 30,
        },
      ],
    };
    const parsed = goodsReceiptPayload.parse(receipt);
    expect(baseQuantity(parsed.lines[0])).toBe(150);
  });

  it('refuses two packs with one name, or two of one size', () => {
    const strip = { name: 'strip', size: 10, priceSantim: 1_000 };
    expect(
      productPacks.safeParse([strip, { name: 'box', size: 100, priceSantim: 9_000 }]).success,
    ).toBe(true);
    expect(productPacks.safeParse([strip, { ...strip, name: 'Strip', size: 20 }]).success).toBe(
      false,
    );
    expect(productPacks.safeParse([strip, { ...strip, name: 'blister' }]).success).toBe(false);
  });

  it('refuses a fractional pack price — a pack is money too (G4)', () => {
    expect(productPacks.safeParse([{ name: 'box', size: 30, priceSantim: 99.5 }]).success).toBe(
      false,
    );
  });

  const ref = {
    id: PRODUCT,
    name: 'Amoxicillin 500mg',
    unit: 'capsule',
    isControlled: false,
    psychotropicClass: null,
    currentPriceSantim: 400,
    changeSeq: 7,
    deletedAt: null,
  };

  it('pulls a product with no `packs` at all — what a 1.4.0 server sends', () => {
    expect(productRef.safeParse(ref).success).toBe(true);
  });

  it('pulls a product with its packs', () => {
    const parsed = productRef.parse({
      ...ref,
      packs: [{ name: 'box', size: 30, priceSantim: 10_000 }],
    });
    expect(parsed.packs).toHaveLength(1);
  });

  it('keeps every earlier version inside the support window (ADR-009)', () => {
    for (const v of ['1.0.0', '1.1.0', '1.2.0', '1.3.0', '1.4.0', '1.5.0']) {
      expect(SUPPORTED_CONTRACT_VERSIONS).toContain(v);
    }
  });
});

describe('contract v1.6.0 — barcodes (FR-13, ADR-031)', () => {
  it.each(BARCODE_VECTORS)('canonicalises %s to %s', (input, canonical) => {
    expect(canonicalBarcode(input)).toBe(canonical);
  });

  it('is idempotent — canonicalising twice changes nothing', () => {
    for (const [input] of BARCODE_VECTORS) {
      const once = canonicalBarcode(input);
      expect(canonicalBarcode(once)).toBe(once);
    }
  });

  it('makes the EAN-13 on the box and the GTIN in its DataMatrix the same barcode', () => {
    expect(canonicalBarcode('6291100080014')).toBe(canonicalBarcode('06291100080014'));
  });

  it('stores only the canonical form, so two spellings cannot both be saved', () => {
    expect(barcode.safeParse('06291100080014').success).toBe(true);
    expect(barcode.safeParse('6291100080014').success).toBe(false);
  });

  it('refuses a barcode with a space, a control character, or nothing in it', () => {
    for (const bad of ['', 'abc', 'has space 1', 'tab\there', '\u001d0106291100080014']) {
      expect(barcode.safeParse(bad).success, JSON.stringify(bad)).toBe(false);
    }
  });

  it('refuses the same barcode twice on one product', () => {
    expect(productBarcodes.safeParse(['06291100080014', 'SHELF-0042']).success).toBe(true);
    expect(productBarcodes.safeParse(['06291100080014', '06291100080014']).success).toBe(false);
  });

  const ref = {
    id: PRODUCT,
    name: 'Amoxicillin 500mg capsule',
    unit: 'capsule',
    isControlled: false,
    psychotropicClass: null,
    currentPriceSantim: 400,
    changeSeq: 7,
    deletedAt: null,
  };

  it('pulls a product with no `barcodes` at all — what a 1.5.0 server sends', () => {
    expect(productRef.safeParse(ref).success).toBe(true);
  });

  it('pulls a product with its barcodes', () => {
    expect(productRef.parse({ ...ref, barcodes: ['06291100080014'] }).barcodes).toHaveLength(1);
  });

  it('keeps every earlier version inside the support window (ADR-009)', () => {
    for (const v of ['1.0.0', '1.4.0', '1.5.0', '1.6.0']) {
      expect(SUPPORTED_CONTRACT_VERSIONS).toContain(v);
    }
  });
});

describe('contract v1.7.0 — customer credit ledger (FR-16, ADR-034)', () => {
  const CUSTOMER = '01930000-0000-7000-8000-00000000000c';
  const PAY2 = '01930000-0000-7000-8000-00000000000d';

  /** 45.00 sold; 20.00 paid in cash now, 25.00 owed. */
  const partCredit = {
    ...validSale,
    customerId: CUSTOMER,
    payments: [
      { id: OP, method: 'cash' as const, amountSantim: 2000 },
      { id: PAY2, method: 'credit' as const, amountSantim: 2500 },
    ],
  };

  it('accepts a sale partly paid and partly on credit', () => {
    const parsed = salePayload.parse(partCredit);
    expect(creditPortion(parsed)).toBe(2500);
  });

  it('accepts a sale wholly on credit', () => {
    const all = {
      ...partCredit,
      payments: [{ id: OP, method: 'credit' as const, amountSantim: 4500 }],
    };
    expect(creditPortion(salePayload.parse(all))).toBe(4500);
  });

  it('refuses credit owed by nobody — a debt needs a customer', () => {
    const { customerId: _omit, ...anonymous } = partCredit;
    expect(salePayload.safeParse(anonymous).success).toBe(false);
    expect(salePayload.safeParse({ ...partCredit, customerId: null }).success).toBe(false);
  });

  it('refuses a credit sale whose payments do not add up to its total (G4)', () => {
    const short = {
      ...partCredit,
      payments: [
        { id: OP, method: 'cash' as const, amountSantim: 2000 },
        { id: PAY2, method: 'credit' as const, amountSantim: 2400 },
      ],
    };
    expect(salePayload.safeParse(short).success).toBe(false);
  });

  it('owes nothing on a sale with no credit in it', () => {
    expect(creditPortion(salePayload.parse(validSale))).toBe(0);
  });

  it('still accepts a 1.6.0 sale unchanged — no customer, no credit (ADR-009)', () => {
    expect(salePayload.safeParse(validSale).success).toBe(true);
    expect(operation.safeParse(validOperation).success).toBe(true);
    // And the rule about payments adding up is not applied to it retroactively: a 1.0.0
    // terminal was never asked for that, and its sales must not start being refused.
    const legacy = { ...validSale, payments: [] };
    expect(salePayload.safeParse(legacy).success).toBe(true);
  });

  it('accepts explicit null for the customer, which is what the generated Dart sends', () => {
    expect(salePayload.safeParse({ ...validSale, customerId: null }).success).toBe(true);
  });

  const customer = {
    name: 'Abebe Kebede',
    phone: '0911 23 45 67',
    note: null,
    createdAt: '2026-10-07T08:00:00Z',
  };

  it('carries a customer created at the counter', () => {
    const op = {
      ...validOperation,
      entityId: CUSTOMER,
      entityType: 'customer' as const,
      payload: customer,
    };
    expect(operation.safeParse(op).success).toBe(true);
  });

  it('refuses a customer with no name', () => {
    expect(customerPayload.safeParse({ ...customer, name: '   ' }).success).toBe(false);
  });

  it('asks for nothing about the person beyond who owes the money', () => {
    // docs/01 §2.3: this is a debt book, not a patient record.
    expect(Object.keys(customerPayload.shape).sort()).toEqual([
      'createdAt',
      'name',
      'note',
      'phone',
    ]);
  });

  const repayment = {
    customerId: CUSTOMER,
    amountSantim: 2500,
    method: 'cash' as const,
    paidAt: '2026-10-08T09:00:00Z',
    shiftId: null,
    receivedBy: ACTOR,
    note: null,
  };

  it('carries a repayment', () => {
    const op = { ...validOperation, entityType: 'credit_payment' as const, payload: repayment };
    expect(operation.safeParse(op).success).toBe(true);
  });

  it('refuses a repayment of nothing, of less than nothing, or of a fraction', () => {
    for (const amountSantim of [0, -100, 12.5]) {
      expect(creditPaymentPayload.safeParse({ ...repayment, amountSantim }).success).toBe(false);
    }
  });

  it('refuses settling a debt with more credit', () => {
    expect(creditPaymentPayload.safeParse({ ...repayment, method: 'credit' }).success).toBe(false);
  });

  it('pulls a customer with a balance that may be owed, settled or paid ahead', () => {
    const ref = {
      id: CUSTOMER,
      name: 'Abebe',
      phone: null,
      note: null,
      changeSeq: 4,
      deletedAt: null,
    };
    for (const balanceSantim of [2500, 0, -2000]) {
      expect(customerRef.safeParse({ ...ref, balanceSantim }).success).toBe(true);
    }
    expect(customerRef.safeParse({ ...ref, balanceSantim: 10.5 }).success).toBe(false);
  });

  it('pulls a page with no `customers` at all — what a 1.6.0 server sends', () => {
    const page = {
      contractVersion: '1.6.0',
      cursor: 1,
      hasMore: false,
      products: [],
      branches: [],
      users: [],
      stockBatches: [],
      serverTime: '2026-10-07T08:00:00Z',
    };
    expect(pullResponse.safeParse(page).success).toBe(true);
  });

  it('keeps every earlier version inside the support window (ADR-009)', () => {
    for (const v of ['1.0.0', '1.5.0', '1.6.0', '1.7.0']) {
      expect(SUPPORTED_CONTRACT_VERSIONS).toContain(v);
    }
  });
});

describe('contract v1.8.0 — price tiers (FR-19, ADR-037)', () => {
  it('accepts a sale rung up at wholesale', () => {
    const parsed = salePayload.parse({ ...validSale, priceTier: 'wholesale' });
    expect(parsed.priceTier).toBe('wholesale');
  });

  it('still accepts a 1.7.0 sale unchanged — no tier at all (ADR-009)', () => {
    expect(salePayload.safeParse(validSale).success).toBe(true);
    expect(salePayload.parse(validSale).priceTier).toBeUndefined();
  });

  it('accepts explicit null, which is what the generated Dart sends for retail', () => {
    expect(salePayload.safeParse({ ...validSale, priceTier: null }).success).toBe(true);
  });

  it('refuses a tier that is not one of the two', () => {
    expect(priceTier.safeParse('staff').success).toBe(false);
    expect(salePayload.safeParse({ ...validSale, priceTier: 'vip' }).success).toBe(false);
  });

  it('does not let the tier touch the money rule: total is still qty × the price charged', () => {
    const wrong = {
      ...validSale,
      priceTier: 'wholesale',
      lines: [{ ...validSale.lines[0], lineTotalSantim: 4000 }],
      totalSantim: 4000,
    };
    expect(salePayload.safeParse(wrong).success).toBe(false);
  });

  it('carries a wholesale price on a pack, and none on a pack without one', () => {
    const box = { name: 'box', size: 30, priceSantim: 10_000 };
    expect(productPacks.safeParse([box]).success).toBe(true);
    expect(productPacks.safeParse([{ ...box, wholesalePriceSantim: 9_000 }]).success).toBe(true);
    expect(productPacks.safeParse([{ ...box, wholesalePriceSantim: null }]).success).toBe(true);
    expect(productPacks.safeParse([{ ...box, wholesalePriceSantim: 90.5 }]).success).toBe(false);
    expect(productPacks.safeParse([{ ...box, wholesalePriceSantim: -1 }]).success).toBe(false);
  });

  const ref = {
    id: PRODUCT,
    name: 'Amoxicillin 500mg capsule',
    unit: 'capsule',
    isControlled: false,
    psychotropicClass: null,
    currentPriceSantim: 400,
    changeSeq: 7,
    deletedAt: null,
  };

  it('pulls a product with no wholesale price — what a 1.7.0 server sends', () => {
    expect(productRef.safeParse(ref).success).toBe(true);
  });

  it('pulls a product with one, or with an explicit null', () => {
    expect(productRef.parse({ ...ref, wholesalePriceSantim: 350 }).wholesalePriceSantim).toBe(350);
    expect(productRef.safeParse({ ...ref, wholesalePriceSantim: null }).success).toBe(true);
  });

  it('keeps every earlier version inside the support window (ADR-009)', () => {
    for (const v of ['1.0.0', '1.6.0', '1.7.0', '1.8.0']) {
      expect(SUPPORTED_CONTRACT_VERSIONS).toContain(v);
    }
  });
});

describe('contract v1.9.0 — suppliers and what is owed to them (FR-18, ADR-038)', () => {
  const SUPPLIER = '01930000-0000-7000-8000-0000000000e1';
  // Five boxes at 90.00: the delivery cost 450.00.
  const receipt = {
    supplierName: 'EPSS',
    receivedAt: '2026-10-07T08:00:00Z',
    lines: [
      {
        id: LINE,
        productId: PRODUCT,
        lotNo: 'L1',
        expiryDate: '2027-12-31',
        qty: 5,
        costSantim: 9_000,
        packSize: 30,
      },
    ],
  };

  it('still accepts a 1.8.0 receipt unchanged — a name, no account (ADR-009)', () => {
    const parsed = goodsReceiptPayload.parse(receipt);
    expect(parsed.supplierId).toBeUndefined();
    expect(parsed.owedSantim).toBeUndefined();
  });

  it('accepts explicit nulls, which is what the generated Dart sends', () => {
    expect(
      goodsReceiptPayload.safeParse({ ...receipt, supplierId: null, owedSantim: null }).success,
    ).toBe(true);
  });

  it('costs a delivery by its lines, in the unit they were counted in', () => {
    // Five boxes at the box cost — never 150 capsules at the box cost.
    expect(receiptCost(receipt)).toBe(45_000);
  });

  it('accepts a delivery paid for, part paid, and wholly on account', () => {
    for (const owedSantim of [0, 20_000, 45_000]) {
      expect(
        goodsReceiptPayload.safeParse({ ...receipt, supplierId: SUPPLIER, owedSantim }).success,
      ).toBe(true);
    }
  });

  it('refuses a debt owed to nobody', () => {
    expect(goodsReceiptPayload.safeParse({ ...receipt, owedSantim: 20_000 }).success).toBe(false);
    expect(
      goodsReceiptPayload.safeParse({ ...receipt, supplierId: null, owedSantim: 20_000 }).success,
    ).toBe(false);
  });

  it('refuses owing more than the delivery cost, or a fraction of a santim (G4)', () => {
    for (const owedSantim of [45_001, -1, 100.5]) {
      expect(
        goodsReceiptPayload.safeParse({ ...receipt, supplierId: SUPPLIER, owedSantim }).success,
      ).toBe(false);
    }
  });

  const supplier = {
    name: 'Addis Pharma Import',
    phone: '0911 000000',
    note: null,
    createdAt: '2026-10-07T08:00:00Z',
  };

  it('carries a supplier created while receiving', () => {
    const op = { ...validOperation, entityType: 'supplier' as const, payload: supplier };
    expect(operation.safeParse(op).success).toBe(true);
    expect(supplierPayload.safeParse({ ...supplier, name: '  ' }).success).toBe(false);
  });

  const payment = {
    supplierId: SUPPLIER,
    amountSantim: 20_000,
    method: 'cash' as const,
    paidAt: '2026-10-07T09:00:00Z',
    shiftId: null,
    paidBy: ACTOR,
    note: null,
  };

  it('carries a payment to a supplier, from a till or not', () => {
    const op = { ...validOperation, entityType: 'supplier_payment' as const, payload: payment };
    expect(operation.safeParse(op).success).toBe(true);
    expect(supplierPaymentPayload.safeParse({ ...payment, shiftId: SALE }).success).toBe(true);
    expect(supplierPaymentPayload.safeParse({ ...payment, method: 'other_recorded' }).success).toBe(
      true,
    );
  });

  it('refuses a payment of nothing, of less than nothing, or on credit', () => {
    for (const amountSantim of [0, -500, 10.5]) {
      expect(supplierPaymentPayload.safeParse({ ...payment, amountSantim }).success).toBe(false);
    }
    expect(supplierPaymentPayload.safeParse({ ...payment, method: 'credit' }).success).toBe(false);
  });

  it('pulls a supplier owed, settled or paid ahead', () => {
    const ref = {
      id: SUPPLIER,
      name: 'EPSS',
      phone: null,
      note: null,
      changeSeq: 4,
      deletedAt: null,
    };
    for (const balanceSantim of [45_000, 0, -2_000]) {
      expect(supplierRef.safeParse({ ...ref, balanceSantim }).success).toBe(true);
    }
    expect(supplierRef.safeParse({ ...ref, balanceSantim: 0.5 }).success).toBe(false);
  });

  it('pulls a page with no `suppliers` at all — what a 1.8.0 server sends', () => {
    const page = {
      contractVersion: '1.8.0',
      cursor: 1,
      hasMore: false,
      products: [],
      branches: [],
      users: [],
      stockBatches: [],
      serverTime: '2026-10-07T08:00:00Z',
    };
    expect(pullResponse.safeParse(page).success).toBe(true);
  });

  it('keeps every earlier version inside the support window (ADR-009)', () => {
    for (const v of ['1.0.0', '1.7.0', '1.8.0', '1.9.0']) {
      expect(SUPPORTED_CONTRACT_VERSIONS).toContain(v);
    }
    expect(CONTRACT_VERSION).toBe('1.9.0');
  });
});
