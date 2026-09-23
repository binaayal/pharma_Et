import { describe, expect, it } from 'vitest';
import {
  CONTRACT_VERSION,
  SUPPORTED_CONTRACT_VERSIONS,
  operation,
  pushRequest,
  salePayload,
  santim,
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
