// @vitest-environment jsdom
import { cleanup, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiError } from '../src/lib/api';
import type { Session } from '../src/lib/session';

/**
 * T3 — the console's pages (docs/05-qa §3).
 *
 * §3 asks for "critical-path e2e + smoke" at this tier, and the critical path through every
 * one of these pages is the same: load, or fail in a way the owner can act on. The
 * behaviour worth pinning is the **session contract** — that a 401 signs them out and
 * anything else does not — because every page implements it and the consequence of getting
 * it wrong is silent. An owner stuck on a page that never loads has no way to know a
 * re-login would fix it.
 */
vi.mock('../src/lib/api', async () => {
  const actual = await vi.importActual<typeof import('../src/lib/api')>('../src/lib/api');
  return {
    ...actual,
    api: {
      sales: vi.fn(),
      oversells: vi.fn(),
      cashUps: vi.fn(),
      salesSummary: vi.fn(),
      stock: vi.fn(),
      audit: vi.fn(),
      subscription: vi.fn(),
      health: vi.fn(),
      platform: { login: vi.fn(), tenants: vi.fn(), pendingProofs: vi.fn() },
    },
  };
});

const { api } = await import('../src/lib/api');
const { SalesPage } = await import('../src/pages/SalesPage');
const { AuditPage } = await import('../src/pages/AuditPage');

const session: Session = {
  accessToken: 'tok',
  tenantCode: 'abay',
  scope: {
    userId: '01930000-0000-7000-8000-000000000001',
    tenantId: '01930000-0000-7000-8000-000000000002',
    role: 'owner',
    branchIds: [],
    displayName: 'Abay owner',
  },
};

const calendar = { toEthiopian: (iso: string) => iso.slice(0, 10) };

afterEach(cleanup);

describe('SalesPage', () => {
  beforeEach(() => vi.clearAllMocks());

  it('signs the owner out when the session has ended', async () => {
    vi.mocked(api.sales).mockRejectedValue(new ApiError('expired', 401));
    vi.mocked(api.oversells).mockRejectedValue(new ApiError('expired', 401));
    const onExpired = vi.fn();

    render(<SalesPage session={session} onExpired={onExpired} />);

    // The whole of the console's session handling. Without it the owner sits on a page that
    // never loads, with no reason to suspect that signing in again would fix it.
    await waitFor(() => expect(onExpired).toHaveBeenCalled());
  });

  it('does not sign them out for an ordinary failure', async () => {
    vi.mocked(api.sales).mockRejectedValue(new ApiError('server exploded', 500));
    vi.mocked(api.oversells).mockRejectedValue(new ApiError('server exploded', 500));
    const onExpired = vi.fn();

    render(<SalesPage session={session} onExpired={onExpired} />);

    // Signing out on a 500 would lose the owner's place for a problem that is not theirs and
    // that a refresh might well clear.
    await waitFor(() => expect(screen.getByText(/server exploded/)).toBeDefined());
    expect(onExpired).not.toHaveBeenCalled();
  });

  it('shows the takings it loaded', async () => {
    vi.mocked(api.sales).mockResolvedValue([
      {
        id: 's1',
        branchId: 'b1',
        branchName: 'Main branch',
        cashierId: 'c1',
        totalSantim: 12500,
        soldAt: '2026-09-24T08:00:00.000Z',
        syncedAt: '2026-09-24T08:01:00.000Z',
        lineCount: 3,
      },
    ]);
    vi.mocked(api.oversells).mockResolvedValue([]);

    render(<SalesPage session={session} onExpired={vi.fn()} />);

    // 12500 santim is 125.00 ETB. Money is integer santim to the very edge, and the edge is
    // here — a page that rendered "12500" would be off by a hundred (G4).
    // `getAllByText`: the figure appears twice by design — once as the day's total and once
    // in the sale's own row — and a single-match finder would fail on correct output.
    await waitFor(() => expect(screen.getAllByText(/125\.00 ETB/).length).toBeGreaterThan(0));
    expect(screen.getByText(/Main branch/)).toBeDefined();
  });
});

describe('AuditPage', () => {
  beforeEach(() => vi.clearAllMocks());

  it('signs the owner out when the session has ended', async () => {
    vi.mocked(api.audit).mockRejectedValue(new ApiError('expired', 401));
    const onExpired = vi.fn();

    render(<AuditPage session={session} onExpired={onExpired} calendar={calendar} />);

    await waitFor(() => expect(onExpired).toHaveBeenCalled());
  });

  it('explains a 403 rather than showing an empty table', async () => {
    vi.mocked(api.audit).mockRejectedValue(new ApiError('forbidden', 403));

    render(<AuditPage session={session} onExpired={vi.fn()} calendar={calendar} />);

    // An empty audit table reads as "nobody has done anything", which is the worst possible
    // answer from an audit log. Saying the matrix grants it to the owner alone is the honest
    // one.
    await waitFor(() => expect(screen.getByText(/Only the owner/)).toBeDefined());
  });

  it('survives a rejection that is not an object at all', async () => {
    // The case that used to throw inside the catch block: `(cause as {...}).status` on a
    // non-object. The page must still render rather than taking the console down with it.
    vi.mocked(api.audit).mockRejectedValue('a bare string');
    const onExpired = vi.fn();

    render(<AuditPage session={session} onExpired={onExpired} calendar={calendar} />);

    await waitFor(() => expect(onExpired).not.toHaveBeenCalled());
    expect(document.body.textContent).toBeTruthy();
  });
});
