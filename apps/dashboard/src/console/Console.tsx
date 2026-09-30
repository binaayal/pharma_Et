import { useCallback, useEffect, useState } from 'react';
import {
  api,
  isSessionExpired,
  type PendingProof,
  type PlatformTenant,
  type SignupRequest,
} from '../lib/api';
import { Overview } from './Overview';
import { Payments } from './Payments';
import { Requests } from './Requests';
import { Subscriptions } from './Subscriptions';
import { TenantDetailPage, Tenants } from './Tenants';

/**
 * The platform console — docs/prototype/index.html screens 20–26.
 *
 * Ours, not the pharmacies'. An owner runs their pharmacy from the mobile app; this is where
 * we review sign-ups, verify payments and manage subscriptions. A separate login with a
 * separate token type (BR-2.2), and nothing here reads a pharmacy's sales.
 */
export type Route =
  | { page: 'overview' }
  | { page: 'requests' }
  | { page: 'tenants' }
  | { page: 'tenant'; id: string }
  | { page: 'payments' }
  | { page: 'subscriptions' };

/** The app icon, rendered for the web by scripts/make-app-icons.py. */
const LOGO = `${import.meta.env.BASE_URL}icon-192.png`;

/**
 * Whether this browser has a platform session. The credential itself is an HttpOnly cookie
 * the page cannot read (docs/engineering/security.md), so the console asks the server —
 * `null` while it is asking.
 */
export function Console() {
  const [signedIn, setSignedIn] = useState<boolean | null>(null);

  useEffect(() => {
    let live = true;
    api
      .me()
      .then(() => live && setSignedIn(true))
      .catch(() => live && setSignedIn(false));
    return () => {
      live = false;
    };
  }, []);

  const signOut = useCallback(() => {
    setSignedIn(false);
    // Clears the cookie server-side; the page never held it, so there is nothing to wipe here.
    void api.logout().catch(() => undefined);
  }, []);

  if (signedIn === null) return <div className="empty">Loading…</div>;
  if (!signedIn) return <Login onSignedIn={() => setSignedIn(true)} />;
  return <Shell onSignOut={signOut} />;
}

/** Screen 20. */
function Login({ onSignedIn }: { onSignedIn: () => void }) {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    setBusy(true);
    setError(null);
    try {
      await api.login(email.trim(), password);
      onSignedIn();
    } catch {
      setError('Those details were not accepted.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="login-bg">
      <form className="login-card" onSubmit={(e) => void submit(e)}>
        <div className="brand">
          <img className="logo" src={LOGO} alt="" />
          <div>
            <b>PharmaEt</b>
            <span>Platform console</span>
          </div>
        </div>
        {error && <div className="error">{error}</div>}
        <div className="fld">
          <label htmlFor="email">Email</label>
          <input
            id="email"
            type="email"
            autoComplete="username"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
          />
        </div>
        <div className="fld">
          <label htmlFor="password">Password</label>
          <input
            id="password"
            type="password"
            autoComplete="current-password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
        </div>
        <button className="btn g" type="submit" disabled={busy || !email || !password}>
          {busy ? 'Signing in…' : 'Sign in'}
        </button>
        <div className="foot">Platform staff only · above tenant scope</div>
      </form>
    </div>
  );
}

/** Everything the pages share, loaded once and refreshed after every decision. */
export interface ConsoleData {
  tenants: PlatformTenant[] | null;
  proofs: PendingProof[];
  requests: SignupRequest[];
}

function Shell({ onSignOut }: { onSignOut: () => void }) {
  const [route, setRoute] = useState<Route>({ page: 'overview' });
  const [data, setData] = useState<ConsoleData>({ tenants: null, proofs: [], requests: [] });
  const [error, setError] = useState<string | null>(null);

  const reload = useCallback(async () => {
    try {
      const [tenants, proofs, requests] = await Promise.all([
        api.tenants(),
        api.pendingProofs(),
        api.signupRequests('pending'),
      ]);
      setData({ tenants, proofs, requests });
      setError(null);
    } catch (cause) {
      if (isSessionExpired(cause)) return onSignOut();
      setError(cause instanceof Error ? cause.message : 'could not load');
    }
  }, [onSignOut]);

  useEffect(() => {
    void reload();
  }, [reload]);

  /** Every action funnels its failure here; an ended session goes back to sign-in. */
  const fail = useCallback(
    (cause: unknown) => {
      if (isSessionExpired(cause)) return onSignOut();
      setError(cause instanceof Error ? cause.message : 'that did not work');
    },
    [onSignOut],
  );

  const nav = (target: Route['page'], label: string, count?: number) => (
    <a
      className={
        route.page === target || (target === 'tenants' && route.page === 'tenant') ? 'on' : ''
      }
      onClick={() => setRoute({ page: target } as Route)}
    >
      {label}
      {count ? <span className="ct badge b-amber">{count}</span> : null}
    </a>
  );

  const props = { data, reload, fail, go: setRoute };

  return (
    <div className="web">
      <nav className="wnav">
        <div className="wb">
          <img className="logo" src={LOGO} alt="" />
          <b>PharmaEt</b>
        </div>
        {nav('overview', '▤ Overview')}
        {nav('requests', '✋ Sign-up requests', data.requests.length)}
        {nav('tenants', '▦ Tenants')}
        {nav('payments', '⛨ Payments', data.proofs.length)}
        {nav('subscriptions', '◷ Subscriptions')}
        <div className="foot">
          <a onClick={onSignOut}>Sign out</a>
        </div>
      </nav>
      <main className="wmain">
        {error && <div className="error">{error}</div>}
        {route.page === 'overview' && <Overview {...props} />}
        {route.page === 'requests' && <Requests {...props} />}
        {route.page === 'tenants' && <Tenants {...props} />}
        {route.page === 'tenant' && <TenantDetailPage {...props} id={route.id} />}
        {route.page === 'payments' && <Payments {...props} />}
        {route.page === 'subscriptions' && <Subscriptions {...props} />}
      </main>
    </div>
  );
}

export interface PageProps {
  data: ConsoleData;
  reload: () => Promise<void>;
  fail: (cause: unknown) => void;
  go: (route: Route) => void;
}

/** The subscription state as a badge, in the prototype's colours. */
export function StateBadge({ state }: { state: PlatformTenant['subscriptionState'] }) {
  if (state === 'active') return <span className="badge b-green">Active</span>;
  if (state === 'suspended') return <span className="badge b-red">Suspended</span>;
  if (state === 'pending') return <span className="badge b-amber">Pending pay</span>;
  return <span className="badge b-grey">No subscription</span>;
}

/**
 * The subscription badge, unless the account itself is deactivated (ADR-025) — which
 * outranks any billing state, because nothing the pharmacy does works until it is lifted.
 */
export function TenantBadge({ tenant }: { tenant: PlatformTenant }) {
  if (tenant.status === 'deactivated') return <span className="badge b-red">Deactivated</span>;
  return <StateBadge state={tenant.subscriptionState} />;
}
