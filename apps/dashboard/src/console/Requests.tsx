import { useEffect, useState } from 'react';
import { api, type SignupRequest } from '../lib/api';
import { formatInstant, formatPhone } from '../lib/format';
import type { PageProps } from './Console';

const BAND: Record<SignupRequest['branchBand'], string> = {
  '1': '1 branch',
  '2-3': '2–3 branches',
  '4+': '4+ branches',
};

/**
 * Screen 22 — the onboarding gate (ADR-022).
 *
 * Call the number first. Approving opens the pharmacy and its owner account in one step; the
 * starting PIN is read out to the owner on that call, since V1 sends no texts.
 */
export function Requests({ token, data, reload, fail }: PageProps) {
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [mode, setMode] = useState<'view' | 'approve' | 'reject'>('view');
  const [code, setCode] = useState('');
  const [username, setUsername] = useState('');
  const [pin, setPin] = useState('');
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);

  const selected = data.requests.find((r) => r.id === selectedId) ?? data.requests[0] ?? null;

  useEffect(() => {
    // A fresh request gets fresh suggestions — never the last one's PIN.
    setMode('view');
    setReason('');
    setPin('');
    if (selected) {
      setCode(slug(selected.pharmacyName));
      setUsername(slug(selected.ownerName.split(' ')[0] ?? 'owner'));
    }
  }, [selected?.id]); // eslint-disable-line react-hooks/exhaustive-deps

  async function decide(accept: boolean) {
    if (!selected) return;
    setBusy(true);
    try {
      await api.decideSignup(
        token,
        selected.id,
        accept
          ? { accept: true, code: code.trim(), ownerUsername: username.trim(), ownerPin: pin }
          : { accept: false, reason: reason.trim() },
      );
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
          <h3>Sign-up requests</h3>
          <p>Verify each pharmacy by phone before opening an account — the anti-abuse gate</p>
        </div>
      </div>
      <div className="wgrid2">
        <div className="wpanel">
          <div className="wpanel-h">
            <b>Awaiting review</b>
            <span className="sp" />
            <span className="badge b-amber">{data.requests.length}</span>
          </div>
          {data.requests.length === 0 ? (
            <div className="empty">
              No requests waiting. They arrive from “Request an account” in the app.
            </div>
          ) : (
            <table>
              <thead>
                <tr>
                  <th>Pharmacy</th>
                  <th>Owner</th>
                  <th>Phone</th>
                  <th>City</th>
                </tr>
              </thead>
              <tbody>
                {data.requests.map((r) => (
                  <tr
                    key={r.id}
                    className={`pick${selected?.id === r.id ? ' sel' : ''}`}
                    onClick={() => setSelectedId(r.id)}
                  >
                    <td>
                      <b>{r.pharmacyName}</b>
                      <div className="sub">{BAND[r.branchBand]}</div>
                    </td>
                    <td>{r.ownerName}</td>
                    <td>{formatPhone(r.phone)}</td>
                    <td>{r.city}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>

        {selected && (
          <div className="wpanel">
            <div className="wpanel-h">
              <b>{selected.pharmacyName} · request</b>
            </div>
            <div className="pad">
              <div className="sl">
                <span>Owner</span>
                <b>{selected.ownerName}</b>
              </div>
              <div className="sl">
                <span>Phone</span>
                <b>{formatPhone(selected.phone)}</b>
              </div>
              <div className="sl">
                <span>City</span>
                <b>{selected.city}</b>
              </div>
              <div className="sl">
                <span>Branches</span>
                <b>{BAND[selected.branchBand]}</b>
              </div>
              <div className="sl">
                <span>Submitted</span>
                <b>{formatInstant(selected.submittedAt)}</b>
              </div>

              {mode === 'view' && (
                <>
                  <div className="notice n-blue">
                    <span>☏</span>
                    <div>Call the number to confirm it's a real pharmacy before approving.</div>
                  </div>
                  <div className="btn-pair">
                    <button className="wbtn r" onClick={() => setMode('reject')}>
                      Reject
                    </button>
                    <button className="wbtn p" onClick={() => setMode('approve')}>
                      Approve &amp; open account
                    </button>
                  </div>
                </>
              )}

              {mode === 'approve' && (
                <div style={{ marginTop: 14 }}>
                  <div className="fld">
                    <label htmlFor="code">Pharmacy code</label>
                    <input id="code" value={code} onChange={(e) => setCode(e.target.value)} />
                    <div className="hint">
                      What staff type to sign in. Letters, digits, hyphens.
                    </div>
                  </div>
                  <div className="fld">
                    <label htmlFor="username">Owner username</label>
                    <input
                      id="username"
                      value={username}
                      onChange={(e) => setUsername(e.target.value)}
                    />
                  </div>
                  <div className="fld">
                    <label htmlFor="pin">Starting PIN</label>
                    <input
                      id="pin"
                      inputMode="numeric"
                      value={pin}
                      onChange={(e) => setPin(e.target.value.replace(/\D/g, '').slice(0, 8))}
                    />
                    <div className="hint">Read it to the owner on the call — 4 to 8 digits.</div>
                  </div>
                  <div className="btn-pair">
                    <button className="wbtn d" onClick={() => setMode('view')} disabled={busy}>
                      Back
                    </button>
                    <button
                      className="wbtn p"
                      disabled={
                        busy ||
                        code.trim().length < 2 ||
                        username.trim().length < 2 ||
                        pin.length < 4
                      }
                      onClick={() => void decide(true)}
                    >
                      {busy ? 'Opening…' : 'Open account'}
                    </button>
                  </div>
                </div>
              )}

              {mode === 'reject' && (
                <div style={{ marginTop: 14 }}>
                  <div className="fld">
                    <label htmlFor="reason">Reason</label>
                    <textarea
                      id="reason"
                      rows={3}
                      value={reason}
                      onChange={(e) => setReason(e.target.value)}
                    />
                    <div className="hint">
                      Kept with the request, so the next reviewer knows why.
                    </div>
                  </div>
                  <div className="btn-pair">
                    <button className="wbtn d" onClick={() => setMode('view')} disabled={busy}>
                      Back
                    </button>
                    <button
                      className="wbtn r"
                      disabled={busy || reason.trim().length < 3}
                      onClick={() => void decide(false)}
                    >
                      {busy ? 'Rejecting…' : 'Reject request'}
                    </button>
                  </div>
                </div>
              )}
            </div>
          </div>
        )}
      </div>
    </>
  );
}

function slug(text: string): string {
  return text
    .toLowerCase()
    .replace(/pharmacy/g, '')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 32);
}
