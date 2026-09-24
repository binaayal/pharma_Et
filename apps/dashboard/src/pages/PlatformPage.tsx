import { useCallback, useEffect, useState } from 'react';
import { api, isSessionExpired, type PendingProof, type PlatformTenant } from '../lib/api';
import { formatEtb, formatInstant, relativeAge } from '../lib/format';

/**
 * The platform console (FR-1, Vision §4) — us, not a tenant.
 *
 * V1 has no payment gateway and will not for six months or more. A pharmacy pays ETB
 * 1,000/month, sends a screenshot, and **a person looks at it**. This page is that person's
 * workbench, and it is built for the judgement they are actually making: is this screenshot
 * a real payment of the right amount from the right pharmacy?
 *
 * So the queue leads, the image is one click away, and the two decisions are adjacent. A
 * rejection demands a reason because the tenant is shown it verbatim — without one their
 * next submission is a guess.
 *
 * Separate login, separate token. A tenant session cannot reach any of this (BR-2.2).
 */
export function PlatformPage() {
  const [token, setToken] = useState<string | null>(() => {
    try {
      return sessionStorage.getItem('pharmaet.platform') ?? null;
    } catch {
      return null;
    }
  });

  if (!token) return <PlatformLogin onSignedIn={setToken} />;
  return <PlatformConsole token={token} onSignOut={() => setToken(null)} />;
}

function PlatformLogin({ onSignedIn }: { onSignedIn: (token: string) => void }) {
  const [email, setEmail] = useState(import.meta.env.DEV ? 'admin@pharmaet.local' : '');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const { accessToken } = await api.platform.login(email, password);
      try {
        // sessionStorage, not localStorage: this token can suspend a pharmacy and has no
        // business outliving the tab.
        sessionStorage.setItem('pharmaet.platform', accessToken);
      } catch {
        /* private browsing — the session simply will not survive a reload */
      }
      onSignedIn(accessToken);
    } catch {
      setError('Could not sign in.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="login-wrap">
      <form className="login-card" onSubmit={submit}>
        <h1>Platform console</h1>
        <p className="sub">Onboarding, payment verification and subscriptions.</p>
        {error && <div className="error">{error}</div>}
        <div className="field">
          <label htmlFor="pemail">Email</label>
          <input id="pemail" value={email} onChange={(e) => setEmail(e.target.value)} required />
        </div>
        <div className="field">
          <label htmlFor="ppass">Password</label>
          <input
            id="ppass"
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            required
          />
        </div>
        <button className="primary" type="submit" disabled={busy}>
          {busy ? 'Signing in…' : 'Sign in'}
        </button>
        <div className="hint-box">
          This is a separate identity from any pharmacy account. A tenant login cannot reach these
          pages, and this one cannot read a pharmacy's sales.
        </div>
      </form>
    </div>
  );
}

function PlatformConsole({ token, onSignOut }: { token: string; onSignOut: () => void }) {
  const [tenants, setTenants] = useState<PlatformTenant[] | null>(null);
  const [proofs, setProofs] = useState<PendingProof[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const [t, p] = await Promise.all([
        api.platform.tenants(token),
        api.platform.pendingProofs(token),
      ]);
      setTenants(t);
      setProofs(p);
      setError(null);
    } catch (cause) {
      if (isSessionExpired(cause)) return onSignOut();
      setError(cause instanceof Error ? cause.message : 'could not load');
    }
  }, [token, onSignOut]);

  useEffect(() => {
    void load();
  }, [load]);

  async function decide(proof: PendingProof, accept: boolean) {
    let reason: string | undefined;
    if (!accept) {
      // Required, and shown to the tenant verbatim. Without it their next submission is a
      // guess at what was wrong.
      reason = window.prompt('Why is this being rejected? The pharmacy is shown this.') ?? '';
      if (!reason.trim()) return;
    }
    setBusyId(proof.id);
    try {
      await api.platform.decide(token, proof.id, { accept, reason });
      await load();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'could not record the decision');
    } finally {
      setBusyId(null);
    }
  }

  async function toggleSuspension(tenant: PlatformTenant) {
    const suspending = tenant.subscriptionState !== 'suspended';
    let reason: string | undefined;
    if (suspending) {
      reason = window.prompt('Why? The owner is shown this in their app.') ?? '';
      if (!reason.trim()) return;
    }
    setBusyId(tenant.id);
    try {
      await api.platform.setState(token, {
        tenantId: tenant.id,
        state: suspending ? 'suspended' : 'active',
        reason,
      });
      await load();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'could not change the subscription');
    } finally {
      setBusyId(null);
    }
  }

  const suspended = (tenants ?? []).filter((t) => t.subscriptionState === 'suspended').length;

  return (
    <div className="shell">
      <aside className="sidebar">
        <div className="brand">
          <div className="mark">P</div>
          <div>
            <b>PharmaEt</b>
            <span>Platform console</span>
          </div>
        </div>
        <div className="nav-group">Session</div>
        <button
          className="nav-item"
          onClick={() => {
            try {
              sessionStorage.removeItem('pharmaet.platform');
            } catch {
              /* nothing to clear */
            }
            onSignOut();
          }}
        >
          Sign out
        </button>
      </aside>

      <main className="main">
        <div className="page-head">
          <div>
            <h1>Payment verification</h1>
            <p>
              Every payment is checked by a person. Accepting extends the subscription; a rejection
              is shown to the pharmacy in their own words, so they can fix it.
            </p>
          </div>
          <button className="ghost" onClick={() => void load()}>
            Refresh
          </button>
        </div>

        {error && <div className="error">{error}</div>}

        <div className="stat-row">
          <div className="stat">
            <div className="label">Awaiting a decision</div>
            <div className={`value${proofs.length ? ' warn' : ''}`}>{proofs.length}</div>
            <div className="hint">oldest first</div>
          </div>
          <div className="stat">
            <div className="label">Pharmacies</div>
            <div className="value">{tenants?.length ?? '—'}</div>
            <div className="hint">{suspended} suspended</div>
          </div>
        </div>

        <div className="panel" style={{ marginBottom: 22 }}>
          <div className="panel-head">
            <h2>Queue</h2>
            <span className="note">Open the screenshot before deciding</span>
          </div>
          {proofs.length === 0 ? (
            <div className="empty">
              <strong>Nothing waiting</strong>
              Payment screenshots appear here as pharmacies submit them.
            </div>
          ) : (
            <table>
              <thead>
                <tr>
                  <th>Pharmacy</th>
                  <th>Submitted</th>
                  <th style={{ textAlign: 'right' }}>Amount</th>
                  <th>Screenshot</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {proofs.map((proof) => (
                  <tr key={proof.id}>
                    <td>
                      <strong>{proof.tenantName}</strong>
                      <div className="mono">{proof.tenantCode}</div>
                    </td>
                    <td>
                      {formatInstant(proof.submittedAt)}
                      <div className="mono">{relativeAge(proof.submittedAt)}</div>
                    </td>
                    <td className="num">{formatEtb(proof.amountSantim)}</td>
                    <td>
                      <a
                        href={api.platform.proofImageUrl(proof.id)}
                        target="_blank"
                        rel="noreferrer"
                      >
                        Open
                      </a>
                      {proof.note && <div className="mono">{proof.note}</div>}
                    </td>
                    <td>
                      <button
                        className="ghost"
                        disabled={busyId === proof.id}
                        onClick={() => void decide(proof, true)}
                      >
                        Accept
                      </button>{' '}
                      <button
                        className="ghost"
                        disabled={busyId === proof.id}
                        onClick={() => void decide(proof, false)}
                      >
                        Reject
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>

        <div className="panel">
          <div className="panel-head">
            <h2>Pharmacies</h2>
            <span className="note">
              Suspending blocks management changes only — sales already recorded still sync
            </span>
          </div>
          {tenants === null ? (
            <div className="empty">Loading…</div>
          ) : (
            <table>
              <thead>
                <tr>
                  <th>Pharmacy</th>
                  <th>Subscription</th>
                  <th>Paid until</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {tenants.map((tenant) => (
                  <tr key={tenant.id}>
                    <td>
                      <strong>{tenant.name}</strong>
                      <div className="mono">{tenant.code}</div>
                    </td>
                    <td>
                      {tenant.subscriptionState ?? '—'}
                      {tenant.suspendedReason && (
                        <div className="mono">{tenant.suspendedReason}</div>
                      )}
                    </td>
                    <td>
                      {tenant.currentPeriodEnd ? formatInstant(tenant.currentPeriodEnd) : '—'}
                    </td>
                    <td>
                      <button
                        className="ghost"
                        disabled={busyId === tenant.id}
                        onClick={() => void toggleSuspension(tenant)}
                      >
                        {tenant.subscriptionState === 'suspended' ? 'Reactivate' : 'Suspend'}
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>

        <p className="footnote">
          Suspension blocks branches, staff, products and prices. It never blocks a queued sale from
          syncing, a report from being read, or a payment proof from being sent — refusing those
          would destroy a pharmacy's records over a billing dispute (ADR-016).
        </p>
      </main>
    </div>
  );
}
