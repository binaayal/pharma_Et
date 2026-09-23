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

const BASE = '/api';

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

export const api = {
  login: (body: LoginRequest) =>
    request<LoginResponse>('/auth/login', { method: 'POST', body: JSON.stringify(body) }),

  sales: (token: string) => request<SyncedSale[]>('/reports/sales', {}, token),

  oversells: (token: string) => request<OversellRow[]>('/reports/oversells', {}, token),

  health: () => request<{ status: string; contractVersion: string }>('/health'),
};
