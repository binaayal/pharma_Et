import { formatEtb, formatPhone } from '../lib/format';
import { StateBadge, type PageProps } from './Console';

const WEEK_MS = 7 * 24 * 3600 * 1000;

/** Screen 21 — platform health at a glance. Cross-tenant counts only (ADR-003). */
export function Overview({ data, go }: PageProps) {
  const tenants = data.tenants ?? [];
  const active = tenants.filter((t) => t.subscriptionState === 'active');
  const now = Date.now();
  const newThisMonth = tenants.filter(
    (t) =>
      new Date(t.createdAt).getMonth() === new Date().getMonth() &&
      new Date(t.createdAt).getFullYear() === new Date().getFullYear(),
  ).length;
  const recurring = active.reduce((sum, t) => sum + (t.priceSantim ?? 0), 0);
  const recent = tenants
    .filter((t) => now - new Date(t.createdAt).getTime() <= WEEK_MS)
    .sort((a, b) => b.createdAt.localeCompare(a.createdAt));

  return (
    <>
      <div className="wtop">
        <div>
          <h3>Overview</h3>
          <p>Platform health at a glance</p>
        </div>
      </div>
      <div className="wtiles">
        <div className="wtile">
          <div className="k">Active tenants</div>
          <div className="v">{data.tenants ? active.length : '—'}</div>
          <div className="k2" style={{ color: 'var(--green)' }}>
            ▲ {newThisMonth} this month
          </div>
        </div>
        <div
          className="wtile"
          style={{ cursor: 'pointer' }}
          onClick={() => go({ page: 'requests' })}
        >
          <div className="k">Sign-up requests</div>
          <div className="v" style={{ color: data.requests.length ? 'var(--amber)' : undefined }}>
            {data.requests.length}
          </div>
          <div className="k2">awaiting review</div>
        </div>
        <div
          className="wtile"
          style={{ cursor: 'pointer' }}
          onClick={() => go({ page: 'payments' })}
        >
          <div className="k">Pending payments</div>
          <div className="v" style={{ color: data.proofs.length ? 'var(--amber)' : undefined }}>
            {data.proofs.length}
          </div>
          <div className="k2">awaiting verification</div>
        </div>
        <div className="wtile">
          <div className="k">MRR</div>
          <div className="v">
            {formatEtb(recurring).replace(' ETB', '')} <small>ETB</small>
          </div>
          <div className="k2">active subscriptions</div>
        </div>
      </div>

      <div className="wpanel">
        <div className="wpanel-h">
          <b>Recently onboarded</b>
          <span className="sp" />
          <span className="badge b-grey">last 7 days</span>
        </div>
        {recent.length === 0 ? (
          <div className="empty">No pharmacy was opened in the last 7 days.</div>
        ) : (
          <table>
            <thead>
              <tr>
                <th>Pharmacy</th>
                <th>Branches</th>
                <th>Owner</th>
                <th>Status</th>
              </tr>
            </thead>
            <tbody>
              {recent.map((t) => (
                <tr key={t.id} className="pick" onClick={() => go({ page: 'tenant', id: t.id })}>
                  <td>
                    <b>{t.name}</b>
                  </td>
                  <td>{t.branchCount}</td>
                  <td>
                    {t.ownerName ?? '—'}
                    {t.ownerPhone && <div className="sub">{formatPhone(t.ownerPhone)}</div>}
                  </td>
                  <td>
                    <StateBadge state={t.subscriptionState} />
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
