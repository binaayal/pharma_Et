import { useEffect, useState } from 'react';
import { api } from '../lib/api';
import { formatEtb, formatInstant } from '../lib/format';
import type { PageProps } from './Console';

/**
 * Screen 25 — manual payment verification (V1: no Telebirr/CBE integration).
 *
 * The screenshot is shown inline, next to the two decisions: the reviewer is judging an
 * image, and making them open it somewhere else is how proofs get approved unseen.
 */
export function Payments({ data, reload, fail }: PageProps) {
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [image, setImage] = useState<string | null>(null);
  const [imageError, setImageError] = useState(false);
  const [busy, setBusy] = useState(false);
  // ADR-028: screenshots live in the database for now, so each one is deleted once decided
  // unless the reviewer says otherwise — the decision and the amount are the record.
  const [deleteAfter, setDeleteAfter] = useState(true);
  const [stored, setStored] = useState<{ count: number; bytes: number } | null>(null);

  async function loadStored() {
    try {
      const rows = await api.decidedImages();
      setStored({ count: rows.length, bytes: rows.reduce((sum, r) => sum + r.byteSize, 0) });
    } catch {
      setStored(null);
    }
  }

  useEffect(() => {
    void loadStored();
  }, [data.proofs.length]);

  async function purge() {
    setBusy(true);
    try {
      await api.purgeDecidedImages();
      await loadStored();
    } catch (cause) {
      fail(cause);
    } finally {
      setBusy(false);
    }
  }

  const selected = data.proofs.find((p) => p.id === selectedId) ?? data.proofs[0] ?? null;

  useEffect(() => {
    if (!selected) return;
    let live = true;
    let url: string | null = null;
    setImage(null);
    setImageError(false);
    api
      .proofImage(selected.id)
      .then((u) => {
        url = u;
        if (live) setImage(u);
      })
      .catch(() => live && setImageError(true));
    return () => {
      live = false;
      if (url) URL.revokeObjectURL(url);
    };
  }, [selected?.id]); // eslint-disable-line react-hooks/exhaustive-deps

  async function decide(accept: boolean) {
    if (!selected) return;
    let reason: string | undefined;
    if (!accept) {
      // Shown to the pharmacy verbatim — without it their next submission is a guess.
      reason = window.prompt('Why is this being rejected? The pharmacy is shown this.') ?? '';
      if (!reason.trim()) return;
    }
    setBusy(true);
    try {
      await api.decideProof(selected.id, { accept, reason, deleteImage: deleteAfter });
      setSelectedId(null);
      await reload();
    } catch (cause) {
      fail(cause);
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <div className="wtop">
        <div>
          <h3>Payment verification</h3>
          <p>Manual screenshot approval — V1 (Telebirr/CBE integration deferred)</p>
        </div>
        {stored && stored.count > 0 && (
          <div className="sp">
            <button className="wbtn d" disabled={busy} onClick={() => void purge()}>
              Free space: delete {stored.count} decided screenshot{stored.count === 1 ? '' : 's'} (
              {Math.ceil(stored.bytes / 1024)} KB)
            </button>
          </div>
        )}
      </div>
      <div className="wgrid2">
        <div className="wpanel">
          <div className="wpanel-h">
            <b>Awaiting review</b>
            <span className="sp" />
            <span className="badge b-amber">{data.proofs.length}</span>
          </div>
          {data.proofs.length === 0 ? (
            <div className="empty">
              Nothing waiting. Proofs arrive from the app's payment screen.
            </div>
          ) : (
            <table>
              <tbody>
                {data.proofs.map((p, i) => (
                  <tr
                    key={p.id}
                    className={`pick${selected?.id === p.id ? ' sel' : ''}`}
                    onClick={() => setSelectedId(p.id)}
                  >
                    <td>
                      <b>{p.tenantName}</b>
                      <div className="sub">{p.tenantCode}</div>
                    </td>
                    <td>{formatEtb(p.amountSantim)}</td>
                    <td>
                      {selected?.id === p.id || (!selectedId && i === 0) ? (
                        <span className="badge b-amber">Review</span>
                      ) : (
                        <span className="badge b-grey">Queued</span>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>

        {selected && (
          <div className="wpanel">
            <div className="wpanel-h">
              <b>{selected.tenantName} · proof</b>
            </div>
            <div className="pad">
              <div className="proof-img">
                {image ? (
                  <img src={image} alt={`Payment screenshot from ${selected.tenantName}`} />
                ) : imageError ? (
                  'The screenshot could not be loaded.'
                ) : (
                  'Loading screenshot…'
                )}
              </div>
              <div className="sl" style={{ marginTop: 8 }}>
                <span>Amount</span>
                <b>{formatEtb(selected.amountSantim)}</b>
              </div>
              {selected.note && (
                <div className="sl">
                  <span>Reference</span>
                  <b>{selected.note}</b>
                </div>
              )}
              <div className="sl">
                <span>Submitted</span>
                <b>{formatInstant(selected.submittedAt)}</b>
              </div>
              <label className="check">
                <input
                  type="checkbox"
                  checked={deleteAfter}
                  onChange={(e) => setDeleteAfter(e.target.checked)}
                />{' '}
                Delete the screenshot once decided (keeps the amount and the decision)
              </label>
              <div className="btn-pair">
                <button className="wbtn r" disabled={busy} onClick={() => void decide(false)}>
                  Reject
                </button>
                <button className="wbtn p" disabled={busy} onClick={() => void decide(true)}>
                  Approve &amp; unlock subscription
                </button>
              </div>
            </div>
          </div>
        )}
      </div>
    </>
  );
}
