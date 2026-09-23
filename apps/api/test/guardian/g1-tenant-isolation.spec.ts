import request from 'supertest';
import { TestHarness, type SeededTenant } from '../harness';

/**
 * G1 — TENANT ISOLATION (docs/05-qa §4).
 *
 * The invariant: no API call, and no repository call, ever returns another tenant's row —
 * and the guarantee does not rest on application code remembering to filter.
 *
 * Cross-tenant leakage is an S1 (docs/05-qa §14). In a regulated, multi-tenant system it is
 * also the one bug a customer can never forgive, so it is tested from both sides: through
 * the API, and directly against the database with the scope deliberately withheld.
 */
describe('G1 — tenant isolation', () => {
  let harness: TestHarness;
  let abay: SeededTenant;
  let tana: SeededTenant;

  beforeAll(async () => {
    harness = await TestHarness.start();
    await harness.reset();
    abay = await harness.seedTenant('abay');
    tana = await harness.seedTenant('tana');
  });

  afterAll(async () => harness?.stop());

  it("never returns another tenant's reference data through the sync pull", async () => {
    const response = await request(harness.app.getHttpServer())
      .get('/api/sync/pull?cursor=0')
      .set('authorization', `Bearer ${abay.users.owner.token}`)
      .expect(200);

    const names: string[] = response.body.products.map((p: { name: string }) => p.name);
    expect(names).toEqual(expect.arrayContaining(['abay paracetamol']));
    expect(names.some((n) => n.startsWith('tana'))).toBe(false);

    const branchIds: string[] = response.body.branches.map((b: { id: string }) => b.id);
    expect(branchIds).not.toEqual(expect.arrayContaining(tana.branchIds));
  });

  it('refuses a pushed operation that claims a different tenant than the token', async () => {
    const response = await request(harness.app.getHttpServer())
      .post('/api/sync/push')
      .set('authorization', `Bearer ${abay.users.cashier.token}`)
      .send({
        terminalId: '01930000-0000-7000-8000-0000000000e1',
        operations: [
          {
            opId: '01930000-0000-7000-8000-0000000000f1',
            terminalId: '01930000-0000-7000-8000-0000000000e1',
            terminalSeq: 1,
            entityId: '01930000-0000-7000-8000-0000000000f2',
            opType: 'create',
            baseVersion: null,
            // The hostile part: another tenant's id, on an otherwise valid operation.
            tenantId: tana.id,
            branchId: tana.branchIds[0],
            actorId: abay.users.cashier.id,
            clientTs: '2026-09-22T08:30:00Z',
            entityType: 'sale',
            payload: {
              shiftId: null,
              cashierId: abay.users.cashier.id,
              soldAt: '2026-09-22T08:30:00Z',
              totalSantim: 1500,
              lines: [
                {
                  id: '01930000-0000-7000-8000-0000000000f3',
                  productId: tana.productId,
                  batchId: null,
                  qty: 1,
                  unitPriceSantim: 1500,
                  lineTotalSantim: 1500,
                },
              ],
              payments: [
                {
                  id: '01930000-0000-7000-8000-0000000000f4',
                  method: 'cash',
                  amountSantim: 1500,
                },
              ],
            },
          },
        ],
      })
      .expect(201);

    expect(response.body.acks[0].status).toBe('rejected');

    // And nothing landed in the victim tenant.
    const rows = await harness.platformDataSource.query(
      `SELECT count(*)::int AS n FROM sale WHERE tenant_id = $1`,
      [tana.id],
    );
    expect(rows[0].n).toBe(0);
  });

  it('returns nothing at all when the tenant scope is withheld — RLS, not app code', async () => {
    // This is the backstop under test. The query has no tenant predicate and no scope has
    // been set, so RLS must default to deny. If this ever returns rows, every "we filter by
    // tenant in the repository" assurance in the codebase is worthless.
    const runner = harness.appDataSource.createQueryRunner();
    await runner.connect();
    try {
      const products = await runner.query(`SELECT id FROM product`);
      const sales = await runner.query(`SELECT id FROM sale`);
      const tenants = await runner.query(`SELECT id FROM tenant`);
      expect(products).toHaveLength(0);
      expect(sales).toHaveLength(0);
      expect(tenants).toHaveLength(0);
    } finally {
      await runner.release();
    }
  });

  it("returns exactly one tenant's rows when the scope IS set", async () => {
    // The mirror of the test above: proof that the previous result was RLS doing its job,
    // not an empty database or a broken connection.
    const runner = harness.appDataSource.createQueryRunner();
    await runner.connect();
    await runner.startTransaction();
    try {
      await runner.query('SELECT set_config($1, $2, true)', ['app.current_tenant', abay.id]);
      const products = await runner.query(`SELECT name FROM product`);
      expect(products.length).toBeGreaterThan(0);
      expect(products.every((p: { name: string }) => p.name.startsWith('abay'))).toBe(true);
      await runner.commitTransaction();
    } finally {
      await runner.release();
    }
  });

  it('cannot write into another tenant even with an explicit tenant_id', async () => {
    const runner = harness.appDataSource.createQueryRunner();
    await runner.connect();
    await runner.startTransaction();
    try {
      await runner.query('SELECT set_config($1, $2, true)', ['app.current_tenant', abay.id]);
      // WITH CHECK on the policy must refuse a row written into a tenant we are not scoped
      // to — otherwise isolation would only protect reads.
      await expect(
        runner.query(`INSERT INTO branch (id, tenant_id, name) VALUES ($1, $2, 'smuggled')`, [
          '01930000-0000-7000-8000-0000000000ff',
          tana.id,
        ]),
      ).rejects.toThrow();
      await runner.rollbackTransaction();
    } finally {
      await runner.release();
    }
  });
});
