import request from 'supertest';
import { uuidv7 } from 'uuidv7';
import { TEST_PIN, TEST_TERMINAL, TestHarness, type SeededTenant } from '../harness';
import { TERMINAL, saleOp } from '../helpers/build-ops';

/**
 * A DEACTIVATED PHARMACY IS REFUSED EVERYTHING, AND LOSES NOTHING (ADR-025).
 *
 * The platform's forced stop for an account that broke its terms. Three properties matter,
 * and each has an obvious way to be quietly wrong:
 *
 *  - **It reaches tokens already issued.** A check at sign-in alone leaves every signed-in
 *    terminal working for the life of its access token, and a refresh token is thirty days.
 *  - **It does not become an enumeration oracle.** "Deactivated" is said only to someone
 *    who proved the credential; a wrong PIN is refused exactly as before.
 *  - **It deletes nothing.** Reactivation restores the account as it was — and a push
 *    refused in between writes nothing, so the terminal keeps it queued.
 *
 * And, as with every G1 suite: the tenant next door is untouched.
 */
describe('G1 / ADR-025 — forced deactivation of a tenant', () => {
  let harness: TestHarness;
  let abay: SeededTenant;
  let tana: SeededTenant;
  let platformToken: string;
  const server = () => harness.app.getHttpServer();

  beforeAll(async () => {
    harness = await TestHarness.start();
  });

  beforeEach(async () => {
    await harness.reset();
    abay = await harness.seedTenant('abay');
    tana = await harness.seedTenant('tana');
    platformToken = await harness.seedPlatformAdmin();
  });

  afterAll(async () => harness?.stop());

  const REASON = 'Selling prescription-only medicine without a prescription.';

  const deactivate = (tenantId = abay.id, reason = REASON) =>
    request(server())
      .post(`/api/platform/tenants/${tenantId}/deactivate`)
      .set('authorization', `Bearer ${platformToken}`)
      .send({ reason });

  const login = (code: string, secret = TEST_PIN) =>
    request(server())
      .post('/api/auth/login')
      .send({ tenantCode: code, username: 'owner', secret, terminalId: TEST_TERMINAL });

  describe('what is refused', () => {
    it('refuses a correct sign-in, with the reason and a code the app keys on', async () => {
      await deactivate().expect(201);
      const response = await login('abay').expect(403);
      expect(response.body.code).toBe('tenant_deactivated');
      expect(response.body.message).toBe(REASON);
    });

    it('refuses a WRONG PIN exactly as it always did — no oracle', async () => {
      // Saying "deactivated" before the credential is proven would confirm the pharmacy
      // code is real to anyone guessing.
      await deactivate().expect(201);
      const response = await login('abay', '9999').expect(401);
      expect(response.body.code).toBeUndefined();
      expect(JSON.stringify(response.body)).not.toContain('deactivated');
    });

    it('refuses tokens issued before the deactivation — reads included', async () => {
      await deactivate().expect(201);
      for (const path of ['/reports/sales', '/sync/pull?cursor=0', '/billing/subscription']) {
        const response = await request(server())
          .get(`/api${path}`)
          .set('authorization', `Bearer ${abay.users.owner.token}`);
        expect({ path, status: response.status }).toEqual({ path, status: 403 });
        expect(response.body.code).toBe('tenant_deactivated');
      }
    });

    it('refuses a refresh, so thirty days of refresh token cannot outlive it', async () => {
      const session = await harness.login('abay', 'cashier');
      await deactivate().expect(201);
      const response = await request(server())
        .post('/api/auth/refresh')
        .send({ refreshToken: session.refreshToken, terminalId: TEST_TERMINAL })
        .expect(403);
      expect(response.body.code).toBe('tenant_deactivated');
    });

    it('refuses a push and writes nothing, so the terminal keeps it queued', async () => {
      await deactivate().expect(201);
      await request(server())
        .post('/api/sync/push')
        .set('authorization', `Bearer ${abay.users.cashier.token}`)
        .send({
          terminalId: TERMINAL,
          operations: [saleOp(abay, { terminalSeq: 1, qty: 1, batchId: null })],
        })
        .expect(403);

      const rows = await harness.platformDataSource.query(
        `SELECT count(*)::int AS n FROM sale WHERE tenant_id = $1`,
        [abay.id],
      );
      expect(rows[0].n).toBe(0);
    });
  });

  describe('what is untouched', () => {
    it('leaves the tenant next door working', async () => {
      await deactivate().expect(201);
      await login('tana').expect(200);
      await request(server())
        .get('/api/reports/sales')
        .set('authorization', `Bearer ${tana.users.owner.token}`)
        .expect(200);
    });

    it('deletes nothing: reactivation restores the account and its records', async () => {
      await request(server())
        .post('/api/sync/push')
        .set('authorization', `Bearer ${abay.users.cashier.token}`)
        .send({
          terminalId: TERMINAL,
          operations: [saleOp(abay, { terminalSeq: 1, qty: 2, batchId: null })],
        })
        .expect(201);

      await deactivate().expect(201);
      await request(server())
        .post(`/api/platform/tenants/${abay.id}/reactivate`)
        .set('authorization', `Bearer ${platformToken}`)
        .send({ note: 'Owner signed the corrective-action letter.' })
        .expect(201);

      // The token minted before any of this works again: nothing about the account changed
      // but its status.
      await request(server())
        .get('/api/reports/sales')
        .set('authorization', `Bearer ${abay.users.owner.token}`)
        .expect(200);
      await login('abay').expect(200);

      const rows = await harness.platformDataSource.query(
        `SELECT count(*)::int AS n FROM sale WHERE tenant_id = $1`,
        [abay.id],
      );
      expect(rows[0].n).toBe(1);
    });

    it('is recorded in the pharmacy’s own audit trail, by the platform', async () => {
      await deactivate().expect(201);
      await request(server())
        .post(`/api/platform/tenants/${abay.id}/reactivate`)
        .set('authorization', `Bearer ${platformToken}`)
        .send({})
        .expect(201);

      const events = await harness.platformDataSource.query(
        `SELECT event_type, payload FROM event
          WHERE tenant_id = $1 AND event_type LIKE 'audit.tenant_%' ORDER BY seq`,
        [abay.id],
      );
      expect(events.map((e: { event_type: string }) => e.event_type)).toEqual([
        'audit.tenant_deactivated',
        'audit.tenant_reactivated',
      ]);
      expect(events[0].payload.reason).toBe(REASON);
      expect(events[0].payload.byPlatformAdmin).toBe(true);
    });
  });

  describe('who may do it, and how', () => {
    it('is refused to a tenant token, even the owner’s', async () => {
      await request(server())
        .post(`/api/platform/tenants/${tana.id}/deactivate`)
        .set('authorization', `Bearer ${abay.users.owner.token}`)
        .send({ reason: REASON })
        .expect(401);
    });

    it('requires a reason the owner can read', async () => {
      await deactivate(abay.id, 'bad').expect(400);
      await login('abay').expect(200);
    });

    it('will not overwrite an existing deactivation', async () => {
      await deactivate().expect(201);
      await deactivate(abay.id, 'A different reason that would erase the first.').expect(400);
      const [row] = await harness.platformDataSource.query(
        `SELECT deactivated_reason FROM tenant WHERE id = $1`,
        [abay.id],
      );
      expect(row.deactivated_reason).toBe(REASON);
    });

    it('answers 404 for a pharmacy that does not exist, and 400 for a malformed id', async () => {
      await deactivate(uuidv7()).expect(404);
      await deactivate('not-a-uuid').expect(400);
    });

    it('is enforced by the schema too: a deactivation needs a reason, a time and an actor', async () => {
      await expect(
        harness.platformDataSource.query(`UPDATE tenant SET status = 'deactivated' WHERE id = $1`, [
          abay.id,
        ]),
      ).rejects.toThrow(/tenant_deactivation_check/);
    });

    it('shows the platform console who is deactivated and why', async () => {
      await deactivate().expect(201);
      const response = await request(server())
        .get('/api/platform/tenants')
        .set('authorization', `Bearer ${platformToken}`)
        .expect(200);
      const row = response.body.find((t: { id: string }) => t.id === abay.id);
      expect(row.status).toBe('deactivated');
      expect(row.deactivatedReason).toBe(REASON);
      expect(row.deactivatedAt).toEqual(expect.any(String));
    });
  });
});
