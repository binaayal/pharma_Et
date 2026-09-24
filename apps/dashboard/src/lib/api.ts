import { CONTRACT_VERSION, CONTRACT_VERSION_HEADER } from '@pharmaet/contracts';

/**
 * The platform console's API client.
 *
 * The web console is ours, not the pharmacies' (prototype screens 20–26): sign-up review,
 * tenants, payment verification and subscriptions. Everything a pharmacy owner does lives in
 * the mobile app. So every call here carries a **platform** token, which the server keeps
 * structurally separate from any tenant token (BR-2.2).
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
 * One function, guarded: a rejection that is not an object must not throw a TypeError
 * **inside the catch block**, which would take the page down instead of showing sign-in.
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

export type SubscriptionState = 'pending' | 'active' | 'suspended';

export interface PlatformTenant {
  id: string;
  name: string;
  code: string;
  status: string;
  createdAt: string;
  subscriptionState: SubscriptionState | null;
  currentPeriodEnd: string | null;
  suspendedReason: string | null;
  priceSantim: number | null;
  pendingProofs: number;
  branchCount: number;
  branchNames: string | null;
  ownerName: string | null;
  ownerPhone: string | null;
}

export interface TenantDetail extends PlatformTenant {
  branches: Array<{
    id: string;
    name: string;
    address: string | null;
    staffCount: number;
    lastSyncAt: string | null;
  }>;
  lastPaymentAt: string | null;
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

export interface SignupRequest {
  id: string;
  pharmacyName: string;
  ownerName: string;
  phone: string;
  city: string;
  branchBand: '1' | '2-3' | '4+';
  status: 'pending' | 'approved' | 'rejected';
  submittedAt: string;
  decidedAt: string | null;
  decisionReason: string | null;
  tenantId: string | null;
}

export type SignupDecision =
  | { accept: true; code: string; ownerUsername: string; ownerPin: string }
  | { accept: false; reason: string };

export const api = {
  health: () => request<{ status: string; contractVersion: string }>('/health'),

  login: (email: string, password: string) =>
    request<{ accessToken: string; admin: { id: string; email: string; displayName: string } }>(
      '/platform/login',
      { method: 'POST', body: JSON.stringify({ email, password }) },
    ),

  tenants: (token: string) => request<PlatformTenant[]>('/platform/tenants', {}, token),

  tenant: (token: string, id: string) =>
    request<TenantDetail>(`/platform/tenants/${id}`, {}, token),

  onboard: (
    token: string,
    body: { name: string; code: string; ownerUsername: string; ownerDisplayName: string; ownerPin: string },
  ) =>
    request<{ tenantId: string }>(
      '/platform/tenants',
      { method: 'POST', body: JSON.stringify(body) },
      token,
    ),

  signupRequests: (token: string, status: SignupRequest['status']) =>
    request<SignupRequest[]>(`/platform/signup-requests?status=${status}`, {}, token),

  decideSignup: (token: string, id: string, decision: SignupDecision) =>
    request<unknown>(
      `/platform/signup-requests/${id}/decide`,
      { method: 'POST', body: JSON.stringify(decision) },
      token,
    ),

  pendingProofs: (token: string) =>
    request<PendingProof[]>('/platform/payment-proofs', {}, token),

  decideProof: (token: string, id: string, body: { accept: boolean; reason?: string }) =>
    request<unknown>(
      `/platform/payment-proofs/${id}/decide`,
      { method: 'POST', body: JSON.stringify(body) },
      token,
    ),

  /**
   * The screenshot, fetched with the platform token.
   *
   * It used to be a plain link, which a browser follows without an Authorization header — so
   * the guard refused it and the reviewer could never see the proof they were approving.
   */
  proofImage: async (token: string, id: string): Promise<string> => {
    const response = await fetch(`${BASE}/platform/payment-proofs/${id}/image`, {
      headers: { authorization: `Bearer ${token}` },
    });
    if (!response.ok) throw new ApiError('could not load the screenshot', response.status);
    return URL.createObjectURL(await response.blob());
  },

  setState: (
    token: string,
    body: { tenantId: string; state: 'active' | 'suspended'; reason?: string },
  ) =>
    request<unknown>(
      '/platform/subscriptions',
      { method: 'POST', body: JSON.stringify(body) },
      token,
    ),
};
