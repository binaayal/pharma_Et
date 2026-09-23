import { uuidv7 } from 'uuidv7';
import type { SeededTenant } from '../harness';

export const TERMINAL = '01930000-0000-7000-8000-0000000000e1';

/** Builds a syntactically valid sale operation for a seeded tenant. */
export function saleOp(
  tenant: SeededTenant,
  options: {
    terminalSeq: number;
    qty?: number;
    unitPriceSantim?: number;
    batchId?: string | null;
    opId?: string;
    entityId?: string;
    totalOverride?: number;
  },
) {
  const qty = options.qty ?? 1;
  const unit = options.unitPriceSantim ?? 1500;
  const lineTotal = qty * unit;
  return {
    opId: options.opId ?? uuidv7(),
    terminalId: TERMINAL,
    terminalSeq: options.terminalSeq,
    entityId: options.entityId ?? uuidv7(),
    opType: 'create' as const,
    baseVersion: null,
    tenantId: tenant.id,
    branchId: tenant.branchIds[0],
    actorId: tenant.users.cashier.id,
    clientTs: new Date(Date.UTC(2026, 8, 22, 8, 0, options.terminalSeq % 60)).toISOString(),
    entityType: 'sale' as const,
    payload: {
      shiftId: null,
      cashierId: tenant.users.cashier.id,
      soldAt: new Date(Date.UTC(2026, 8, 22, 8, 0, options.terminalSeq % 60)).toISOString(),
      totalSantim: options.totalOverride ?? lineTotal,
      lines: [
        {
          id: uuidv7(),
          productId: tenant.productId,
          batchId: options.batchId === undefined ? tenant.batchIds[1] : options.batchId,
          qty,
          unitPriceSantim: unit,
          lineTotalSantim: lineTotal,
        },
      ],
      payments: [{ id: uuidv7(), method: 'cash' as const, amountSantim: lineTotal }],
    },
  };
}

export function receiptOp(
  tenant: SeededTenant,
  options: { terminalSeq: number; qty: number; lotNo: string; expiryDate: string },
) {
  return {
    opId: uuidv7(),
    terminalId: TERMINAL,
    terminalSeq: options.terminalSeq,
    entityId: uuidv7(),
    opType: 'create' as const,
    baseVersion: null,
    tenantId: tenant.id,
    branchId: tenant.branchIds[0],
    actorId: tenant.users.manager.id,
    clientTs: '2026-09-22T07:00:00.000Z',
    entityType: 'goods_receipt' as const,
    payload: {
      supplierName: 'Test Wholesaler',
      receivedAt: '2026-09-22T07:00:00.000Z',
      lines: [
        {
          id: uuidv7(),
          productId: tenant.productId,
          lotNo: options.lotNo,
          expiryDate: options.expiryDate,
          qty: options.qty,
          costSantim: 800,
        },
      ],
    },
  };
}

export function shiftOp(
  tenant: SeededTenant,
  options: {
    terminalSeq: number;
    shiftId?: string;
    openingFloatSantim?: number;
    closedAt?: string | null;
    opType?: 'create' | 'update';
  },
) {
  return {
    opId: uuidv7(),
    terminalId: TERMINAL,
    terminalSeq: options.terminalSeq,
    entityId: options.shiftId ?? uuidv7(),
    opType: options.opType ?? ('create' as const),
    baseVersion: null,
    tenantId: tenant.id,
    branchId: tenant.branchIds[0],
    actorId: tenant.users.cashier.id,
    clientTs: '2026-09-23T06:00:00.000Z',
    entityType: 'shift' as const,
    payload: {
      userId: tenant.users.cashier.id,
      openedAt: '2026-09-23T06:00:00.000Z',
      closedAt: options.closedAt ?? null,
      openingFloatSantim: options.openingFloatSantim ?? 20000,
    },
  };
}

export function cashUpOp(
  tenant: SeededTenant,
  options: {
    terminalSeq: number;
    shiftId: string;
    expectedSantim: number;
    countedSantim: number;
    note?: string | null;
    userId?: string;
  },
) {
  return {
    opId: uuidv7(),
    terminalId: TERMINAL,
    terminalSeq: options.terminalSeq,
    entityId: uuidv7(),
    opType: 'create' as const,
    baseVersion: null,
    tenantId: tenant.id,
    branchId: tenant.branchIds[0],
    actorId: tenant.users.cashier.id,
    clientTs: '2026-09-23T17:00:00.000Z',
    entityType: 'cash_up' as const,
    payload: {
      shiftId: options.shiftId,
      userId: options.userId ?? tenant.users.cashier.id,
      countedAt: '2026-09-23T17:00:00.000Z',
      expectedSantim: options.expectedSantim,
      countedSantim: options.countedSantim,
      varianceSantim: options.countedSantim - options.expectedSantim,
      note: options.note ?? null,
    },
  };
}

/** A sale bound to a shift, so its cash reaches that shift's expected figure. */
export function saleInShift(
  tenant: SeededTenant,
  options: {
    terminalSeq: number;
    shiftId: string;
    qty?: number;
    unitPriceSantim?: number;
    method?: 'cash' | 'other_recorded';
  },
) {
  const op = saleOp(tenant, {
    terminalSeq: options.terminalSeq,
    qty: options.qty,
    unitPriceSantim: options.unitPriceSantim,
    batchId: null,
  });
  return {
    ...op,
    payload: {
      ...op.payload,
      shiftId: options.shiftId,
      payments: op.payload.payments.map((p) => ({ ...p, method: options.method ?? 'cash' })),
    },
  };
}
