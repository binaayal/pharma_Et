import { useCallback, useEffect, useState } from 'react';
import { api, type SalesSummary } from '../lib/api';
import { formatEtb, formatInstant, relativeAge } from '../lib/format';
import type { Session } from '../lib/session';

/** Yesterday..today as ISO calendar dates; the window is half-open, so `to` is exclusive. */
function defaultWindow(): { from: string; to: string } {
  const today = new Date();
  const iso = (d: Date) => d.toISOString().slice(0, 10);
  const start = new Date(today);
  start.setUTCDate(start.getUTCDate() - 6);
  const end = new Date(today);
  end.setUTCDate(end.getUTCDate() + 1);
  return { from: iso(start), to: iso(end) };
}

/**
 * Daily sales summary (FR-8 report 2, AC-8.2).
 *
 * Per-branch and consolidated together, because the owner's question is almost never one or
 * the other — it is "how did we do, and which shop is the reason". Cash is shown separately
 * from other tenders: the cash figure is the one that reconciles against a drawer, and
 * conflating them would make this page disagree with the cash-up for a reason nobody could
 * find.
 */
export function SalesSummaryPage({
  session,
  onExpired,
}: {
  session: Session;
  onExpired: () => void;
}) {
  const [window, setWindow] = useState(defaultWindow);
  const [data, setData] = useState<SalesSummary | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setData(await api.salesSummary(session.accessToken, window.from, window.to));
      setError(null);
    } catch (cause) {
      if (cause instanceof Error && (cause as { status?: number }).status === 401) {
        onExpired();
        return;
      }
      setError(cause instanceof Error ? cause.message : 'could not load');
    }
  }, [session.accessToken, window, onExpired]);

  useEffect(() => {
    void load();
  }, [load]);

  const total = data?.total;

  return (
    <>
      <div className="page-head">
        <div>
          <h1>Sales summary</h1>
          <p>
            Consolidated and per branch. Cash is shown separately because that is the figure a
            drawer is counted against.
          </p>
        </div>
        {/* Reports reflect synced data (BR-8.1). On this product that caveat is real: a
            branch offline since Tuesday shows a plausible, complete-looking, wrong total. */}
        {data?.lastSyncedAt && (
          <span className="currency-chip">
            <span className="dot" />
            newest sale synced {relativeAge(data.lastSyncedAt)}
          </span>
        )}
      </div>

      <div className="panel" style={{ marginBottom: 18 }}>
        <div className="panel-head">
          <h2>Window</h2>
          <span className="note">
            {window.from} to {window.to} (end exclusive)
          </span>
        </div>
        <div style={{ display: 'flex', gap: 12, padding: 14, flexWrap: 'wrap' }}>
          <div>
            <label htmlFor="from">From</label>
            <input
              id="from"
              type="date"
              value={window.from}
              onChange={(e) => setWindow((w) => ({ ...w, from: e.target.value }))}
            />
          </div>
          <div>
            <label htmlFor="to">To</label>
            <input
              id="to"
              type="date"
              value={window.to}
              onChange={(e) => setWindow((w) => ({ ...w, to: e.target.value }))}
            />
          </div>
        </div>
      </div>

      {error && <div className="error">{error}</div>}

      <div className="stat-row">
        <div className="stat">
          <div className="label">Sales</div>
          <div className="value">{total?.saleCount ?? '—'}</div>
          <div className="hint">{total?.itemsSold ?? 0} items</div>
        </div>
        <div className="stat">
          <div className="label">Gross</div>
          <div className="value">{formatEtb(total?.grossSantim ?? 0)}</div>
          <div className="hint">all branches</div>
        </div>
        <div className="stat">
          <div className="label">Cash</div>
          <div className="value">{formatEtb(total?.cashSantim ?? 0)}</div>
          <div className="hint">reconciles against the drawer</div>
        </div>
        <div className="stat">
          <div className="label">Other tender</div>
          <div className="value">{formatEtb(total?.otherTenderSantim ?? 0)}</div>
          <div className="hint">recorded, not settled</div>
        </div>
      </div>

      <div className="panel">
        <div className="panel-head">
          <h2>By branch</h2>
          <button className="ghost" onClick={() => void load()}>
            Refresh
          </button>
        </div>
        {data === null ? (
          <div className="empty">Loading…</div>
        ) : data.branches.length === 0 ? (
          <div className="empty">
            <strong>No sales in this window</strong>
            Either nothing was sold, or the terminals have not synced yet.
          </div>
        ) : (
          <table>
            <thead>
              <tr>
                <th>Branch</th>
                <th style={{ textAlign: 'right' }}>Sales</th>
                <th style={{ textAlign: 'right' }}>Items</th>
                <th style={{ textAlign: 'right' }}>Cash</th>
                <th style={{ textAlign: 'right' }}>Other</th>
                <th style={{ textAlign: 'right' }}>Gross</th>
              </tr>
            </thead>
            <tbody>
              {data.branches.map((b) => (
                <tr key={b.branchId}>
                  <td>{b.branchName}</td>
                  <td className="num">{b.saleCount}</td>
                  <td className="num">{b.itemsSold}</td>
                  <td className="num">{formatEtb(b.cashSantim)}</td>
                  <td className="num">{formatEtb(b.otherTenderSantim)}</td>
                  <td className="num">{formatEtb(b.grossSantim)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      {data?.lastSyncedAt && (
        <p className="footnote">
          Figures cover sales that have reached the server. Newest arrived{' '}
          {formatInstant(data.lastSyncedAt)}.
        </p>
      )}
    </>
  );
}
