import request from 'supertest';
import { uuidv7 } from 'uuidv7';
import { TestHarness, type SeededTenant } from '../harness';
import { TERMINAL, saleOp } from '../helpers/build-ops';

/**
 * SUSPENSION BLOCKS MANAGEMENT WRITES, AND NOTHING ELSE (BR-1.3, ADR-016).
 *
 * The assertion that matters most in this file is that **`/sync/push` still works while
 * suspended**. Those operations are records of things that already happened: money taken,
 * receipts printed, stock gone from the shelf. Refusing them leaves them in an outbox that
 * retries forever until the device is replaced — at which point a pharmacy's real trading
 * records are destroyed over a billing dispute.
 *
 * This suite exists because that regression was introduced once already, during the very
 * change that added the guard: the decorator was written and never applied. It is an easy
 * mistake, it produces no error anywhere in our own systems, and the people it harms find
 * out months later.
 */
describe('BR-1.3 / ADR-016 — what suspension blocks', () => {
  let harness: TestHarness;
  let tenant: SeededTenant;
  const server = () => harness.app.getHttpServer();

  beforeAll(async () => {
    harness = await TestHarness.start();
  });

  beforeEach(async () => {
    await harness.reset();
    tenant = await harness.seedTenant('abay', 1500);
    await harness.platformDataSource.query(
      `INSERT INTO subscription (id, tenant_id, state, current_period_end, price_santim)
       VALUES ($1, $2, 'active', now() + interval '30 days', 100000)`,
      [uuidv7(), tenant.id],
    );
  });

  afterAll(async () => harness?.stop());

  const suspend = (reason = 'payment not received') =>
    harness.platformDataSource.query(
      `UPDATE subscription SET state = 'suspended', suspended_reason = $2 WHERE tenant_id = $1`,
      [tenant.id, reason],
    );

  const asOwner = () => tenant.users.owner.token;
  const asCashier = () => tenant.users.cashier.token;

  describe('a queued record always lands', () => {
    it('accepts /sync/push while suspended — the whole point of ADR-016', async () => {
      await suspend();

      const response = await request(server())
        .post('/api/sync/push')
        .set('authorization', `Bearer ${asCashier()}`)
        .send({
          terminalId: TERMINAL,
          operations: [saleOp(tenant, { terminalSeq: 1, qty: 2, batchId: null })],
        })
        .expect(201);

      expect(response.body.acks[0].status).toBe('applied');

      const rows = await harness.platformDataSource.query(
        `SELECT count(*)::int AS n FROM sale WHERE tenant_id = $1`,
        [tenant.id],
      );
      expect(rows[0].n).toBe(1);
    });

    it('accepts a full offline backlog while suspended', async () => {
      // The case that actually hurts: three days of trade queued on a terminal, and the
      // subscription lapsed at some point in between.
      await suspend();

      const ops = Array.from({ length: 40 }, (_, i) =>
        saleOp(tenant, { terminalSeq: i + 1, qty: 1, batchId: null }),
      );
      const response = await request(server())
        .post('/api/sync/push')
        .set('authorization', `Bearer ${asCashier()}`)
        .send({ terminalId: TERMINAL, operations: ops })
        .expect(201);

      expect(response.body.acks.every((a: { status: string }) => a.status === 'applied')).toBe(
        true,
      );
    });

    it('still serves /sync/pull, so the counter does not overcharge customers', async () => {
      // A terminal running on stale prices harms the pharmacy's customers, who are no party
      // to our billing relationship.
      await suspend();
      await request(server())
        .get('/api/sync/pull?cursor=0')
        .set('authorization', `Bearer ${asCashier()}`)
        .expect(200);
    });
  });

  describe('management writes stop', () => {
    it.each([
      ['change a price', 'post', '/products/PRODUCT/price', { priceSantim: 999 }],
      ['create a branch', 'post', '/branches', { name: 'Another' }],
      [
        'create a user',
        'post',
        '/users',
        { username: 'newbie', displayName: 'New', role: 'cashier', pin: '1234', branchIds: [] },
      ],
    ] as const)('%s → 402', async (_label, method, path, body) => {
      await suspend();
      const response = await request(server())
        [method](`/api${path.replace('PRODUCT', tenant.productId)}`)
        .set('authorization', `Bearer ${asOwner()}`)
        .send(body);
      expect(response.status).toBe(402);
    });

    it('answers 402, not 403, so a client can tell billing from permission', async () => {
      // Only a billing refusal should send an owner to a payment screen. Conflating the two
      // sends somebody to pay for a permission they were never going to have.
      await suspend('September payment not received.');
      const response = await request(server())
        .post('/api/branches')
        .set('authorization', `Bearer ${asOwner()}`)
        .send({ name: 'Another' })
        .expect(402);

      expect(response.body.subscriptionState).toBe('suspended');
      // The reason the admin typed, shown to the owner verbatim — a suspension the owner
      // cannot explain to themselves is a support call.
      expect(response.body.message).toBe('September payment not received.');
    });

    it('does not block a management write while merely pending', async () => {
      // Pending is not suspended: a newly onboarded pharmacy sets itself up and starts
      // trading while the first payment is arranged. Blocking it would make onboarding a
      // locked door.
      await harness.platformDataSource.query(
        `UPDATE subscription SET state = 'pending', current_period_end = NULL WHERE tenant_id = $1`,
        [tenant.id],
      );
      await request(server())
        .post('/api/branches')
        .set('authorization', `Bearer ${asOwner()}`)
        .send({ name: 'Onboarding branch' })
        .expect(201);
    });
  });

  describe('reads and the way out stay open', () => {
    it('serves reports while suspended', async () => {
      // Their data. Withholding it is leverage, not enforcement.
      await suspend();
      for (const path of ['/reports/sales', '/reports/cash-up', '/reports/stock']) {
        await request(server())
          .get(`/api${path}`)
          .set('authorization', `Bearer ${asOwner()}`)
          .expect(200);
      }
    });

    it('lets the tenant read its own subscription and see why', async () => {
      await suspend('September payment not received.');
      const response = await request(server())
        .get('/api/billing/subscription')
        .set('authorization', `Bearer ${asOwner()}`)
        .expect(200);

      expect(response.body.state).toBe('suspended');
      expect(response.body.suspendedReason).toBe('September payment not received.');
    });

    it('allows a payment proof to be submitted while suspended', async () => {
      // Blocking the one action that ends a suspension would leave a tenant with no route
      // out. A 400 for the missing file proves the request reached the handler rather than
      // being refused by the guard — which is what this asserts.
      await suspend();
      const response = await request(server())
        .post('/api/billing/payment-proofs')
        .set('authorization', `Bearer ${asOwner()}`)
        .field('amountSantim', '100000');
      expect(response.status).not.toBe(402);
    });
  });

  describe('failing safe', () => {
    it('does not block a tenant that has no subscription row at all', async () => {
      // A bookkeeping gap on our side must not become a refusal charged to them.
      await harness.platformDataSource.query(`DELETE FROM subscription WHERE tenant_id = $1`, [
        tenant.id,
      ]);
      await request(server())
        .post('/api/branches')
        .set('authorization', `Bearer ${asOwner()}`)
        .send({ name: 'No subscription' })
        .expect(201);
    });

    it('never blocks a read, whatever the state', async () => {
      await suspend();
      await request(server())
        .get('/api/reports/sales')
        .set('authorization', `Bearer ${asOwner()}`)
        .expect(200);
    });

    it("keeps one tenant's suspension out of another's way", async () => {
      const other = await harness.seedTenant('tana');
      await harness.platformDataSource.query(
        `INSERT INTO subscription (id, tenant_id, state, current_period_end, price_santim)
         VALUES ($1, $2, 'active', now() + interval '30 days', 100000)`,
        [uuidv7(), other.id],
      );
      await suspend();

      await request(server())
        .post('/api/branches')
        .set('authorization', `Bearer ${other.users.owner.token}`)
        .send({ name: 'Unaffected' })
        .expect(201);
    });
  });

  describe('the exemption list stays countable', () => {
    it('exempts exactly the routes ADR-016 names', async () => {
      // An exemption list that grew by accident would hollow BR-1.3 out one endpoint at a
      // time, and nobody would be able to say what suspension still blocks. This counts
      // them: sync push (a record) and payment-proof submission (the way out).
      const { readFileSync } = await import('node:fs');
      const { execSync } = await import('node:child_process');
      const files = execSync(
        `grep -rl "AllowWhenSuspended()" ${__dirname}/../../src --include=*.ts`,
        { encoding: 'utf8' },
      )
        .trim()
        .split('\n')
        .filter(Boolean);

      const uses = files.flatMap((f) =>
        readFileSync(f, 'utf8')
          .split('\n')
          .filter((line) => line.trim() === '@AllowWhenSuspended()'),
      );

      expect(uses).toHaveLength(2);
      expect(files.map((f) => f.split('/').pop()).sort()).toEqual([
        'billing.controller.ts',
        'sync.controller.ts',
      ]);
    });
  });
});
