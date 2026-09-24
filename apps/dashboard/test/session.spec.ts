// @vitest-environment jsdom
//
// `sessionStorage` is a browser API, so this file needs a DOM. Declared per file rather than
// globally: the API-client and formatting suites are pure TypeScript and run faster, and more
// honestly, without one.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { clearSession, loadSession, saveSession, type Session } from '../src/lib/session';

/**
 * The dashboard's session store (docs/05-qa §3, tier T2).
 *
 * Three of its four branches are `catch` blocks, and nothing exercised any of them. That is
 * the usual shape of this kind of defect: the happy path is obvious and gets used constantly,
 * while the failure paths are written once from good instincts and never run again — until a
 * private window or a locked-down browser runs them for real, in front of a pharmacy owner.
 *
 * `sessionStorage` rather than `localStorage` is deliberate and worth pinning: this console
 * shows tenant and platform data, and a token that outlives the browser tab outlives the
 * person who walked away from the desk.
 */
describe('the dashboard session store', () => {
  const session: Session = {
    accessToken: 'tok',
    tenantCode: 'abay',
    scope: {
      userId: '01930000-0000-7000-8000-000000000001',
      tenantId: '01930000-0000-7000-8000-000000000002',
      role: 'owner',
      branchIds: [],
      displayName: 'Abay owner',
    },
  };

  beforeEach(() => {
    sessionStorage.clear();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('round-trips a session', () => {
    saveSession(session);
    expect(loadSession()).toEqual(session);
  });

  it('is empty before anyone signs in', () => {
    expect(loadSession()).toBeNull();
  });

  it('forgets on sign-out', () => {
    saveSession(session);
    clearSession();
    expect(loadSession()).toBeNull();
  });

  it('uses sessionStorage, so a closed tab is a closed session', () => {
    saveSession(session);

    // Pinned deliberately. Moving this to localStorage would be a one-word change that
    // silently leaves a back-office token on a shared machine overnight.
    expect(sessionStorage.getItem('pharmaet.session')).not.toBeNull();
    expect(localStorage.getItem('pharmaet.session')).toBeNull();
  });

  describe('when the browser will not cooperate', () => {
    it('reads a corrupt value as signed out rather than crashing on boot', () => {
      sessionStorage.setItem('pharmaet.session', '{not json');

      // A console that throws here shows a blank page and no way forward. Treating it as
      // logged out costs one sign-in.
      expect(loadSession()).toBeNull();
    });

    it('survives storage being blocked on read', () => {
      vi.spyOn(Storage.prototype, 'getItem').mockImplementation(() => {
        throw new DOMException('The operation is insecure.', 'SecurityError');
      });

      // Private browsing, or a policy that blocks site data. Real, and not rare.
      expect(loadSession()).toBeNull();
    });

    it('survives storage being full or blocked on write', () => {
      vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => {
        throw new DOMException('QuotaExceededError', 'QuotaExceededError');
      });

      // Non-fatal by design: the person is signed in for this tab, the session simply will
      // not survive a reload. Throwing would turn a successful login into a failed one.
      expect(() => saveSession(session)).not.toThrow();
    });

    it('survives storage being blocked on sign-out', () => {
      saveSession(session);
      vi.spyOn(Storage.prototype, 'removeItem').mockImplementation(() => {
        throw new DOMException('The operation is insecure.', 'SecurityError');
      });

      // Signing out must never fail loudly — the user asked to leave, and an error dialog
      // that keeps them signed in is the opposite of what they requested.
      expect(() => clearSession()).not.toThrow();
    });
  });
});
