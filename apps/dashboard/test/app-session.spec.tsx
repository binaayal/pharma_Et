// @vitest-environment jsdom
import { cleanup, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiError } from '../src/lib/api';

/**
 * The console's session continuity (ADR-019).
 *
 * Before this, an expired access token signed the owner out — honest, and every fifteen
 * minutes. Someone reading a month's sales summary was returned to the login screen
 * mid-thought, repeatedly, by a console whose whole job is to be sat in front of.
 *
 * The renewal lives in one place because every page already funnels a 401 to the same
 * callback, and each page's loader is keyed on the access token — so replacing it re-runs
 * the fetch and the page fills itself in. Putting a retry in each page would have rebuilt
 * exactly the duplication that left four spellings of the 401 check.
 */
vi.mock('../src/lib/api', async () => {
  const actual = await vi.importActual<typeof import('../src/lib/api')>('../src/lib/api');
  return {
    ...actual,
    api: {
      // Sane defaults, not bare `vi.fn()`. A mock that resolves `undefined` makes every page
      // throw on `.length` before it can reach the behaviour under test, and the failure
      // looks nothing like the thing that caused it.
      login: vi.fn(),
      refresh: vi.fn(),
      sales: vi.fn().mockResolvedValue([]),
      oversells: vi.fn().mockResolvedValue([]),
      cashUps: vi.fn().mockResolvedValue([]),
      salesSummary: vi.fn().mockResolvedValue({
        totalSantim: 0,
        saleCount: 0,
        branches: [],
      }),
      stock: vi.fn().mockResolvedValue({ batches: [], expiringSoon: [] }),
      audit: vi.fn().mockResolvedValue([]),
      subscription: vi.fn().mockResolvedValue({ state: 'active' }),
      health: vi.fn().mockResolvedValue({ status: 'ok', contractVersion: '1.3.0' }),
      platform: {
        login: vi.fn(),
        tenants: vi.fn().mockResolvedValue([]),
        pendingProofs: vi.fn().mockResolvedValue([]),
      },
    },
  };
});

const { api } = await import('../src/lib/api');
const { App } = await import('../src/App');

const scope = {
  userId: '01930000-0000-7000-8000-000000000001',
  tenantId: '01930000-0000-7000-8000-000000000002',
  role: 'owner' as const,
  branchIds: [],
  displayName: 'Abay owner',
};

const storedSession = (accessToken: string, refreshToken: string) =>
  sessionStorage.setItem(
    'pharmaet.session',
    JSON.stringify({ accessToken, refreshToken, scope, tenantCode: 'abay' }),
  );

beforeEach(() => {
  // `clearAllMocks`, not `resetAllMocks`: reset would strip the default resolutions above
  // and put every page back to throwing on undefined.
  vi.clearAllMocks();
  vi.mocked(api.sales).mockResolvedValue([]);
  vi.mocked(api.oversells).mockResolvedValue([]);
  vi.mocked(api.cashUps).mockResolvedValue([]);
  vi.mocked(api.audit).mockResolvedValue([]);
  vi.mocked(api.health).mockResolvedValue({ status: 'ok', contractVersion: '1.3.0' });
  sessionStorage.clear();
  localStorage.clear();
});
afterEach(cleanup);

describe('when a page reports an expired session', () => {
  it('renews it and the owner stays where they were', async () => {
    storedSession('stale', 'good-refresh');
    // The console lands on cash-up, so that is the page that reports the expiry. Mocking a
    // page the app never renders would leave the 401 unreported and the test waiting.
    vi.mocked(api.cashUps).mockRejectedValueOnce(new ApiError('expired', 401));
    vi.mocked(api.cashUps).mockResolvedValue([]);
    vi.mocked(api.refresh).mockResolvedValue({
      accessToken: 'fresh',
      refreshToken: 'next-refresh',
      expiresAt: new Date(Date.now() + 900_000).toISOString(),
      offlineValidUntil: new Date(Date.now() + 604_800_000).toISOString(),
      scope,
    });

    render(<App />);

    await waitFor(() => expect(api.refresh).toHaveBeenCalledOnce());

    // Still signed in — no login form. This is the whole point: the owner never learns that
    // anything expired.
    await waitFor(() =>
      expect(screen.queryByLabelText(/Pharmacy code/i)).toBeNull(),
    );
    expect(JSON.parse(sessionStorage.getItem('pharmaet.session')!).accessToken).toBe('fresh');
  });

  it('signs them out only when the renewal itself fails', async () => {
    storedSession('stale', 'spent-refresh');
    vi.mocked(api.cashUps).mockRejectedValue(new ApiError('expired', 401));
    vi.mocked(api.refresh).mockRejectedValue(new ApiError('session expired', 401));

    render(<App />);

    // A spent or revoked refresh token, or a deactivated user. None of those can be fixed by
    // asking again, so the honest answer is the login screen.
    await waitFor(() => expect(sessionStorage.getItem('pharmaet.session')).toBeNull());
  });

  it('does not try to renew a session stored before refresh existed', async () => {
    storedSession('stale', '');
    vi.mocked(api.cashUps).mockRejectedValue(new ApiError('expired', 401));

    render(<App />);

    // Posting an empty token would earn a 401 that reads as a dead session anyway. Going
    // straight to the login screen is the same outcome without the misleading round trip.
    await waitFor(() => expect(sessionStorage.getItem('pharmaet.session')).toBeNull());
    expect(api.refresh).not.toHaveBeenCalled();
  });

  it('does not loop when the renewed token is refused as well', async () => {
    storedSession('stale', 'good-refresh');
    vi.mocked(api.cashUps).mockRejectedValue(new ApiError('expired', 401));
    vi.mocked(api.refresh).mockResolvedValue({
      accessToken: 'fresh',
      refreshToken: 'next-refresh',
      expiresAt: new Date(Date.now() + 900_000).toISOString(),
      offlineValidUntil: new Date(Date.now() + 604_800_000).toISOString(),
      scope,
    });

    render(<App />);

    // Renewing replaces the token, which re-runs the page's loader. If that is refused too —
    // a revoked user, a server problem, a clock far out — renewing again would mint a fresh
    // token every time and never stop. One attempt per issued token, then the login screen.
    //
    // My first version of this had no such bound and called refresh three times before the
    // test stopped it; in a browser it would not have stopped.
    await waitFor(() => expect(sessionStorage.getItem('pharmaet.session')).toBeNull());
    expect(api.refresh).toHaveBeenCalledTimes(1);
  });
});
