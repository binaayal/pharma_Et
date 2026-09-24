import { useState } from 'react';
import { api } from '../lib/api';
import { terminalId } from '../lib/session';
import type { Session } from '../lib/session';

/**
 * Console login.
 *
 * The tenant code is asked for explicitly because authentication happens before any tenant
 * scope exists: usernames are unique per tenant, not globally, so "abebe" alone does not
 * identify anybody (see LoginRequest in @pharmaet/contracts).
 */
export function LoginPage({ onSignedIn }: { onSignedIn: (session: Session) => void }) {
  // The development seed is offered in `vite dev` only. A built console is what a pharmacy
  // opens, and it must not suggest a tenant, let alone print a password that works on every
  // environment seeded from the same script — staging included.
  const [tenantCode, setTenantCode] = useState(import.meta.env.DEV ? 'abay' : '');
  const [username, setUsername] = useState(import.meta.env.DEV ? 'owner' : '');
  const [secret, setSecret] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const response = await api.login({
        tenantCode,
        username,
        secret,
        // The console is a browser, not a provisioned terminal, but the contract records a
        // terminal on every session so a dispute can always be traced to its origin (BR-4.3).
        // Per browser rather than one constant for all of them: a field that names the same
        // phantom device for every owner on every machine records nothing.
        terminalId: terminalId(),
      });
      onSignedIn({
        accessToken: response.accessToken,
        refreshToken: response.refreshToken,
        scope: response.scope,
        tenantCode,
      });
    } catch (cause) {
      // One message for every failure mode. Distinguishing "no such pharmacy" from "wrong
      // PIN" tells an attacker which tenant codes and usernames are real.
      setError(cause instanceof Error ? cause.message : 'sign-in failed');
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="login-wrap">
      <form className="login-card" onSubmit={submit}>
        <h1>PharmaEt Console</h1>
        <p className="sub">Platform operations and owner oversight.</p>

        {error && <div className="error">{error}</div>}

        <div className="field">
          <label htmlFor="tenantCode">Pharmacy code</label>
          <input
            id="tenantCode"
            value={tenantCode}
            onChange={(e) => setTenantCode(e.target.value)}
            autoComplete="organization"
            required
          />
        </div>

        <div className="field">
          <label htmlFor="username">Username</label>
          <input
            id="username"
            value={username}
            onChange={(e) => setUsername(e.target.value)}
            autoComplete="username"
            required
          />
        </div>

        <div className="field">
          <label htmlFor="secret">Password or PIN</label>
          <input
            id="secret"
            type="password"
            value={secret}
            onChange={(e) => setSecret(e.target.value)}
            autoComplete="current-password"
            required
          />
        </div>

        <button className="primary" type="submit" disabled={busy}>
          {busy ? 'Signing in…' : 'Sign in'}
        </button>

        {import.meta.env.DEV && (
          <div className="hint-box">
            <strong>Development seed:</strong>
            <br />
            <code>abay / owner / owner-dev-password</code>
            <br />
            <code>tana / owner / owner-dev-password</code> — a second tenant, so isolation is
            visible by just signing in as the other one.
          </div>
        )}
      </form>
    </div>
  );
}
