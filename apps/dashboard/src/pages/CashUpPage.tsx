import { useCallback, useEffect, useState } from 'react';
import { api, type ShiftReconciliation } from '../lib/api';
import { formatEtb, formatInstant, relativeAge } from '../lib/format';
import type { Session } from '../lib/session';

/**
 * Per-shift cash reconciliation (FR-8 report 1, AC-8.1).
 *
 * Vision §2.1.1 calls this the owner's primary anti-shrinkage control and the strongest
 * single reason to adopt the product, so this page is built to be *read at a glance by
 * somebody who suspects something*, not to be comprehensive.
 *
 * Three things it refuses to do:
 *   - hide an unreconciled shift. A till nobody counted is exactly what an owner needs to
 *     see, and omitting it would make the report quietly complicit;
 *   - net the variances. Four shifts 200 short each is not "balanced" because one was 800
 *     over; summing them away would conceal the pattern that matters;
 *   - silently reconcile the terminal's expected figure with the server's. When they
 *     differ, that gap is shown and explained (ADR-012 §3).
 */
export function CashUpPage({ session, onExpired }: { session: Session; onExpired: () => void }) {
  const [rows, setRows] = useState<ShiftReconciliation[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [fetchedAt, setFetchedAt] = useState(new Date().toISOString());

  const load = useCallback(async () => {
    try {
      setRows(await api.cashUps(session.accessToken));
      setFetchedAt(new Date().toISOString());
      setError(null);
    } catch (cause) {
      if (cause instanceof Error && (cause as { status?: number }).status === 401) {
        onExpired();
        return;
      }
      setError(cause instanceof Error ? cause.message : 'could not load');
    }
  }, [session.accessToken, onExpired]);

  useEffect(() => {
    void load();
  }, [load]);

  const reconciled = (rows ?? []).filter((r) => r.varianceSantim !== null);
  const unreconciled = (rows ?? []).filter((r) => r.varianceSantim === null && r.closedAt);
  const short = reconciled.filter((r) => (r.varianceSantim ?? 0) < 0);
  // Shortfalls are totalled on their own. Netting them against overages is how a pattern
  // of small, consistent losses disappears into a tidy zero.
  const shortTotal = short.reduce((sum, r) => sum + (r.varianceSantim ?? 0), 0);
  const stale = Date.now() - new Date(fetchedAt).getTime() > 120_000;

  return (
    <>
      <div className="page-head">
        <div>
          <h1>Cash reconciliation</h1>
          <p>
            Counted cash against what the system expected, per staff member, per shift. A shift that
            closed without a count appears here too — that is the one worth asking about.
          </p>
        </div>
        <span className={`currency-chip${stale ? ' stale' : ''}`}>
          <span className="dot" />
          as of {relativeAge(fetchedAt)}
        </span>
      </div>

      <div className="stat-row">
        <div className="stat">
          <div className="label">Shifts</div>
          <div className="value">{rows?.length ?? '—'}</div>
          <div className="hint">{reconciled.length} reconciled</div>
        </div>
        <div className="stat">
          <div className="label">Shifts short</div>
          <div className={`value${short.length ? ' warn' : ''}`}>{short.length}</div>
          <div className="hint">{short.length ? 'worth a conversation' : 'none'}</div>
        </div>
        <div className="stat">
          <div className="label">Total shortfall</div>
          <div className={`value${shortTotal < 0 ? ' warn' : ''}`}>{formatEtb(shortTotal)}</div>
          <div className="hint">shortfalls only, not netted against overages</div>
        </div>
        <div className="stat">
          <div className="label">Closed, not counted</div>
          <div className={`value${unreconciled.length ? ' warn' : ''}`}>{unreconciled.length}</div>
          <div className="hint">tills nobody reconciled</div>
        </div>
      </div>

      {error && <div className="error">{error}</div>}

      <div className="panel">
        <div className="panel-head">
          <h2>Shifts</h2>
          <button className="ghost" onClick={() => void load()}>
            Refresh
          </button>
        </div>
        {rows === null ? (
          <div className="empty">Loading…</div>
        ) : rows.length === 0 ? (
          <div className="empty">
            <strong>No shifts yet</strong>
            Open a till on a terminal and cash up at the end of it; the reconciliation arrives on
            the next sync.
          </div>
        ) : (
          <table>
            <thead>
              <tr>
                <th>Opened</th>
                <th>Status</th>
                <th style={{ textAlign: 'right' }}>Sales</th>
                <th style={{ textAlign: 'right' }}>Expected</th>
                <th style={{ textAlign: 'right' }}>Counted</th>
                <th style={{ textAlign: 'right' }}>Difference</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => (
                <tr key={row.shiftId}>
                  <td>
                    {formatInstant(row.openedAt)}
                    <div className="mono">{row.userId.slice(0, 8)}</div>
                  </td>
                  <td>
                    {row.varianceSantim !== null
                      ? 'Counted'
                      : row.closedAt
                        ? 'Closed, not counted'
                        : 'Open'}
                    {row.expectationGapSantim !== null && row.expectationGapSantim !== 0 && (
                      // The cashier counted against a different picture of the day than the
                      // server now has — almost always sales that were still queued. Shown,
                      // not smoothed away.
                      <div className="mono" title="Sales synced after the count was taken">
                        counted before {formatEtb(row.expectationGapSantim)} synced
                      </div>
                    )}
                  </td>
                  <td className="num">{row.saleCount}</td>
                  <td className="num">{formatEtb(row.serverExpectedSantim)}</td>
                  <td className="num">
                    {row.countedSantim === null ? '—' : formatEtb(row.countedSantim)}
                  </td>
                  <td className={`num${(row.varianceSantim ?? 0) < 0 ? ' neg' : ''}`}>
                    {row.varianceSantim === null ? '—' : formatEtb(row.varianceSantim)}
                    {row.note && <div className="mono">{row.note}</div>}
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
