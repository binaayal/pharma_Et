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
 * A deployed bundle is served from a different origin than the API — GitHub Pages and a separate API host —
 * so the base is baked in at build time from VITE_API_BASE_URL, and the API's CORS_ORIGINS
 * must name that origin. Both halves are set by the deploy workflow; if either is missing
 * the console loads and every request fails, which is why the health probe on boot is worth
 * having.
 */
const BASE = import.meta.env.VITE_API_BASE_URL ?? '/api';

/**
 * Every call rides on the platform session **cookie** — HttpOnly, SameSite=Strict, set by
 * `/platform/login` — never on a token this script holds. An injected script therefore has
 * no credential to steal: the one that can deactivate a pharmacy is out of JavaScript's
 * reach (docs/engineering/security.md).
 *
 * The contract header doubles as the server's CSRF check on writes: a cross-site form or
 * image cannot set a custom header, and a cross-site script cannot pass CORS preflight.
 */
async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
  const response = await fetch(`${BASE}${path}`, {
    ...init,
    credentials: 'same-origin',
    headers: {
      'content-type': 'application/json',
      [CONTRACT_VERSION_HEADER]: CONTRACT_VERSION,
      ...init.headers,
    },
  });

  if (!response.ok) {
    const body = await response.json().catch(() => ({}));
    throw new ApiError(body.message ?? `request failed (${response.status})`, response.status);
  }
  if (response.status === 204) return undefined as T;
  return (await response.json()) as T;
}

export type SubscriptionState = 'pending' | 'active' | 'suspended';

export interface PlatformTenant {
  id: string;
  name: string;
  code: string;
  /** `deactivated` is the platform's forced stop (ADR-025), separate from billing. */
  status: 'active' | 'closed' | 'deactivated';
  deactivatedAt: string | null;
  deactivatedReason: string | null;
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

  /** Sets the session cookie. The token in the body is for scripts; the console ignores it. */
  login: (email: string, password: string) =>
    request<{ admin: { id: string; email: string; displayName: string } }>('/platform/login', {
      method: 'POST',
      body: JSON.stringify({ email, password }),
    }),

  /** Whether this browser holds a live session — the console cannot read the cookie itself. */
  me: () => request<{ id: string; email: string }>('/platform/me'),

  logout: () => request<void>('/platform/logout', { method: 'POST' }),

  tenants: () => request<PlatformTenant[]>('/platform/tenants'),

  tenant: (id: string) => request<TenantDetail>(`/platform/tenants/${id}`),

  onboard: (body: {
    name: string;
    code: string;
    ownerUsername: string;
    ownerDisplayName: string;
    ownerPin: string;
  }) =>
    request<{ tenantId: string }>('/platform/tenants', {
      method: 'POST',
      body: JSON.stringify(body),
    }),

  signupRequests: (status: SignupRequest['status']) =>
    request<SignupRequest[]>(`/platform/signup-requests?status=${status}`),

  decideSignup: (id: string, decision: SignupDecision) =>
    request<unknown>(`/platform/signup-requests/${id}/decide`, {
      method: 'POST',
      body: JSON.stringify(decision),
    }),

  pendingProofs: () => request<PendingProof[]>('/platform/payment-proofs'),

  decideProof: (id: string, body: { accept: boolean; reason?: string }) =>
    request<unknown>(`/platform/payment-proofs/${id}/decide`, {
      method: 'POST',
      body: JSON.stringify(body),
    }),

  /** The screenshot, as an object URL — fetched with the session cookie. */
  proofImage: async (id: string): Promise<string> => {
    const response = await fetch(`${BASE}/platform/payment-proofs/${id}/image`, {
      credentials: 'same-origin',
    });
    if (!response.ok) throw new ApiError('could not load the screenshot', response.status);
    return URL.createObjectURL(await response.blob());
  },

  /** ADR-025: every request the pharmacy makes is refused until it is reactivated. */
  deactivate: (tenantId: string, reason: string) =>
    request<unknown>(`/platform/tenants/${tenantId}/deactivate`, {
      method: 'POST',
      body: JSON.stringify({ reason }),
    }),

  reactivate: (tenantId: string, note?: string) =>
    request<unknown>(`/platform/tenants/${tenantId}/reactivate`, {
      method: 'POST',
      body: JSON.stringify({ note }),
    }),

  setState: (body: { tenantId: string; state: 'active' | 'suspended'; reason?: string }) =>
    request<unknown>('/platform/subscriptions', { method: 'POST', body: JSON.stringify(body) }),
};
