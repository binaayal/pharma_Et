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
 * Whether a caught value means "your session has ended" (401).
 *
 * One function because there was one rule and six spellings of it. Two pages — the audit
 * trail and the platform console, the two most sensitive — reached straight for
 * `(cause as {status?: number}).status` with no guard, so a rejection that was not an object
 * would throw a TypeError **inside the catch block**: the error handler itself failing, which
 * takes the page down instead of showing the owner a sign-in screen.
 *
 * `unknown` rather than `Error` on purpose. A catch block receives whatever was thrown, and
 * assuming otherwise is precisely the bug this replaces.
 */
export function isSessionExpired(cause: unknown): boolean {
  return (
    typeof cause === 'object' &&
    cause !== null &&
    'status' in cause &&
    (cause as { status: unknown }).status === 401
  );
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

export interface AuditEntry {
  id: string;
  seq: number;
  eventType: string;
  streamId: string;
  actorId: string;
  branchId: string | null;
  payload: Record<string, unknown>;
  occurredAt: string;
  recordedAt: string;
}

export interface SubscriptionView {
  state: 'pending' | 'active' | 'suspended';
  currentPeriodEnd: string | null;
  priceSantim: number;
  suspendedReason: string | null;
  daysRemaining: number | null;
  pendingProofCount: number;
}

export interface PlatformTenant {
  id: string;
  name: string;
  code: string;
  status: string;
  subscriptionState: 'pending' | 'active' | 'suspended' | null;
  currentPeriodEnd: string | null;
  suspendedReason: string | null;
  pendingProofs: number;
}

export interface PendingProof {
  id: string;
  tenantId: string;
  tenantName: string;
  tenantCode: string;
  amountSantim: number;
  submittedAt: string;
  note: string | null;
  subscriptionState: string | null;
}

export const api = {
  login: (body: LoginRequest) =>
    request<LoginResponse>('/auth/login', { method: 'POST', body: JSON.stringify(body) }),

  /**
   * Exchanges a refresh token for a new session (ADR-019).
   *
   * Carries no access token, by definition: the point is that the old one has expired, and
   * requiring a live one to get a live one would be circular.
   */
  refresh: (body: { refreshToken: string; terminalId: string }) =>
    request<LoginResponse>('/auth/refresh', {
      method: 'POST',
      body: JSON.stringify(body),
    }),

  sales: (token: string) => request<SyncedSale[]>('/reports/sales', {}, token),

  oversells: (token: string) => request<OversellRow[]>('/reports/oversells', {}, token),

  cashUps: (token: string) => request<ShiftReconciliation[]>('/reports/cash-up', {}, token),

  salesSummary: (token: string, from: string, to: string) =>
    request<SalesSummary>(`/reports/sales-summary?from=${from}&to=${to}`, {}, token),

  audit: (token: string, limit = 100) => request<AuditEntry[]>(`/audit?limit=${limit}`, {}, token),

  stock: (token: string, expiringWithinDays: number) =>
    request<StockReport>(`/reports/stock?expiringWithinDays=${expiringWithinDays}`, {}, token),

  subscription: (token: string) => request<SubscriptionView>('/billing/subscription', {}, token),

  health: () => request<{ status: string; contractVersion: string }>('/health'),

  /**
   * The platform console (us). A separate login with a distinct token type — a tenant token
   * must never reach a route that can suspend a pharmacy (BR-2.2).
   */
  platform: {
    login: (email: string, password: string) =>
      request<{ accessToken: string; admin: { id: string; email: string; displayName: string } }>(
        '/platform/login',
        { method: 'POST', body: JSON.stringify({ email, password }) },
      ),
    tenants: (token: string) => request<PlatformTenant[]>('/platform/tenants', {}, token),
    pendingProofs: (token: string) =>
      request<PendingProof[]>('/platform/payment-proofs', {}, token),
    decide: (token: string, id: string, body: { accept: boolean; reason?: string }) =>
      request<unknown>(
        `/platform/payment-proofs/${id}/decide`,
        { method: 'POST', body: JSON.stringify(body) },
        token,
      ),
    setState: (
      token: string,
      body: { tenantId: string; state: 'active' | 'suspended'; reason?: string },
    ) =>
      request<unknown>(
        '/platform/subscriptions',
        { method: 'POST', body: JSON.stringify(body) },
        token,
      ),
    proofImageUrl: (id: string) => `/api/platform/payment-proofs/${id}/image`,
  },
};
