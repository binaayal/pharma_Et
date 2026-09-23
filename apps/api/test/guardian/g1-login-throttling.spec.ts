import request from 'supertest';
import { TestHarness, TEST_PIN, TEST_TERMINAL, type SeededTenant } from '../harness';

/**
 * Guardian: login throttling (NFR-4.2, ADR-017).
 *
 * The control being proven has two halves, and the second matters as much as the first.
 * Stopping a brute force against a four-digit PIN is the obvious half. The other is that the
 * remedy must not become the attack: a lockout in a one-terminal pharmacy is a shutdown
 * anyone can trigger knowing only a pharmacy code and a username, neither of which is
 * secret. Every assertion below about what *keeps working* is load-bearing for ADR-017.
 */
describe('G1 — login throttling brakes an attacker without stopping the pharmacy', () => {
  let harness: TestHarness;
  let tenant: SeededTenant;

  const attempt = (username: string, secret: string, tenantCode = tenant.code) =>
    request(harness.app.getHttpServer())
      .post('/api/auth/login')
      .send({ tenantCode, username, secret, terminalId: TEST_TERMINAL });

  beforeAll(async () => {
    harness = await TestHarness.start();
  });

  afterAll(async () => {
    await harness.stop();
  });

  beforeEach(async () => {
    // A full reset per test, not per suite: the per-source-address limit counts every
    // failure from this process, so tests that shared a window would throttle each other and
    // the suite would start passing for the wrong reason.
    await harness.reset();
    tenant = await harness.seedTenant('thr');
  });

  it('stops a brute force of the PIN space after five wrong guesses', async () => {
    const statuses: number[] = [];
    for (let guess = 0; guess < 7; guess += 1) {
      const response = await attempt('cashier', String(1000 + guess));
      statuses.push(response.status);
    }

    // Five tries are answered honestly; everything after is refused before the credential is
    // ever checked. 1 in 10,000 stays 1 in 10,000 instead of collapsing to minutes of work.
    expect(statuses.slice(0, 5)).toEqual([401, 401, 401, 401, 401]);
    expect(statuses.slice(5)).toEqual([429, 429]);
  });

  it('does not lock the pharmacy: another cashier signs in while one is throttled', async () => {
    for (let guess = 0; guess < 6; guess += 1) {
      await attempt('cashier', String(1000 + guess));
    }
    await attempt('cashier', TEST_PIN).expect(429);

    // The whole point of ADR-017. If this ever returns 429 the control has become a
    // denial-of-service that any passer-by can aim at a shop.
    await attempt('manager', TEST_PIN).expect(200);
    await attempt('owner', TEST_PIN).expect(200);
  });

  it('leaves a terminal that is already signed in trading', async () => {
    const session = await harness.login(tenant.code, 'cashier');

    for (let guess = 0; guess < 6; guess += 1) {
      await attempt('cashier', String(1000 + guess));
    }
    await attempt('cashier', TEST_PIN).expect(429);

    // Throttling is a brake on *new* sign-ins. The till in the shop holds a session and
    // keeps selling — which is what makes the brake safe to apply at all (NFR-1.2, BR-2.3).
    await request(harness.app.getHttpServer())
      .get('/api/products')
      .set('Authorization', `Bearer ${session.accessToken}`)
      .expect(200);
  });

  it('clears the counter on a success, so a fumbled PIN is not held against the day', async () => {
    for (let guess = 0; guess < 4; guess += 1) {
      await attempt('cashier', String(1000 + guess)).expect(401);
    }
    await attempt('cashier', TEST_PIN).expect(200);

    // Without the clear, this cashier would spend the rest of their shift one typo away from
    // a fifteen-minute wait — and would learn to write the PIN on the monitor.
    for (let guess = 0; guess < 4; guess += 1) {
      await attempt('cashier', String(2000 + guess)).expect(401);
    }
    await attempt('cashier', TEST_PIN).expect(200);
  });

  it('is not an account-enumeration oracle', async () => {
    const real = await attempt('cashier', '9999');
    const noSuchUser = await attempt('ghost', '9999');
    const noSuchTenant = await attempt('cashier', '9999', 'nope');

    // Identical before the throttle engages...
    expect(noSuchUser.status).toBe(real.status);
    expect(noSuchTenant.status).toBe(real.status);
    expect(noSuchUser.body.message).toEqual(real.body.message);
    expect(noSuchTenant.body.message).toEqual(real.body.message);

    // ...and identical once it does. Counting attempts against names that do not exist is
    // the point: refusing to count them would make "you were throttled" mean "that account
    // is real", reintroducing through the limiter the exact leak the uniform 401 prevents.
    for (let guess = 0; guess < 5; guess += 1) {
      await attempt('ghost', String(1000 + guess));
      await attempt('cashier', String(1000 + guess));
    }
    const throttledGhost = await attempt('ghost', '9999');
    const throttledReal = await attempt('cashier', '9999');

    expect(throttledGhost.status).toBe(429);
    expect(throttledReal.status).toBe(429);
    expect(throttledGhost.body.message).toEqual(throttledReal.body.message);
  });

  it('throttles one tenant without touching another', async () => {
    const other = await harness.seedTenant('thr2');

    for (let guess = 0; guess < 6; guess += 1) {
      await attempt('cashier', String(1000 + guess));
    }
    await attempt('cashier', TEST_PIN).expect(429);

    // Same username, different pharmacy. The counter is keyed on the pair, so one tenant
    // under attack cannot shut the door on an unrelated one on the same server.
    await attempt('cashier', TEST_PIN, other.code).expect(200);
  });

  it('tells the user what to do, and says the shop keeps selling', async () => {
    for (let guess = 0; guess < 6; guess += 1) {
      await attempt('cashier', String(1000 + guess));
    }
    const response = await attempt('cashier', TEST_PIN).expect(429);

    expect(response.body.retryAfterSeconds).toBe(900);
    // A cashier reading this at a counter with a queue needs to know they have not broken
    // the shop. That reassurance is part of the control, not decoration.
    expect(response.body.message).toMatch(/15 minutes/);
    expect(response.body.message).toMatch(/does not stop you selling/);
  });
});
