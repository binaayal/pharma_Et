import { CONTRACT_VERSION, CONTRACT_VERSION_HEADER } from '@pharmaet/contracts';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiError, api, isSessionExpired } from '../src/lib/api';

/**
 * The dashboard's API client (docs/05-qa §3, tier T2).
 *
 * §3 puts "dashboard API" in T2 — adapters, tested by integration and contract, ≥ 80% line.
 * It had no tests at all: the only two files in this directory covered pure formatting
 * helpers, so every request the console makes was unexercised.
 *
 * What is worth pinning here is not that `fetch` was called. It is the three things every
 * page silently depends on and none of them asserts for itself: that a request carries the
 * contract version it was built against, that the token goes in the right header, and that a
 * failure arrives as an `ApiError` **carrying its status** — because a 401 losing its status
 * on the way up is what turns "your session ended" into "something went wrong".
 */
describe('the dashboard API client', () => {
  const fetchMock = vi.fn();

  beforeEach(() => {
    fetchMock.mockReset();
    vi.stubGlobal('fetch', fetchMock);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  const ok = (body: unknown) => fetchMock.mockResolvedValue({ ok: true, json: async () => body });

  const fail = (status: number, body: unknown = {}) =>
    fetchMock.mockResolvedValue({ ok: false, status, json: async () => body });

  const lastCall = () => {
    const [url, init] = fetchMock.mock.calls.at(-1) as [string, RequestInit];
    return { url, headers: (init.headers ?? {}) as Record<string, string>, init };
  };

  describe('what every request carries', () => {
    it('declares the contract version it was built against (ADR-009)', async () => {
      ok([]);
      await api.tenants('tok');

      // A console that did not declare its version would be served as if it spoke the
      // current one, and would misparse the day the server moved on.
      expect(lastCall().headers[CONTRACT_VERSION_HEADER]).toBe(CONTRACT_VERSION);
    });

    it('sends the token as a bearer credential, and only when there is one', async () => {
      ok([]);
      await api.tenants('tok');
      expect(lastCall().headers.authorization).toBe('Bearer tok');

      ok({ status: 'ok' });
      await api.health();
      // `/health` is public. Sending an authorization header to it would be harmless and
      // still wrong: the client should not imply a credential is needed where it is not.
      expect(lastCall().headers.authorization).toBeUndefined();
    });

    it('asks for JSON', async () => {
      ok([]);
      await api.tenants('tok');
      expect(lastCall().headers['content-type']).toBe('application/json');
    });
  });

  describe('when the server refuses', () => {
    it('raises an ApiError that still knows it was a 401', async () => {
      fail(401, { message: 'invalid or expired token' });

      // The whole of the console's session handling rests on this. Every page checks
      // `status === 401` to sign the owner out; a status lost in translation would show them
      // a generic error and leave them stuck on a page that never loads.
      await expect(api.tenants('stale')).rejects.toMatchObject({
        status: 401,
        message: 'invalid or expired token',
      });
      await expect(api.tenants('stale')).rejects.toBeInstanceOf(ApiError);
    });

    it("keeps the server's wording when there is some", async () => {
      fail(403, { message: 'that report is outside your scope' });

      // The API says something useful about scope and capability denials; replacing it with
      // a generic string would throw away the only explanation the user gets.
      await expect(api.tenants('tok')).rejects.toThrow('that report is outside your scope');
    });

    it('still fails usefully when the body is not JSON at all', async () => {
      // A proxy timeout or an HTML error page. The console must surface *something* rather
      // than throwing a parse error from inside the client.
      fetchMock.mockResolvedValue({
        ok: false,
        status: 502,
        json: async () => {
          throw new SyntaxError('Unexpected token < in JSON');
        },
      });

      await expect(api.tenants('tok')).rejects.toMatchObject({ status: 502 });
      await expect(api.tenants('tok')).rejects.toThrow('request failed (502)');
    });
  });

  describe('the platform surface is kept separate (BR-2.2)', () => {
    it('logs in without a tenant token', async () => {
      ok({ accessToken: 'plat', admin: { id: 'a', email: 'e', displayName: 'd' } });
      await api.login('ops@example.com', 'pw');

      const { url, headers, init } = lastCall();
      expect(url).toContain('/platform/login');
      expect(init.method).toBe('POST');
      expect(headers.authorization).toBeUndefined();
    });

    it('sends the platform token, never a tenant one, to platform routes', async () => {
      ok([]);
      await api.tenants('platform-token');

      const { url, headers } = lastCall();
      expect(url).toContain('/platform/tenants');
      expect(headers.authorization).toBe('Bearer platform-token');
    });
  });

  describe('recognising an ended session', () => {
    // One rule, and until now six spellings of it across six pages. Two of them — the audit
    // trail and the platform console — reached straight into `cause` with no guard, so a
    // rejection that was not an object would throw a TypeError *inside the catch block*. An
    // error handler that fails takes the page down instead of showing a sign-in screen.
    it('recognises a 401 from the API client', async () => {
      fail(401, { message: 'expired' });
      const caught = await api.tenants('stale').catch((cause: unknown) => cause);
      expect(isSessionExpired(caught)).toBe(true);
    });

    it('does not mistake any other failure for an ended session', async () => {
      for (const status of [400, 403, 404, 429, 500, 502]) {
        fail(status, { message: 'nope' });
        const caught = await api.tenants('tok').catch((cause: unknown) => cause);
        expect(isSessionExpired(caught)).toBe(false);
      }
    });

    it('survives anything at all being thrown instead of an ApiError', () => {
      // The cases that used to crash. `catch` receives whatever was thrown, and assuming
      // otherwise is the bug this replaces. (Listed inline rather than via `it.each`, whose
      // title formatter cannot stringify a Symbol — which is itself the joke.)
      const thrown: unknown[] = [
        null,
        undefined,
        'a string',
        42,
        Symbol('x'),
        {},
        [],
        new Error('plain'),
      ];
      for (const value of thrown) {
        expect(() => isSessionExpired(value)).not.toThrow();
        expect(isSessionExpired(value)).toBe(false);
      }
    });

    it('is not fooled by a status that merely looks like one', () => {
      // A string "401" from a hand-rolled error object is not a 401, and treating it as one
      // would sign somebody out on an unrelated failure.
      expect(isSessionExpired({ status: '401' })).toBe(false);
      expect(isSessionExpired({ status: 401 })).toBe(true);
    });
  });

  describe('query parameters reach the server', () => {
    it('asks for the sign-up queue by status', async () => {
      ok([]);
      await api.signupRequests('tok', 'pending');
      expect(lastCall().url).toContain('/platform/signup-requests?status=pending');
    });
  });

  describe('the payment screenshot', () => {
    it('is fetched with the platform token, not followed as a bare link', async () => {
      // A plain <a href> carries no Authorization header, so the guard refused it and the
      // reviewer could never see the proof they were approving.
      fetchMock.mockResolvedValue({ ok: true, blob: async () => new Blob(['png']) });
      vi.stubGlobal('URL', { ...URL, createObjectURL: () => 'blob:proof' });
      const url = await api.proofImage('platform-token', 'p1');

      const { url: requested, headers } = lastCall();
      expect(requested).toContain('/platform/payment-proofs/p1/image');
      expect(headers.authorization).toBe('Bearer platform-token');
      expect(url).toBe('blob:proof');
    });
  });
});
