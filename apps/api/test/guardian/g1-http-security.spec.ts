import request from 'supertest';
import { TestHarness, type SeededTenant } from '../harness';

/**
 * G1 — THE HTTP SECURITY BASELINE (NFR-4.3, docs/engineering/security.md).
 *
 * The request-level controls the other suites take for granted: what every response says
 * about itself, who may sign in how often, how the console's session is carried, and what a
 * malformed or hostile input gets back. Each is a line of configuration that is easy to lose
 * in a refactor and invisible until someone looks for it.
 */
describe('G1 — HTTP security baseline', () => {
  let harness: TestHarness;
  let abay: SeededTenant;
  const server = () => harness.app.getHttpServer();
  const EMAIL = 'ops@pharmaet.test';
  const PASSWORD = 'platform-pass-1';

  beforeAll(async () => {
    harness = await TestHarness.start();
  });

  beforeEach(async () => {
    await harness.reset();
    abay = await harness.seedTenant('abay');
    await harness.seedPlatformAdmin(EMAIL, PASSWORD);
  });

  afterAll(async () => harness?.stop());

  describe('every response', () => {
    it('carries the security headers and names no framework', async () => {
      const response = await request(server()).get('/api/health').expect(200);
      expect(response.headers['x-powered-by']).toBeUndefined();
      expect(response.headers['x-content-type-options']).toBe('nosniff');
      expect(response.headers['x-frame-options']).toBe('DENY');
      expect(response.headers['referrer-policy']).toBe('no-referrer');
      expect(response.headers['content-security-policy']).toContain("default-src 'self'");
      expect(response.headers['content-security-policy']).toContain("frame-ancestors 'none'");
      expect(response.headers['cross-origin-resource-policy']).toBe('same-origin');
    });

    it('is never cached when it is API data', async () => {
      const response = await request(server())
        .get('/api/reports/sales')
        .set('authorization', `Bearer ${abay.users.owner.token}`)
        .expect(200);
      expect(response.headers['cache-control']).toBe('no-store');
    });

    it('never returns a credential hash', async () => {
      const response = await request(server())
        .get('/api/users')
        .set('authorization', `Bearer ${abay.users.owner.token}`)
        .expect(200);
      const body = JSON.stringify(response.body);
      expect(body).not.toMatch(/argon2|pin_?hash|password_?hash/i);
    });
  });

  describe('platform sign-in', () => {
    const attempt = (password: string) =>
      request(server()).post('/api/platform/login').send({ email: EMAIL, password });

    it('is throttled like a pharmacy sign-in (ADR-017)', async () => {
      for (let i = 0; i < 5; i++) await attempt('wrong-password-x').expect(401);
      const response = await attempt(PASSWORD).expect(429);
      expect(response.body.retryAfterSeconds).toBeGreaterThan(0);
    });

    it('sets an HttpOnly, SameSite=Strict cookie scoped to the platform routes', async () => {
      const response = await attempt(PASSWORD).expect(201);
      const cookie = [response.headers['set-cookie']].flat().join(';');
      expect(cookie).toMatch(/pe_platform=/);
      expect(cookie).toMatch(/HttpOnly/i);
      expect(cookie).toMatch(/SameSite=Strict/i);
      expect(cookie).toMatch(/Path=\/api\/platform/);
    });
  });

  describe('the console session cookie', () => {
    async function cookie(): Promise<string> {
      const response = await request(server())
        .post('/api/platform/login')
        .send({ email: EMAIL, password: PASSWORD })
        .expect(201);
      return [response.headers['set-cookie']].flat()[0].split(';')[0];
    }

    it('authenticates a read', async () => {
      const session = await cookie();
      const response = await request(server())
        .get('/api/platform/me')
        .set('cookie', session)
        .expect(200);
      expect(response.body.email).toBe(EMAIL);
    });

    it('refuses a write that lacks the console header — cross-site forgery', async () => {
      const session = await cookie();
      await request(server())
        .post(`/api/platform/tenants/${abay.id}/deactivate`)
        .set('cookie', session)
        .send({ reason: 'A forged request from another site.' })
        .expect(403);
    });

    it('accepts the same write from the console', async () => {
      const session = await cookie();
      await request(server())
        .post(`/api/platform/tenants/${abay.id}/deactivate`)
        .set('cookie', session)
        .set('x-contract-version', '1')
        .send({ reason: 'Breach of the terms of service.' })
        .expect(201);
    });

    it('is not a tenant credential anywhere else', async () => {
      const session = await cookie();
      await request(server()).get('/api/reports/sales').set('cookie', session).expect(401);
    });

    it('is cleared on sign-out', async () => {
      const response = await request(server()).post('/api/platform/logout').expect(204);
      const cleared = [response.headers['set-cookie']].flat().join(';');
      expect(cleared).toMatch(/pe_platform=;/);
    });
  });

  describe('malformed input is a 400, never a 500', () => {
    it.each([
      ['a tenant id', 'get', '/api/platform/tenants/not-a-uuid', 'platform'],
      ['a user id', 'delete', '/api/users/not-a-uuid', 'owner'],
      ['a shift id', 'get', '/api/reports/cash-up/nope', 'owner'],
      ['a branch filter', 'get', '/api/reports/stock?branchId=nope', 'owner'],
      ['a limit', 'get', '/api/reports/sales?limit=1000000000', 'owner'],
      ['a limit that is not a number', 'get', '/api/reports/cash-up?limit=abc', 'owner'],
    ] as const)('%s', async (_label, method, path, who) => {
      const token =
        who === 'platform'
          ? await harness.seedPlatformAdmin(EMAIL, PASSWORD)
          : abay.users.owner.token;
      const response = await request(server())
        [method](path)
        .set('authorization', `Bearer ${token}`);
      expect(response.status).toBe(400);
    });
  });

  describe('the anonymous sign-up form', () => {
    const base = {
      pharmacyName: 'Adera Pharmacy',
      ownerName: 'Helen Bekele',
      phone: '0911223344',
      city: 'Addis Ababa',
      branchBand: '1',
    };
    const count = async () =>
      (await harness.platformDataSource.query(`SELECT count(*)::int AS n FROM signup_request`))[0]
        .n;

    it('answers a bot that fills the honeypot exactly like a person, and stores nothing', async () => {
      const response = await request(server())
        .post('/api/signup-requests')
        .send({ ...base, website: 'http://spam.example' })
        .expect(201);
      expect(response.body.status).toBe('pending');
      expect(await count()).toBe(0);
    });

    it('refuses links and markup in a name', async () => {
      for (const pharmacyName of ['Visit http://x.example', '<script>alert(1)</script>']) {
        await request(server())
          .post('/api/signup-requests')
          .send({ ...base, pharmacyName })
          .expect(400);
      }
      expect(await count()).toBe(0);
    });

    it('still takes a real request', async () => {
      await request(server()).post('/api/signup-requests').send(base).expect(201);
      expect(await count()).toBe(1);
    });
  });
});
