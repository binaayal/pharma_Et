import { describe, expect, it } from 'vitest';
import {
  CONTRACT_VERSION,
  SUPPORTED_CONTRACT_VERSIONS,
  MAX_PACK_SIZE,
  baseQuantity,
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
    expect(CONTRACT_VERSION).toBe('1.5.0');
  });
});
