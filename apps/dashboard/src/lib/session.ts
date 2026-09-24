import type { AuthScope } from '@pharmaet/contracts';
import { uuidv7 } from 'uuidv7';

/**
 * Dashboard session state.
 *
 * The token lives in sessionStorage, not localStorage: this is a back-office console for
 * tenant and platform data, and a token that outlives the browser tab is a token that
 * outlives the person who walked away from the desk.
 */

const KEY = 'pharmaet.session';
const TERMINAL_KEY = 'pharmaet.terminal_id';

/**
 * This browser's stable identity.
 *
 * Every session records the terminal it came from, so a dispute can be traced to its origin
 * (BR-4.3). The console used to send one hard-coded constant for every browser and every
 * tenant, which made that field a decoration: two owners on two machines were
 * indistinguishable, and so were the audit entries their sessions produced.
 *
 * **localStorage, not sessionStorage.** This identifies the machine, not the visit, and it
 * has to be the same value across tabs and after the browser closes — otherwise a refresh
 * would arrive from a "different terminal" than the login it is renewing. It is not a
 * credential: it names a device and grants nothing.
 */
export function terminalId(): string {
  try {
    const existing = localStorage.getItem(TERMINAL_KEY);
    if (existing) return existing;
    // v7, not `crypto.randomUUID()` — that returns a v4, and the contract validates
    // `terminalId` with a regex that pins the version nibble to 7 (ADR-006). A v4 here would
    // be refused by the server on every single login.
    const minted = uuidv7();
    localStorage.setItem(TERMINAL_KEY, minted);
    return minted;
  } catch {
    // Private browsing, or storage blocked. A per-load id is worse than a stable one and far
    // better than a shared constant — this session is still attributable to itself.
    return uuidv7();
  }
}

export interface Session {
  accessToken: string;
  /** Redeemed for a new session when the access token expires (ADR-019). */
  refreshToken: string;
  scope: AuthScope;
  tenantCode: string;
}

export function loadSession(): Session | null {
  try {
    const raw = sessionStorage.getItem(KEY);
    if (!raw) return null;
    const session = JSON.parse(raw) as Session;
    // A session stored before refresh existed has no token. Treated as empty rather than
    // undefined so `refresh()` is never called with the string "undefined".
    return { ...session, refreshToken: session.refreshToken ?? '' };
  } catch {
    // Private browsing, blocked storage, or a corrupt value. Treat it as logged out rather
    // than crashing the console on boot.
    return null;
  }
}

export function saveSession(session: Session): void {
  try {
    sessionStorage.setItem(KEY, JSON.stringify(session));
  } catch {
    // Non-fatal: the session simply will not survive a reload.
  }
}

export function clearSession(): void {
  try {
    sessionStorage.removeItem(KEY);
  } catch {
    /* nothing to do */
  }
}
