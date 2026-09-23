import type { LoginRequest, LoginResponse } from '@pharmaet/contracts';
import { CONTRACT_VERSION, CONTRACT_VERSION_HEADER } from '@pharmaet/contracts';

/**
 * The dashboard's API client.
 *
 * Request and response types come from @pharmaet/contracts — the same schemas the server
 * validates against and the mobile app's Dart types are generated from (ADR-010). Nothing
 * here restates a shape the contract already defines; a drift between this file and the
 * server would be a type error rather than a runtime surprise in front of a customer.
 */

export class ApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message);
  }
}

/**
 * In development the Vite proxy forwards `/api` to the local server, so a relative base
 * keeps the browser same-origin and CORS out of the picture entirely.
 *
 * A deployed bundle is served from a different origin than the API — GitHub Pages and Fly —
 * so the base is baked in at build time from VITE_API_BASE_URL, and the API's CORS_ORIGINS
 * must name that origin. Both halves are set by the deploy workflow; if either is missing
 * the console loads and every request fails, which is why the health probe on boot is worth
 * having.
 */
const BASE = import.meta.env.VITE_API_BASE_URL ?? '/api';

async function request<T>(path: string, init: RequestInit = {}, token?: string): Promise<T> {
  const response = await fetch(`${BASE}${path}`, {
    ...init,
    headers: {
      'content-type': 'application/json',
      [CONTRACT_VERSION_HEADER]: CONTRACT_VERSION,
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...init.headers,
    },
  });

  if (!response.ok) {
    const body = await response.json().catch(() => ({}));
    throw new ApiError(body.message ?? `request failed (${response.status})`, response.status);
  }
  return (await response.json()) as T;
}

export interface SyncedSale {
  id: string;
  branchId: string;
  branchName: string;
  cashierId: string;
  totalSantim: number;
  soldAt: string;
  syncedAt: string;
  lineCount: number;
}

export interface OversellRow {
  id: string;
  branchId: string;
  productId: string;
  saleId: string;
  resultingQty: number;
  observedAt: string;
}

/** One shift's reconciliation, as the Z-report returns it (FR-8, AC-8.1). */
export interface ShiftReconciliation {
  shiftId: string;
  branchId: string;
  userId: string;
  openedAt: string;
  closedAt: string | null;
  openingFloatSantim: number;
  cashTakenSantim: number;
  /** Recomputed by the server from sales that have actually synced. */
  serverExpectedSantim: number;
  saleCount: number;
  countedSantim: number | null;
  /** What the terminal showed the cashier at count time. Never recomputed (ADR-012 §3). */
  terminalExpectedSantim: number | null;
  varianceSantim: number | null;
  /** serverExpected − terminalExpected. Non-zero means sales were still queued. */
  expectationGapSantim: number | null;
  countedAt: string | null;
  note: string | null;
}

export interface BranchSalesRow {
  branchId: string;
  branchName: string;
  saleCount: number;
  grossSantim: number;
  cashSantim: number;
  otherTenderSantim: number;
  itemsSold: number;
}

export interface SalesSummary {
  from: string;
  to: string;
  branches: BranchSalesRow[];
  total: Omit<BranchSalesRow, 'branchId' | 'branchName'>;
  /** When the most recent sale in this window actually reached the server (BR-8.1). */
  lastSyncedAt: string | null;
}

export interface StockRow {
  batchId: string;
  branchId: string;
  branchName: string;
  productId: string;
  productName: string;
  unit: string;
  lotNo: string;
  expiryDate: string;
  qtyOnHand: number;
  daysToExpiry: number;
  status: 'expired' | 'expiring' | 'oversold' | 'ok';
  valueSantim: number;
}

export interface StockReport {
  asOf: string;
  expiringWithinDays: number;
  rows: StockRow[];
  summary: {
    expiredBatches: number;
    expiringBatches: number;
    oversoldBatches: number;
    expiredValueSantim: number;
    expiringValueSantim: number;
  };
}

export const api = {
  login: (body: LoginRequest) =>
    request<LoginResponse>('/auth/login', { method: 'POST', body: JSON.stringify(body) }),

  sales: (token: string) => request<SyncedSale[]>('/reports/sales', {}, token),

  oversells: (token: string) => request<OversellRow[]>('/reports/oversells', {}, token),

  cashUps: (token: string) => request<ShiftReconciliation[]>('/reports/cash-up', {}, token),

  salesSummary: (token: string, from: string, to: string) =>
    request<SalesSummary>(`/reports/sales-summary?from=${from}&to=${to}`, {}, token),

  stock: (token: string, expiringWithinDays: number) =>
    request<StockReport>(`/reports/stock?expiringWithinDays=${expiringWithinDays}`, {}, token),

  health: () => request<{ status: string; contractVersion: string }>('/health'),
};
