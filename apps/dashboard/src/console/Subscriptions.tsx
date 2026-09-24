import { useState } from 'react';
import { api, type PlatformTenant } from '../lib/api';
import { formatInstant } from '../lib/format';
import { StateBadge, type PageProps } from './Console';

const DAY_MS = 24 * 3600 * 1000;

/** Screen 26 — the manual billing cycle: who is due, who is overdue, who is suspended. */
export function Subscriptions({ token, data, reload, fail, go }: PageProps) {
  const [busyId, setBusyId] = useState<string | null>(null);
  const tenants = data.tenants ?? [];
  const now = Date.now();
  const count = (s: PlatformTenant['subscriptionState']) =>
    tenants.filter((t) => t.subscriptionState === s).length;
  const dueWithin = (t: PlatformTenant, days: number) =>
    t.currentPeriodEnd !== null && new Date(t.currentPeriodEnd).getTime() - now <= days * DAY_MS;

  // Renewals first by date; suspended and pending ones need a person, so they come along.
  const renewals = tenants
    .filter((t) => t.subscriptionState !== 'active' || dueWithin(t, 14))
    .sort((a, b) => (a.currentPeriodEnd ?? '9').localeCompare(b.currentPeriodEnd ?? '9'));

  async function setState(t: PlatformTenant, state: 'active' | 'suspended') {
    let reason: string | undefined;
    if (state === 'suspended') {
      reason = window.prompt('Why? The owner is shown this in their app.') ?? '';
      if (!reason.trim()) return;
    }
    setBusyId(t.id);
    try {
      await api.setState(token, { tenantId: t.id, state, reason });
      await reload();
    } catch (cause) {
      fail(cause);
    } finally {
      setBusyId(null);
    }
  }

  function renews(t: PlatformTenant): string {
    if (!t.currentPeriodEnd) return 'not yet paid';
    const end = new Date(t.currentPeriodEnd).getTime();
    if (end < now) return `overdue ${Math.ceil((now - end) / DAY_MS)}d`;
    return formatInstant(t.currentPeriodEnd).replace(/ \d\d:\d\d$/, '');
  }

  return (
    <>
      <div className="wtop">
        <div>
          <h3>Subscriptions</h3>
          <p>ETB 1,000 / month · manual billing cycle</p>
        </div>
      </div>
      <div className="wtiles">
        <div className="wtile">
          <div className="k">Active</div>
          <div className="v" style={{ color: 'var(--green)' }}>
            {count('active')}
          </div>
        </div>
        <div className="wtile">
          <div className="k">Pending</div>
          <div className="v" style={{ color: 'var(--amber)' }}>
            {count('pending')}
          </div>
        </div>
        <div className="wtile">
          <div className="k">Suspended</div>
          <div className="v" style={{ color: 'var(--red)' }}>
            {count('suspended')}
          </div>
        </div>
        <div className="wtile">
          <div className="k">Due this week</div>
          <div className="v">
            {tenants.filter((t) => t.subscriptionState === 'active' && dueWithin(t, 7)).length}
          </div>
        </div>
      </div>
      <div className="wpanel">
        <div className="wpanel-h">
          <b>Renewals due</b>
        </div>
        {renewals.length === 0 ? (
          <div className="empty">Nothing due in the next two weeks.</div>
        ) : (
          <table>
            <thead>
              <tr>
                <th>Pharmacy</th>
                <th>Renews</th>
                <th>State</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {renewals.map((t) => (
                <tr key={t.id}>
                  <td>
                    <b
                      style={{ cursor: 'pointer' }}
                      onClick={() => go({ page: 'tenant', id: t.id })}
                    >
                      {t.name}
                    </b>
                  </td>
                  <td>{renews(t)}</td>
                  <td>
                    <StateBadge state={t.subscriptionState} />
                  </td>
                  <td style={{ textAlign: 'right' }}>
                    {t.subscriptionState === 'suspended' ? (
                      <button
                        className="wbtn a"
                        disabled={busyId === t.id}
                        onClick={() => void setState(t, 'active')}
                      >
                        Reactivate
                      </button>
                    ) : t.pendingProofs > 0 ? (
                      <button className="wbtn d" onClick={() => go({ page: 'payments' })}>
                        View proof
                      </button>
                    ) : (
                      <button
                        className="wbtn d"
                        disabled={busyId === t.id}
                        onClick={() => void setState(t, 'suspended')}
                      >
                        Suspend
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </>
  );
}
