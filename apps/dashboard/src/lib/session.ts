import type { AuthScope } from '@pharmaet/contracts';

/**
 * Dashboard session state.
 *
 * The token lives in sessionStorage, not localStorage: this is a back-office console for
 * tenant and platform data, and a token that outlives the browser tab is a token that
 * outlives the person who walked away from the desk.
 */

const KEY = 'pharmaet.session';

export interface Session {
  accessToken: string;
  scope: AuthScope;
  tenantCode: string;
}

export function loadSession(): Session | null {
  try {
    const raw = sessionStorage.getItem(KEY);
    return raw ? (JSON.parse(raw) as Session) : null;
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
