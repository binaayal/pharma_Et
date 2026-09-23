import { useCallback, useEffect, useState } from 'react';
import { api, type AuditEntry } from '../lib/api';
import { formatEtb, formatInstant, relativeAge, type Calendar } from '../lib/format';
import type { Session } from '../lib/session';

/**
 * The action audit trail (Vision §2.1.1, FR-6 generalized).
 *
 * Vision calls owner trust in staff "the product". This is where that is cashed: who changed
 * a price, who added a user, who deactivated one — and when.
 *
 * It renders **what changed, not that something changed**. "Price updated" tells an owner
 * nothing they can act on; "Amoxicillin 250mg, 4.50 → 18.50 ETB" is a question they can ask
 * somebody. Every entry is built to be read that way.
 */
export function AuditPage({
  session,
  onExpired,
  calendar,
}: {
  session: Session;
  onExpired: () => void;
  calendar: Calendar;
}) {
  const [rows, setRows] = useState<AuditEntry[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [fetchedAt, setFetchedAt] = useState(new Date().toISOString());

  const load = useCallback(async () => {
    try {
      setRows(await api.audit(session.accessToken));
      setFetchedAt(new Date().toISOString());
      setError(null);
    } catch (cause) {
      const status = (cause as { status?: number }).status;
      if (status === 401) return onExpired();
      if (status === 403) {
        // The FR-2 matrix grants the audit trail to the owner alone. Saying so beats an
        // empty table, which would read as "nobody has done anything".
        setError('Only the owner may read the audit trail.');
        setRows([]);
        return;
      }
      setError(cause instanceof Error ? cause.message : 'could not load');
    }
  }, [session.accessToken, onExpired]);

  useEffect(() => {
    void load();
  }, [load]);

  return (
    <>
      <div className="page-head">
        <div>
          <h1>Audit trail</h1>
          <p>
            Who changed what, and when. Append-only — entries cannot be edited or removed, by
            anyone, including us.
          </p>
        </div>
        <span className="currency-chip">
          <span className="dot" />
          as of {relativeAge(fetchedAt)}
        </span>
      </div>

      {error && <div className="error">{error}</div>}

      <div className="panel">
        <div className="panel-head">
          <h2>Recent activity</h2>
          <button className="ghost" onClick={() => void load()}>
            Refresh
          </button>
        </div>
        {rows === null ? (
          <div className="empty">Loading…</div>
        ) : rows.length === 0 ? (
          <div className="empty">
            <strong>Nothing recorded yet</strong>
            Price changes, staff changes and branch changes appear here as they happen.
          </div>
        ) : (
          <table>
            <thead>
              <tr>
                <th>When</th>
                <th>What</th>
                <th>Detail</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => (
                <tr key={row.id}>
                  <td>
                    {formatInstant(row.occurredAt, calendar)}
                    <div className="mono">{relativeAge(row.occurredAt)}</div>
                  </td>
                  <td>{label(row.eventType)}</td>
                  <td>
                    {detail(row)}
                    <div className="mono">by {row.actorId.slice(0, 8)}</div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      <p className="footnote">
        The log is append-only at the database, not by convention: update, delete and truncate are
        refused outright, including for the database owner. A correction is a new entry, never an
        edit — so a mistake stays visible alongside its fix.
      </p>
    </>
  );
}

function label(eventType: string): string {
  const labels: Record<string, string> = {
    'audit.price_changed': 'Price changed',
    'audit.product_created': 'Product added',
    'audit.user_created': 'Staff added',
    'audit.user_deactivated': 'Staff deactivated',
    'audit.branch_created': 'Branch added',
    'audit.branch_updated': 'Branch updated',
    'audit.stock_adjusted': 'Stock adjusted',
  };
  return labels[eventType] ?? eventType;
}

/** What changed, in the terms somebody would ask about it. */
function detail(row: AuditEntry) {
  const p = row.payload as Record<string, string | number | undefined>;

  if (row.eventType === 'audit.price_changed') {
    const from = Number(p.previousPriceSantim ?? 0);
    const to = Number(p.priceSantim ?? 0);
    const rise = to > from;
    return (
      <>
        <strong>{p.productName}</strong>{' '}
        <span style={{ color: rise ? 'var(--amber)' : 'var(--muted)' }}>
          {formatEtb(from)} → {formatEtb(to)}
        </span>
      </>
    );
  }
  if (row.eventType === 'audit.user_created' || row.eventType === 'audit.user_deactivated') {
    return (
      <>
        <strong>{p.username}</strong> · {p.role}
      </>
    );
  }
  if (row.eventType === 'audit.product_created') {
    return (
      <>
        <strong>{p.name}</strong> at {formatEtb(Number(p.priceSantim ?? 0))}
      </>
    );
  }
  if (row.eventType.startsWith('audit.branch')) {
    return <strong>{String(p.name ?? '')}</strong>;
  }
  return <span className="mono">{JSON.stringify(p)}</span>;
}
