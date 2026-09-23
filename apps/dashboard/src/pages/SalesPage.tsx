import { useCallback, useEffect, useState } from 'react';
import { api, type OversellRow, type SyncedSale } from '../lib/api';
import { formatEtb, formatInstant, relativeAge } from '../lib/format';
import type { Session } from '../lib/session';

/**
 * The Phase 0 dashboard view: proof that a sale rung up on a terminal — possibly offline,
 * possibly days ago — arrived exactly once (docs/04 §13).
 *
 * It shows both `soldAt` and `syncedAt`, and the gap between them, because that gap IS the
 * product: a wide gap means the counter kept working through an outage, which is the thing
 * this system promises and the thing an owner will want to see with their own eyes.
 */
export function SalesPage({ session, onExpired }: { session: Session; onExpired: () => void }) {
  const [sales, setSales] = useState<SyncedSale[] | null>(null);
  const [oversells, setOversells] = useState<OversellRow[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [fetchedAt, setFetchedAt] = useState<string>(new Date().toISOString());

  const load = useCallback(async () => {
    try {
      const [salesResult, oversellResult] = await Promise.all([
        api.sales(session.accessToken),
        api.oversells(session.accessToken),
      ]);
      setSales(salesResult);
      setOversells(oversellResult);
      setFetchedAt(new Date().toISOString());
      setError(null);
    } catch (cause) {
      if (cause instanceof Error && 'status' in cause && (cause as { status: number }).status === 401) {
        onExpired();
        return;
      }
      setError(cause instanceof Error ? cause.message : 'could not load');
    }
  }, [session.accessToken, onExpired]);

  useEffect(() => {
    void load();
  }, [load]);

  const total = (sales ?? []).reduce((sum, sale) => sum + sale.totalSantim, 0);
  const stale = Date.now() - new Date(fetchedAt).getTime() > 120_000;

  return (
    <>
      <div className="page-head">
        <div>
          <h1>Synced sales</h1>
          <p>
            Every sale that has reached the server, with the gap between when it was rung up
            and when it arrived. A wide gap is the offline window doing its job, not a fault.
          </p>
        </div>
        {/* Reports reflect synced data, so the view states its own currency (BR-8.1). */}
        <span className={`currency-chip${stale ? ' stale' : ''}`}>
          <span className="dot" />
          as of {relativeAge(fetchedAt)}
        </span>
      </div>

      <div className="stat-row">
        <div className="stat">
          <div className="label">Sales synced</div>
          <div className="value">{sales?.length ?? '—'}</div>
          <div className="hint">across all branches</div>
        </div>
        <div className="stat">
          <div className="label">Value</div>
          <div className="value">{formatEtb(total)}</div>
          <div className="hint">sum of synced sale totals</div>
        </div>
        <div className="stat">
          <div className="label">Oversells</div>
          <div className={`value${oversells.length ? ' warn' : ''}`}>{oversells.length}</div>
          <div className="hint">
            {oversells.length ? 'needs a physical count' : 'stock reconciles'}
          </div>
        </div>
      </div>

      {error && <div className="error">{error}</div>}

      <div className="panel" style={{ marginBottom: 22 }}>
        <div className="panel-head">
          <h2>Recent sales</h2>
          <button className="ghost" onClick={() => void load()}>
            Refresh
          </button>
        </div>
        {sales === null ? (
          <div className="empty">Loading…</div>
        ) : sales.length === 0 ? (
          <div className="empty">
            <strong>Nothing has synced yet</strong>
            Ring up a sale on a terminal — offline is fine — and it will appear here on its
            next reconnect.
          </div>
        ) : (
          <table>
            <thead>
              <tr>
                <th>Branch</th>
                <th>Sold at</th>
                <th>Synced at</th>
                <th style={{ textAlign: 'right' }}>Lines</th>
                <th style={{ textAlign: 'right' }}>Total</th>
              </tr>
            </thead>
            <tbody>
              {sales.map((sale) => (
                <tr key={sale.id}>
                  <td>{sale.branchName}</td>
                  <td>{formatInstant(sale.soldAt)}</td>
                  <td>
                    {formatInstant(sale.syncedAt)}
                    <div className="mono">{relativeAge(sale.syncedAt)}</div>
                  </td>
                  <td className="num">{sale.lineCount}</td>
                  <td className="num">{formatEtb(sale.totalSantim)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      <div className="panel">
        <div className="panel-head">
          <h2>Oversells</h2>
          <span className="note">
            Stock sold below zero. Never blocked at the counter — recorded here instead
            (BR-3.2).
          </span>
        </div>
        {oversells.length === 0 ? (
          <div className="empty">
            <strong>No oversells</strong>
            Recorded stock covers everything sold.
          </div>
        ) : (
          <table>
            <thead>
              <tr>
                <th>Observed</th>
                <th>Product</th>
                <th style={{ textAlign: 'right' }}>Resulting stock</th>
              </tr>
            </thead>
            <tbody>
              {oversells.map((row) => (
                <tr key={row.id}>
                  <td>{formatInstant(row.observedAt)}</td>
                  <td className="mono">{row.productId}</td>
                  <td className="num neg">{row.resultingQty}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </>
  );
}
