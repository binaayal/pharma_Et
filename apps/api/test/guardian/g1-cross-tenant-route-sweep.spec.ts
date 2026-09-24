import request from 'supertest';
import { TestHarness, type SeededTenant } from '../harness';

/**
 * G1 — EXHAUSTIVE CROSS-TENANT ROUTE SWEEP (docs/05-qa §10).
 *
 * The other G1 suites probe isolation feature by feature, which proves the features they
 * know about. §10 asks for something different and stricter: *every* route attempted across
 * the tenant boundary. The difference matters because the realistic way this product leaks
 * one pharmacy's data to another is not a flaw in a reviewed endpoint — it is an endpoint
 * added six months from now by someone who did not think about tenancy at all.
 *
 * So the sweep reads the route table out of the running application rather than from a list
 * a human maintains, and refuses to pass if it finds a route nobody has classified. A new
 * controller therefore breaks this suite on the day it is written, and the author has to say
 * which side of the tenant boundary it sits on. That is the property being protected here;
 * the individual probes below are the payoff.
 */

type RouteClass = 'unauthenticated' | 'platform' | 'tenant';

interface RouteSpec {
  /** How this route sits relative to the tenant boundary. */
  cls: RouteClass;
  /** Why, in the author's words. Recorded so the classification is a decision, not a habit. */
  why: string;
}

/**
 * The classification table. `METHOD /path` exactly as Express registers it.
 *
 * Adding a route without adding it here fails the first test in this file.
 */
const ROUTES: Record<string, RouteSpec> = {
  'GET /api/health':
    { cls: 'unauthenticated', why: 'liveness for the load balancer; returns no tenant data' },
  'POST /api/auth/login':
    { cls: 'unauthenticated', why: 'establishes the scope; cannot require one' },
  'POST /api/platform/login':
    { cls: 'unauthenticated', why: 'platform-admin sign-in; issues a token with no tenant' },
  'POST /api/auth/refresh':
    {
      cls: 'unauthenticated',
      why:
        'the access token has expired by definition — requiring one would be circular. The ' +
        'refresh token IS the credential, and it names its own tenant, so the session it ' +
        'returns is scoped by the token rather than by the caller (ADR-019).',
    },

  'GET /api/platform/tenants':
    { cls: 'platform', why: 'the operator sees every tenant; that is the surface, not a leak' },
  'POST /api/platform/tenants':
    { cls: 'platform', why: 'onboarding creates the tenant a scope would have to name' },
  'GET /api/platform/payment-proofs':
    { cls: 'platform', why: 'the operator reconciles payments across tenants' },
  'GET /api/platform/payment-proofs/:id/image':
    { cls: 'platform', why: 'the bank slip the operator is deciding on' },
  'POST /api/platform/payment-proofs/:id/decide':
    { cls: 'platform', why: 'approval is the operator’s act, never the tenant’s' },
  'POST /api/platform/subscriptions':
    { cls: 'platform', why: 'the operator grants the subscription a tenant cannot grant itself' },

  'GET /api/audit': { cls: 'tenant', why: 'one pharmacy’s action history' },
  'GET /api/audit/verify': { cls: 'tenant', why: 'hash-chain verification over that history' },
  'GET /api/branches': { cls: 'tenant', why: 'the pharmacy’s own branches' },
  'POST /api/branches': { cls: 'tenant', why: 'creates under the caller’s tenant' },
  'PATCH /api/branches/:id': { cls: 'tenant', why: 'edits a branch the caller must own' },
  'GET /api/users': { cls: 'tenant', why: 'the pharmacy’s own staff' },
  'POST /api/users': { cls: 'tenant', why: 'creates under the caller’s tenant' },
  'DELETE /api/users/:id': { cls: 'tenant', why: 'deactivates a user the caller must own' },
  'GET /api/products': { cls: 'tenant', why: 'the pharmacy’s own catalogue and prices' },
  'POST /api/products': { cls: 'tenant', why: 'creates under the caller’s tenant' },
  'POST /api/products/:id/price': { cls: 'tenant', why: 'reprices a product the caller must own' },
  'GET /api/billing/subscription': { cls: 'tenant', why: 'this pharmacy’s own billing state' },
  'GET /api/billing/payment-proofs': { cls: 'tenant', why: 'proofs this pharmacy submitted' },
  'POST /api/billing/payment-proofs': { cls: 'tenant', why: 'submits against the caller’s tenant' },
  'POST /api/sync/push': { cls: 'tenant', why: 'the core write path for one pharmacy’s terminals' },
  'GET /api/sync/pull': { cls: 'tenant', why: 'the delta a pharmacy’s terminal replays' },
  'GET /api/reports/sales': { cls: 'tenant', why: 'one pharmacy’s takings' },
  'GET /api/reports/oversells': { cls: 'tenant', why: 'one pharmacy’s reconciliation queue' },
  'GET /api/reports/cash-up/:shiftId': { cls: 'tenant', why: 'a shift the caller must own' },
  'GET /api/reports/cash-up': { cls: 'tenant', why: 'one pharmacy’s cash-ups' },
  'GET /api/reports/sales-summary': { cls: 'tenant', why: 'one pharmacy’s totals' },
  'GET /api/reports/stock': { cls: 'tenant', why: 'one pharmacy’s shelves' },
};

/** Reads the route table out of the running Express instance. */
function registeredRoutes(harness: TestHarness): string[] {
  const instance = harness.app.getHttpAdapter().getInstance();
  const router = instance._router ?? instance.router;
  const found: string[] = [];
  for (const layer of router.stack) {
    if (!layer.route) continue;
    for (const method of Object.keys(layer.route.methods)) {
      found.push(`${method.toUpperCase()} ${layer.route.path}`);
    }
  }
  return found.sort();
}

describe('G1 — every route, attempted across the tenant boundary', () => {
  let harness: TestHarness;
  let a: SeededTenant;
  let b: SeededTenant;
  let platformToken: string;
  let snapshotB: unknown;

  beforeAll(async () => {
    harness = await TestHarness.start();
    await harness.reset();
    a = await harness.seedTenant('swpa');
    b = await harness.seedTenant('swpb');
    platformToken = await harness.seedPlatformAdmin();
    snapshotB = await snapshot(harness, b.id);
  });

  afterAll(async () => {
    await harness.stop();
  });

  const asA = (method: 'get' | 'post' | 'patch' | 'delete', path: string) =>
    request(harness.app.getHttpServer())
      [method](path)
      .set('Authorization', `Bearer ${a.users.owner.token}`);

  it('classifies every route the application actually serves', () => {
    const live = registeredRoutes(harness);
    const classified = Object.keys(ROUTES).sort();

    // Unclassified routes are the failure this suite exists to cause. A route that nobody
    // placed on one side of the tenant boundary has not been reasoned about, and in this
    // system that omission is a breach rather than an oversight.
    expect(live.filter((route) => !(route in ROUTES))).toEqual([]);
    // And the converse, so the table cannot drift into fiction: an entry for a route that no
    // longer exists would make the sweep below quietly stop testing something.
    expect(classified.filter((route) => !live.includes(route))).toEqual([]);
  });

  describe('a tenant token cannot reach the platform surface', () => {
    const platformRoutes = Object.entries(ROUTES).filter(([, spec]) => spec.cls === 'platform');

    it.each(platformRoutes)('%s refuses a tenant owner', async (route) => {
      const [method, path] = route.split(' ') as ['GET' | 'POST', string];
      const response = await asA(method.toLowerCase() as 'get' | 'post', path.replace(':id', b.id))
        .send({});

      // An owner is the most privileged principal inside a pharmacy and still has no standing
      // here. The guard checks `typ: 'platform'` rather than merely "is authenticated",
      // because a valid tenant token would otherwise satisfy an is-signed-in check.
      expect(response.status).toBe(401);
    });
  });

  describe('a tenant-scoped route never serves another tenant’s rows', () => {
    const tenantGets = Object.keys(ROUTES).filter(
      (route) => ROUTES[route].cls === 'tenant' && route.startsWith('GET ') && !route.includes(':'),
    );

    it.each(tenantGets)('%s, called with every identifier of the other tenant', async (route) => {
      const path = route.slice(4);

      // Every query parameter any of these routes accepts, all pointed at tenant B. Sending
      // the union rather than per-route arguments is deliberate: a route that grows a new
      // filter is swept by it immediately, with nobody remembering to update this file.
      const response = await asA('get', path).query({
        branchId: b.branchIds[0],
        streamId: b.id,
        actorId: b.users.owner.id,
        from: '2000-01-01',
        to: '2100-01-01',
        limit: 1000,
        cursor: 0,
        expiringWithinDays: 3650,
      });

      // A refusal is an acceptable answer; a leak is not. What must never happen is a 200
      // carrying B's data, so the assertion is on the payload rather than the status.
      const body = JSON.stringify(response.body ?? {});
      for (const [label, identifier] of identifiersOf(b)) {
        expect(`${route} leaked ${label}: ${body.slice(0, 400)}`).not.toContain(identifier);
        expect(body).not.toContain(identifier);
      }
    });
  });

  describe('a tenant-scoped route never acts on another tenant’s row', () => {
    const foreignIdRoutes: Array<[string, () => string]> = [
      ['PATCH /api/branches/:id', () => b.branchIds[0]],
      ['DELETE /api/users/:id', () => b.users.cashier.id],
      ['POST /api/products/:id/price', () => b.productId],
      ['GET /api/reports/cash-up/:shiftId', () => b.branchIds[0]],
    ];

    it.each(foreignIdRoutes)('%s, naming a row of the other tenant', async (route, idOf) => {
      const [method, template] = route.split(' ') as ['PATCH' | 'DELETE' | 'POST' | 'GET', string];
      const path = template.replace(/:[A-Za-z]+/, idOf());
      const before = await snapshot(harness, b.id);

      const response = await asA(method.toLowerCase() as 'patch' | 'delete' | 'post' | 'get', path)
        .send({ name: 'seized', priceSantim: 1, effectiveFrom: '2026-01-01' });

      expect(response.status).not.toBe(200);
      expect(response.status).not.toBe(201);

      // The status alone would be a weak assertion: a 400 from a validation pipe looks
      // identical to a refusal and proves nothing about what the row now holds. So the sweep
      // reads tenant B's state back over the owner connection, past RLS, and requires it
      // byte-identical.
      expect(await snapshot(harness, b.id)).toEqual(before);
    });
  });

  describe('a tenant-scoped write never creates a row under another tenant', () => {
    const writes: Array<[string, () => Record<string, unknown>]> = [
      ['POST /api/branches', () => ({ name: 'planted', tenantId: b.id })],
      [
        'POST /api/users',
        () => ({ username: 'planted', displayName: 'Planted', role: 'cashier', pin: '4321', tenantId: b.id, branchIds: [b.branchIds[0]] }),
      ],
      [
        'POST /api/products',
        () => ({ name: 'planted', unit: 'tablet', isControlled: false, currentPriceSantim: 100, tenantId: b.id }),
      ],
    ];

    it.each(writes)('%s, with the other tenant named in the body', async (route, bodyOf) => {
      const path = route.slice(5);
      const before = await snapshot(harness, b.id);

      // The interesting case is not a rejected request. It is an *accepted* one whose body
      // said `tenantId: b` — the request must succeed under A or fail, and either way B must
      // be untouched. Server-side scoping means the claim in the body is simply ignored.
      await asA('post', path).send(bodyOf());

      expect(await snapshot(harness, b.id)).toEqual(before);
    });
  });

  describe('a platform token cannot reach into a tenant', () => {
    const tenantRoutes = Object.keys(ROUTES).filter((route) => ROUTES[route].cls === 'tenant');

    it.each(tenantRoutes)('%s refuses a platform administrator', async (route) => {
      const [method, template] = route.split(' ') as ['GET' | 'POST' | 'PATCH' | 'DELETE', string];
      const path = template.replace(/:[A-Za-z]+/, b.branchIds[0]);

      const response = await request(harness.app.getHttpServer())
        [method.toLowerCase() as 'get' | 'post' | 'patch' | 'delete'](path)
        .set('Authorization', `Bearer ${platformToken}`)
        .send({});

      // BR-2.2: a platform administrator has no default access to tenant data. The token
      // carries no tenant at all, so the honest answer is a refusal — not an empty result.
      // An empty 200 would be the dangerous outcome: it reads as "this tenant has no
      // branches" and it means the route ran with an undefined scope, which the next raw
      // query added to that controller would happily interpolate.
      expect(response.status).toBe(401);

      // And nothing was touched on the way to being refused.
      expect(await snapshot(harness, b.id)).toEqual(snapshotB);
    });
  });

  it('sync/push refuses operations stamped with another tenant', async () => {
    const before = await snapshot(harness, b.id);

    const response = await asA('post', '/api/sync/push').send({
      terminalId: '01930000-0000-7000-8000-0000000000e1',
      operations: [
        {
          opId: '01930000-0000-7000-8000-0000000000f1',
          terminalId: '01930000-0000-7000-8000-0000000000e1',
          terminalSeq: 1,
          entityId: '01930000-0000-7000-8000-0000000000f2',
          entityType: 'goods_receipt',
          opType: 'create',
          baseVersion: null,
          // Tenant B, pushed on tenant A's token. The single most valuable forgery against
          // this system, because the push path writes.
          tenantId: b.id,
          branchId: b.branchIds[0],
          actorId: b.users.owner.id,
          clientTs: new Date().toISOString(),
          payload: {
            supplierName: 'planted',
            receivedAt: new Date().toISOString(),
            lines: [
              {
                id: '01930000-0000-7000-8000-0000000000f3',
                productId: b.productId,
                lotNo: 'PLANT',
                expiryDate: '2030-01-01',
                qty: 999,
                costSantim: 1,
              },
            ],
          },
        },
      ],
    });

    // A push is a batch, so the transport succeeds and the verdict is per operation — one
    // forged op must not cost a terminal the eighty legitimate ones queued behind it
    // (ADR-005). The refusal to look for is therefore in the ack, not the status line.
    expect(response.status).toBe(201);
    expect(response.body.acks[0].status).toBe('rejected');
    expect(response.body.acks[0].reason).toMatch(/tenant/i);

    // And the reason it was rejected is not the reason it is safe: the write is refused in
    // application code *and* would be refused by RLS underneath, independently (ADR-003).
    // Only B's actual state can show that neither layer let it through.
    expect(await snapshot(harness, b.id)).toEqual(before);
  });
});

/** Every identifier of a tenant that must never appear in another tenant's response. */
function identifiersOf(tenant: SeededTenant): Array<[string, string]> {
  return [
    ['tenant id', tenant.id],
    ['branch 1', tenant.branchIds[0]],
    ['branch 2', tenant.branchIds[1]],
    ['product', tenant.productId],
    ['controlled product', tenant.controlledProductId],
    ['batch 1', tenant.batchIds[0]],
    ['batch 2', tenant.batchIds[1]],
    ['owner', tenant.users.owner.id],
    ['manager', tenant.users.manager.id],
    ['cashier', tenant.users.cashier.id],
  ];
}

/**
 * Everything the platform (owner) connection can see for one tenant, as a comparable value.
 *
 * Read past RLS on purpose: a snapshot taken through the application's own connection would
 * be filtered by the very mechanism under test, and two empty results would compare equal
 * however much had changed.
 */
async function snapshot(harness: TestHarness, tenantId: string): Promise<unknown> {
  const tables = ['branch', 'app_user', 'product', 'stock_batch', 'sale', 'goods_receipt'];
  const rows: Record<string, unknown> = {};
  for (const table of tables) {
    rows[table] = await harness.platformDataSource.query(
      `SELECT * FROM ${table} WHERE tenant_id = $1 ORDER BY id`,
      [tenantId],
    );
  }
  return rows;
}
