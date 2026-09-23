import { useEffect, useState } from 'react';
import { AuditPage } from './pages/AuditPage';
import { CashUpPage } from './pages/CashUpPage';
import { LoginPage } from './pages/LoginPage';
import { SalesPage } from './pages/SalesPage';
import { SalesSummaryPage } from './pages/SalesSummaryPage';
import { StockPage } from './pages/StockPage';
import { api } from './lib/api';
import type { Calendar } from './lib/format';
import { clearSession, loadSession, saveSession, type Session } from './lib/session';

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
          <CashUpPage session={session} onExpired={signOut} calendar={calendar} />
        )}
        {page === 'summary' && <SalesSummaryPage session={session} onExpired={signOut} />}
        {page === 'stock' && (
          <StockPage session={session} onExpired={signOut} calendar={calendar} />
        )}
        {page === 'sales' && <SalesPage session={session} onExpired={signOut} />}
        {page === 'audit' && (
          <AuditPage session={session} onExpired={signOut} calendar={calendar} />
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
