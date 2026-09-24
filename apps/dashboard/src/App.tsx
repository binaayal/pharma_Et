import { useEffect, useRef, useState } from 'react';
import { AuditPage } from './pages/AuditPage';
import { CashUpPage } from './pages/CashUpPage';
import { LoginPage } from './pages/LoginPage';
import { SalesPage } from './pages/SalesPage';
import { SalesSummaryPage } from './pages/SalesSummaryPage';
import { StockPage } from './pages/StockPage';
import { api } from './lib/api';
import type { Calendar } from './lib/format';
import { clearSession, loadSession, saveSession, terminalId, type Session } from './lib/session';

/**
 * Phase 0 console: sign in, and see that sales really arrived (docs/04 §13).
 *
 * Tenant onboarding, payment-screenshot verification and subscription control — the
 * platform-admin surface proper — come with Phase 1. The navigation names them now so the
 * shape of the console is visible, and marks them as not yet built rather than pretending.
 */
type Page = 'sales' | 'cash-up' | 'summary' | 'stock' | 'audit';

export function App() {
  const [session, setSession] = useState<Session | null>(() => loadSession());
  const renewing = useRef(false);
  /** The access token our last renewal produced, so a token refused twice is not retried. */
  const lastRenewedTo = useRef<string | null>(null);
  const [contractVersion, setContractVersion] = useState<string | null>(null);
  const [page, setPage] = useState<Page>('cash-up');
  // Presentation only (BR-10.2). Stored timestamps never change with this (AC-10.2), and
  // localStorage is the right home: a per-viewer convenience, not shared state.
  const [calendar, setCalendar] = useState<Calendar>(() => {
    try {
      return localStorage.getItem('pharmaet.calendar') === 'ethiopian' ? 'ethiopian' : 'gregorian';
    } catch {
      return 'gregorian';
    }
  });

  function chooseCalendar(next: Calendar) {
    setCalendar(next);
    try {
      localStorage.setItem('pharmaet.calendar', next);
    } catch {
      // Private browsing or blocked storage. The choice simply will not survive a reload.
    }
  }

  useEffect(() => {
    // Surfacing the server's contract version makes an N-1 mismatch visible to whoever is
    // looking at the console, instead of only in a log (ADR-009).
    api
      .health()
      .then((h) => setContractVersion(h.contractVersion))
      .catch(() => setContractVersion(null));
  }, []);

  function signIn(next: Session) {
    saveSession(next);
    setSession(next);
  }

  function signOut() {
    clearSession();
    setSession(null);
  }

  /**
   * A page reported a 401. Try to renew before giving up on the owner (ADR-019).
   *
   * One place, not six. Every page already funnels an expired session here, and each one's
   * loader is keyed on `session.accessToken` — so replacing the token re-runs the fetch on
   * its own and the page fills in. Putting the retry in the pages would have recreated
   * exactly the duplication that left four spellings of the 401 check.
   *
   * Only sign out when the renewal itself fails, which means the refresh token is spent,
   * expired, or its user has been deactivated — none of which the console can fix by asking
   * again. Before this, an owner reviewing reports was signed out every fifteen minutes.
   */
  async function renewOrSignOut() {
    if (!session?.refreshToken) return signOut();

    // Guard against a stampede: several pages can report a 401 in the same tick, and each
    // redemption would otherwise race the others for one token.
    if (renewing.current) return;

    // And against a loop. A renewal replaces the token, which re-runs the page's loader; if
    // that is refused too, renewing again would produce a fresh token every time and never
    // stop. One attempt per issued token, then the honest answer.
    if (lastRenewedTo.current === session.accessToken) return signOut();

    renewing.current = true;

    try {
      const renewed = await api.refresh({
        refreshToken: session.refreshToken,
        terminalId: terminalId(),
      });
      const next: Session = {
        accessToken: renewed.accessToken,
        refreshToken: renewed.refreshToken,
        scope: renewed.scope,
        tenantCode: session.tenantCode,
      };
      lastRenewedTo.current = renewed.accessToken;
      saveSession(next);
      setSession(next);
    } catch {
      signOut();
    } finally {
      renewing.current = false;
    }
  }

  if (!session) return <LoginPage onSignedIn={signIn} />;

  return (
    <div className="shell">
      <aside className="sidebar">
        <div className="brand">
          <div className="mark">P</div>
          <div>
            <b>PharmaEt</b>
            <span>Admin console</span>
          </div>
        </div>

        <div className="nav-group">Oversight</div>
        {/* Cash reconciliation leads, because Vision §2.1.1 says it is the reason an owner
            buys this: it is the first thing they should see on opening the console. */}
        <button
          className={`nav-item${page === 'cash-up' ? ' active' : ''}`}
          onClick={() => setPage('cash-up')}
        >
          Cash reconciliation
        </button>
        <button
          className={`nav-item${page === 'summary' ? ' active' : ''}`}
          onClick={() => setPage('summary')}
        >
          Sales summary
        </button>
        <button
          className={`nav-item${page === 'stock' ? ' active' : ''}`}
          onClick={() => setPage('stock')}
        >
          Stock &amp; expiry
        </button>
        <button
          className={`nav-item${page === 'sales' ? ' active' : ''}`}
          onClick={() => setPage('sales')}
        >
          Synced sales
        </button>
        <button
          className={`nav-item${page === 'audit' ? ' active' : ''}`}
          onClick={() => setPage('audit')}
        >
          Audit trail
        </button>

        <div className="nav-group">Platform · Phase 1</div>
        <button className="nav-item" disabled title="Arrives with Phase 1">
          Sign-up requests
        </button>
        <button className="nav-item" disabled title="Arrives with Phase 1">
          Payment verification
        </button>
        <button className="nav-item" disabled title="Arrives with Phase 1">
          Subscriptions
        </button>

        <div className="nav-group">Calendar</div>
        <button
          className={`nav-item${calendar === 'gregorian' ? ' active' : ''}`}
          onClick={() => chooseCalendar('gregorian')}
        >
          Gregorian
        </button>
        <button
          className={`nav-item${calendar === 'ethiopian' ? ' active' : ''}`}
          onClick={() => chooseCalendar('ethiopian')}
        >
          Ethiopian · ኢትዮጵያዊ
        </button>

        <div className="nav-group">Session</div>
        <button className="nav-item" onClick={signOut}>
          Sign out ({session.scope.displayName})
        </button>
      </aside>

      <main className="main">
        {page === 'cash-up' && (
          <CashUpPage session={session} onExpired={renewOrSignOut} calendar={calendar} />
        )}
        {page === 'summary' && <SalesSummaryPage session={session} onExpired={renewOrSignOut} />}
        {page === 'stock' && (
          <StockPage session={session} onExpired={renewOrSignOut} calendar={calendar} />
        )}
        {page === 'sales' && <SalesPage session={session} onExpired={renewOrSignOut} />}
        {page === 'audit' && (
          <AuditPage session={session} onExpired={renewOrSignOut} calendar={calendar} />
        )}
        <p className="footnote">
          Signed in to <strong>{session.tenantCode}</strong> as {session.scope.role}.
          {contractVersion && <> Server contract v{contractVersion}.</>} Money is stored as integer
          santim and formatted only here, at the edge.
        </p>
      </main>
    </div>
  );
}
