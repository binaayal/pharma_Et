import { useEffect, useState } from 'react';
import { api, type PlatformTenant, type TenantDetail } from '../lib/api';
import { formatEtb, formatInstant, relativeAge, formatPhone } from '../lib/format';
import { StateBadge, TenantBadge, type PageProps } from './Console';

/** Screen 23 — every pharmacy, with plan and status. */
export function Tenants({ token, data, reload, fail, go }: PageProps) {
  const [query, setQuery] = useState('');
  const [creating, setCreating] = useState(false);
  const tenants = data.tenants ?? [];
  const q = query.trim().toLowerCase();
  const shown = q
    ? tenants.filter((t) =>
        [t.name, t.code, t.ownerName ?? ''].some((v) => v.toLowerCase().includes(q)),
      )
    : tenants;

  return (
    <>
      <div className="wtop">
        <div>
          <h3>Tenants</h3>
          <p>{data.tenants ? `${tenants.length} pharmacies` : 'Loading…'}</p>
        </div>
        <div className="sp">
          <button className="wbtn d" onClick={() => exportCsv(tenants)} disabled={!tenants.length}>
            Export
          </button>
          <button className="wbtn p" onClick={() => setCreating(true)}>
            ＋ New tenant
          </button>
        </div>
      </div>
      <div className="wpanel">
        <div className="wpanel-h">
          <div className="search">
            <span className="ic">⌕</span>
            <input
              placeholder="Search pharmacy or owner…"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
            />
          </div>
        </div>
        {shown.length === 0 ? (
          <div className="empty">{data.tenants ? 'No pharmacy matches.' : 'Loading…'}</div>
        ) : (
          <table>
            <thead>
              <tr>
                <th>Pharmacy</th>
                <th>Branches</th>
                <th>Owner</th>
                <th>Plan</th>
                <th>Status</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {shown.map((t) => (
                <tr key={t.id} className="pick" onClick={() => go({ page: 'tenant', id: t.id })}>
                  <td>
                    <b>{t.name}</b>
                    <div className="sub">{t.branchNames ?? t.code}</div>
                  </td>
                  <td>{t.branchCount}</td>
                  <td>{t.ownerName ?? '—'}</td>
                  <td>{t.priceSantim !== null ? `${formatEtb(t.priceSantim)}/mo` : '—'}</td>
                  <td>
                    <TenantBadge tenant={t} />
                  </td>
                  <td>›</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
      {creating && (
        <NewTenant
          onClose={() => setCreating(false)}
          onCreate={async (body) => {
            try {
              await api.onboard(token, body);
              setCreating(false);
              await reload();
            } catch (cause) {
              fail(cause);
            }
          }}
        />
      )}
    </>
  );
}

/** Screen 24 — one pharmacy: branches, their sync freshness, and the subscription. */
export function TenantDetailPage({ token, id, reload, fail, go }: PageProps & { id: string }) {
  const [tenant, setTenant] = useState<TenantDetail | null>(null);
  const [busy, setBusy] = useState(false);
  const [confirming, setConfirming] = useState<'deactivate' | 'reactivate' | null>(null);

  useEffect(() => {
    let live = true;
    api
      .tenant(token, id)
      .then((t) => live && setTenant(t))
      .catch(fail);
    return () => {
      live = false;
    };
  }, [token, id, fail]);

  async function toggle() {
    if (!tenant) return;
    const suspending = tenant.subscriptionState !== 'suspended';
    let reason: string | undefined;
    if (suspending) {
      reason = window.prompt('Why? The owner is shown this in their app.') ?? '';
      if (!reason.trim()) return;
    }
    setBusy(true);
    try {
      await api.setState(token, {
        tenantId: tenant.id,
        state: suspending ? 'suspended' : 'active',
        reason,
      });
      setTenant(await api.tenant(token, id));
      await reload();
    } catch (cause) {
      fail(cause);
    } finally {
      setBusy(false);
    }
  }

  async function changeAccount(action: 'deactivate' | 'reactivate', text: string) {
    if (!tenant) return;
    setBusy(true);
    try {
      if (action === 'deactivate') await api.deactivate(token, tenant.id, text);
      else await api.reactivate(token, tenant.id, text || undefined);
      setConfirming(null);
      setTenant(await api.tenant(token, id));
      await reload();
    } catch (cause) {
      fail(cause);
    } finally {
      setBusy(false);
    }
  }

  if (!tenant) return <div className="empty">Loading…</div>;
  const suspended = tenant.subscriptionState === 'suspended';
  const deactivated = tenant.status === 'deactivated';

  return (
    <>
      <div className="wtop">
        <div>
          <h3>
            <a
              style={{ color: 'var(--muted)', cursor: 'pointer' }}
              onClick={() => go({ page: 'tenants' })}
            >
              Tenants ›
            </a>{' '}
            {tenant.name} <TenantBadge tenant={tenant} />
          </h3>
          <p>
            Owner: {tenant.ownerName ?? '—'}
            {tenant.ownerPhone ? ` · ${formatPhone(tenant.ownerPhone)}` : ''} · code {tenant.code} ·
            onboarded {formatInstant(tenant.createdAt).replace(/ \d\d:\d\d$/, '')}
          </p>
        </div>
        <div className="sp">
          <button
            className={suspended ? 'wbtn a' : 'wbtn d'}
            disabled={busy}
            onClick={() => void toggle()}
          >
            {suspended ? 'Reactivate' : 'Suspend'}
          </button>
        </div>
      </div>
      {deactivated && (
        <div className="notice n-red">
          <div>
            <b>Account deactivated</b>
            {tenant.deactivatedAt
              ? ` on ${formatInstant(tenant.deactivatedAt).replace(/ \d\d:\d\d$/, '')}`
              : ''}
            : {tenant.deactivatedReason}. Every sign-in, sync and request from this pharmacy is
            refused until it is reactivated. Nothing has been deleted.
          </div>
        </div>
      )}
      {tenant.suspendedReason && (
        <div className="notice n-red">
          <div>
            <b>Suspended:</b> {tenant.suspendedReason}
          </div>
        </div>
      )}
      <div className="wgrid2">
        <div className="wpanel">
          <div className="wpanel-h">
            <b>Branches</b>
          </div>
          {tenant.branches.length === 0 ? (
            <div className="empty">No branch yet — the owner creates one on first sign-in.</div>
          ) : (
            <table>
              <thead>
                <tr>
                  <th>Branch</th>
                  <th>Staff</th>
                  <th>Last sync</th>
                </tr>
              </thead>
              <tbody>
                {tenant.branches.map((b) => (
                  <tr key={b.id}>
                    <td>
                      <b>{b.name}</b>
                      {b.address && <div className="sub">{b.address}</div>}
                    </td>
                    <td>{b.staffCount}</td>
                    <td>{b.lastSyncAt ? relativeAge(b.lastSyncAt) : 'never'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
        <div className="wpanel">
          <div className="wpanel-h">
            <b>Subscription</b>
          </div>
          <div className="pad">
            <div className="sl">
              <span>Plan</span>
              <b>
                {tenant.priceSantim !== null ? `${formatEtb(tenant.priceSantim)} / month` : '—'}
              </b>
            </div>
            <div className="sl">
              <span>State</span>
              <StateBadge state={tenant.subscriptionState} />
            </div>
            <div className="sl">
              <span>Renews</span>
              <b>
                {tenant.currentPeriodEnd
                  ? formatInstant(tenant.currentPeriodEnd).replace(/ \d\d:\d\d$/, '')
                  : '—'}
              </b>
            </div>
            <div className="sl">
              <span>Last payment</span>
              <b>
                {tenant.lastPaymentAt
                  ? `verified ${formatInstant(tenant.lastPaymentAt).replace(/ \d\d:\d\d$/, '')}`
                  : 'none yet'}
              </b>
            </div>
            <button
              className={suspended ? 'wbtn a' : 'wbtn r'}
              style={{ width: '100%', marginTop: 12 }}
              disabled={busy}
              onClick={() => void toggle()}
            >
              {suspended ? 'Reactivate tenant' : 'Suspend tenant'}
            </button>
          </div>
        </div>
      </div>
      <div className="wpanel danger">
        <div className="wpanel-h">
          <b>Account access</b>
        </div>
        <div className="pad">
          {deactivated ? (
            <>
              <p className="lead">
                Reactivating restores sign-in and sync exactly as they were. Sales the pharmacy's
                terminals queued in the meantime upload on their next sync.
              </p>
              <button
                className="wbtn a"
                disabled={busy}
                onClick={() => setConfirming('reactivate')}
              >
                Reactivate account
              </button>
            </>
          ) : (
            <>
              <p className="lead">
                For a pharmacy that breaks the terms of service. Unlike a suspension, which only
                pauses management changes, deactivation refuses <b>every</b> sign-in, sync and
                request, and signs out every terminal. No record is deleted.
              </p>
              <button
                className="wbtn r"
                disabled={busy}
                onClick={() => setConfirming('deactivate')}
              >
                Deactivate account…
              </button>
            </>
          )}
        </div>
      </div>
      {confirming && (
        <AccountDialog
          tenant={tenant}
          action={confirming}
          busy={busy}
          onClose={() => setConfirming(null)}
          onConfirm={(text) => void changeAccount(confirming, text)}
        />
      )}
      <p style={{ fontSize: 12, color: 'var(--muted)', marginTop: 16 }}>
        Last sync is when a branch's records last arrived — operational health, never what they
        said. Suspension blocks management changes only; queued sales still sync (ADR-016).
      </p>
    </>
  );
}

/**
 * Deactivation is confirmed by typing the pharmacy code — a click is too cheap for an action
 * that stops a business trading on our platform — and it must say why, because the owner is
 * shown the reason on their phone.
 */
export function AccountDialog({
  tenant,
  action,
  busy,
  onClose,
  onConfirm,
}: {
  tenant: PlatformTenant;
  action: 'deactivate' | 'reactivate';
  busy: boolean;
  onClose: () => void;
  onConfirm: (text: string) => void;
}) {
  const [text, setText] = useState('');
  const [typed, setTyped] = useState('');
  const deactivating = action === 'deactivate';
  const ready = deactivating
    ? text.trim().length >= 10 && typed.trim().toLowerCase() === tenant.code.toLowerCase()
    : true;

  return (
    <div className="scrim" onClick={onClose}>
      <div
        className="dialog"
        role="dialog"
        aria-label={deactivating ? 'Deactivate account' : 'Reactivate account'}
        onClick={(e) => e.stopPropagation()}
      >
        <h4>
          {deactivating ? 'Deactivate' : 'Reactivate'} {tenant.name}?
        </h4>
        {deactivating ? (
          <p className="lead">
            Every terminal is signed out and cannot sign back in, online or offline. Their records
            stay on the phones and on our server; nothing is deleted.
          </p>
        ) : (
          <p className="lead">Sign-in and sync are restored immediately.</p>
        )}
        <div className="fld">
          <label htmlFor="account-text">
            {deactivating ? 'Reason — shown to the owner' : 'Note (optional, kept in the audit)'}
          </label>
          <textarea
            id="account-text"
            rows={3}
            value={text}
            onChange={(e) => setText(e.target.value)}
          />
          {deactivating && <div className="hint">At least 10 characters.</div>}
        </div>
        {deactivating && (
          <div className="fld">
            <label htmlFor="account-code">
              Type the pharmacy code <b>{tenant.code}</b> to confirm
            </label>
            <input
              id="account-code"
              autoComplete="off"
              value={typed}
              onChange={(e) => setTyped(e.target.value)}
            />
          </div>
        )}
        <div className="btn-pair">
          <button className="wbtn d" onClick={onClose}>
            Cancel
          </button>
          <button
            className={deactivating ? 'wbtn r' : 'wbtn a'}
            disabled={!ready || busy}
            onClick={() => onConfirm(text.trim())}
          >
            {busy ? 'Saving…' : deactivating ? 'Deactivate account' : 'Reactivate account'}
          </button>
        </div>
      </div>
    </div>
  );
}

function NewTenant({
  onClose,
  onCreate,
}: {
  onClose: () => void;
  onCreate: (body: {
    name: string;
    code: string;
    ownerUsername: string;
    ownerDisplayName: string;
    ownerPin: string;
  }) => Promise<void>;
}) {
  const [f, setF] = useState({
    name: '',
    code: '',
    ownerDisplayName: '',
    ownerUsername: '',
    ownerPin: '',
  });
  const [busy, setBusy] = useState(false);
  const set = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement>) =>
    setF({ ...f, [k]: e.target.value });
  const ready =
    f.name.trim().length >= 2 &&
    f.code.trim().length >= 2 &&
    f.ownerDisplayName.trim() &&
    f.ownerUsername.trim().length >= 2 &&
    /^\d{4,8}$/.test(f.ownerPin);

  return (
    <div className="scrim" onClick={onClose}>
      <div className="dialog" onClick={(e) => e.stopPropagation()}>
        <h4>New tenant</h4>
        <p className="lead">For a pharmacy verified outside the sign-up queue.</p>
        <div className="fld">
          <label>Pharmacy name</label>
          <input value={f.name} onChange={set('name')} />
        </div>
        <div className="fld">
          <label>Pharmacy code</label>
          <input value={f.code} onChange={set('code')} />
        </div>
        <div className="fld">
          <label>Owner full name</label>
          <input value={f.ownerDisplayName} onChange={set('ownerDisplayName')} />
        </div>
        <div className="fld">
          <label>Owner username</label>
          <input value={f.ownerUsername} onChange={set('ownerUsername')} />
        </div>
        <div className="fld">
          <label>Starting PIN</label>
          <input inputMode="numeric" value={f.ownerPin} onChange={set('ownerPin')} />
          <div className="hint">4 to 8 digits, given to the owner in person or by phone.</div>
        </div>
        <div className="btn-pair">
          <button className="wbtn d" onClick={onClose}>
            Cancel
          </button>
          <button
            className="wbtn p"
            disabled={!ready || busy}
            onClick={async () => {
              setBusy(true);
              await onCreate(f);
              setBusy(false);
            }}
          >
            {busy ? 'Opening…' : 'Open account'}
          </button>
        </div>
      </div>
    </div>
  );
}

function exportCsv(tenants: PlatformTenant[]) {
  const cell = (v: unknown) => `"${String(v ?? '').replace(/"/g, '""')}"`;
  const lines = [
    ['Pharmacy', 'Code', 'Branches', 'Owner', 'Phone', 'Account', 'State', 'Paid until']
      .map(cell)
      .join(','),
    ...tenants.map((t) =>
      [
        t.name,
        t.code,
        t.branchCount,
        t.ownerName,
        t.ownerPhone,
        t.status,
        t.subscriptionState,
        t.currentPeriodEnd,
      ]
        .map(cell)
        .join(','),
    ),
  ];
  const url = URL.createObjectURL(new Blob([lines.join('\n')], { type: 'text/csv' }));
  const link = document.createElement('a');
  link.href = url;
  link.download = 'pharmaet-tenants.csv';
  link.click();
  URL.revokeObjectURL(url);
}
