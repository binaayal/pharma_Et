import { useCallback, useEffect, useState } from 'react';
import { api, type StockReport, type StockRow } from '../lib/api';
import { formatDateOnly, formatEtb, relativeAge, type Calendar } from '../lib/format';
import type { Session } from '../lib/session';

const WINDOWS = [30, 90, 180, 365];

/**
 * Stock and expiry alerting (FR-8 report 3, BR-3.4).
 *
 * Vision §1.1 names the losses this is aimed at: dead stock and drugs expiring on the shelf
 * and written off. So the page leads with **what it is worth**, not with an inventory
 * listing — an owner who has to compute the cost themselves will not look twice.
 *
 * Oversold batches sort above everything. A negative count means the shelf and the system
 * disagree, and until someone has counted, every expiry decision resting on that number is
 * guesswork.
 */
export function StockPage({
  session,
  onExpired,
  calendar,
}: {
  session: Session;
  onExpired: () => void;
  calendar: Calendar;
}) {
  const [days, setDays] = useState(90);
  const [data, setData] = useState<StockReport | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setData(await api.stock(session.accessToken, days));
      setError(null);
    } catch (cause) {
      if (cause instanceof Error && (cause as { status?: number }).status === 401) {
        onExpired();
        return;
      }
      setError(cause instanceof Error ? cause.message : 'could not load');
    }
  }, [session.accessToken, days, onExpired]);

  useEffect(() => {
    void load();
  }, [load]);

  const summary = data?.summary;

  return (
    <>
      <div className="page-head">
        <div>
          <h1>Stock &amp; expiry</h1>
          <p>
            What is about to be lost, and what it is worth. Valued at selling price — the question
            is how much is about to be thrown away, and cost price understates it.
          </p>
        </div>
        {data && (
          <span className="currency-chip">
            <span className="dot" />
            as of {relativeAge(data.asOf)}
          </span>
        )}
      </div>

      <div className="stat-row">
        <div className="stat">
          <div className="label">Expiring within {days}d</div>
          <div className={`value${summary?.expiringBatches ? ' warn' : ''}`}>
            {summary?.expiringBatches ?? '—'}
          </div>
          <div className="hint">{formatEtb(summary?.expiringValueSantim ?? 0)} at risk</div>
        </div>
        <div className="stat">
          <div className="label">Already expired</div>
          <div className={`value${summary?.expiredBatches ? ' warn' : ''}`}>
            {summary?.expiredBatches ?? '—'}
          </div>
          <div className="hint">{formatEtb(summary?.expiredValueSantim ?? 0)} written off</div>
        </div>
        <div className="stat">
          <div className="label">Oversold</div>
          <div className={`value${summary?.oversoldBatches ? ' warn' : ''}`}>
            {summary?.oversoldBatches ?? '—'}
          </div>
          <div className="hint">
            {summary?.oversoldBatches ? 'needs a physical count' : 'counts agree'}
          </div>
        </div>
      </div>

      {error && <div className="error">{error}</div>}

      <div className="panel">
        <div className="panel-head">
          <h2>Batches needing attention</h2>
          <div style={{ display: 'flex', gap: 6 }}>
            {WINDOWS.map((w) => (
              <button
                key={w}
                className="ghost"
                style={
                  w === days
                    ? { borderColor: 'var(--green)', color: 'var(--green)', fontWeight: 700 }
                    : undefined
                }
                onClick={() => setDays(w)}
              >
                {w}d
              </button>
            ))}
          </div>
        </div>
        {data === null ? (
          <div className="empty">Loading…</div>
        ) : data.rows.length === 0 ? (
          <div className="empty">
            <strong>Nothing needs attention</strong>
            No batch expires within {days} days, and every count is non-negative.
          </div>
        ) : (
          <table>
            <thead>
              <tr>
                <th>Product</th>
                <th>Branch</th>
                <th>Lot</th>
                <th>Expires</th>
                <th style={{ textAlign: 'right' }}>On hand</th>
                <th style={{ textAlign: 'right' }}>Value</th>
              </tr>
            </thead>
            <tbody>
              {data.rows.map((row) => (
                <tr key={row.batchId}>
                  <td>
                    {row.productName}
                    <div className="mono">
                      <StatusTag row={row} />
                    </div>
                  </td>
                  <td>{row.branchName}</td>
                  <td className="mono">{row.lotNo}</td>
                  <td>
                    {formatDateOnly(row.expiryDate, calendar)}
                    <div className="mono">
                      {row.daysToExpiry < 0
                        ? `${Math.abs(row.daysToExpiry)}d ago`
                        : `in ${row.daysToExpiry}d`}
                    </div>
                  </td>
                  <td className={`num${row.qtyOnHand < 0 ? ' neg' : ''}`}>
                    {row.qtyOnHand} {row.unit}
                  </td>
                  <td className="num">{formatEtb(row.valueSantim)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      <p className="footnote">
        Controlled substances are not listed. Their stock is a projection over the append-only
        ledger (BR-3.3), which arrives with the compliance phase — showing them from any other
        source would be inventing a number.
      </p>
    </>
  );
}

function StatusTag({ row }: { row: StockRow }) {
  const label =
    row.status === 'oversold'
      ? 'oversold — count the shelf'
      : row.status === 'expired'
        ? 'expired'
        : 'expiring';
  const color =
    row.status === 'oversold'
      ? 'var(--red)'
      : row.status === 'expired'
        ? 'var(--red)'
        : 'var(--amber)';
  return <span style={{ color, fontWeight: 700 }}>{label}</span>;
}
