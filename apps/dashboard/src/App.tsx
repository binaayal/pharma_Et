import { useEffect, useState } from 'react';
import { LoginPage } from './pages/LoginPage';
import { SalesPage } from './pages/SalesPage';
import { api } from './lib/api';
import { clearSession, loadSession, saveSession, type Session } from './lib/session';

/**
 * Phase 0 console: sign in, and see that sales really arrived (docs/04 §13).
 *
 * Tenant onboarding, payment-screenshot verification and subscription control — the
 * platform-admin surface proper — come with Phase 1. The navigation names them now so the
 * shape of the console is visible, and marks them as not yet built rather than pretending.
 */
export function App() {
  const [session, setSession] = useState<Session | null>(() => loadSession());
  const [contractVersion, setContractVersion] = useState<string | null>(null);

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
        <button className="nav-item active">Synced sales</button>

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

        <div className="nav-group">Session</div>
        <button className="nav-item" onClick={signOut}>
          Sign out ({session.scope.displayName})
        </button>
      </aside>

      <main className="main">
        <SalesPage session={session} onExpired={signOut} />
        <p className="footnote">
          Signed in to <strong>{session.tenantCode}</strong> as {session.scope.role}.
          {contractVersion && <> Server contract v{contractVersion}.</>} Money is stored as
          integer santim and formatted only here, at the edge.
        </p>
      </main>
    </div>
  );
}
