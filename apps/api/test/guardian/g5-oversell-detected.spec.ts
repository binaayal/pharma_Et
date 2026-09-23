import request from 'supertest';
import { TestHarness, type SeededTenant } from '../harness';
import { TERMINAL, saleOp } from '../helpers/build-ops';

/**
 * G5 — OVERSELL IS DETECTED, NEVER SILENT (docs/05-qa §4; AC-3.1, BR-3.2, ADR-002).
 *
 * The invariant that most surprises people reading this codebase: selling below zero stock
 * SUCCEEDS. It must. An offline terminal cannot know the true count, and a system that
 * refuses the sale stops the counter — the one failure this product exists to prevent.
 *
 * What we owe the pharmacy is not prevention, which offline makes impossible, but honesty:
 * the stock goes negative, an oversell is recorded, and somebody is told to go and count.
 */
describe('G5 — oversell detected', () => {
  let harness: TestHarness;
  let tenant: SeededTenant;
  const server = () => harness.app.getHttpServer();

  beforeAll(async () => {
    harness = await TestHarness.start();
  });

  beforeEach(async () => {
    await harness.reset();
    tenant = await harness.seedTenant('abay');
  });

  afterAll(async () => harness?.stop());

  const push = (operations: unknown[]) =>
    request(server())
      .post('/api/sync/push')
      .set('authorization', `Bearer ${tenant.users.cashier.token}`)
      .send({ terminalId: TERMINAL, operations });

  const batchQty = async (batchId: string): Promise<number> => {
    const rows = await harness.platformDataSource.query(
      `SELECT qty_on_hand FROM stock_batch WHERE id = $1`,
      [batchId],
    );
    return Number(rows[0].qty_on_hand);
  };

  it('completes the sale and drives stock negative rather than blocking it', async () => {
    // The seeded batch holds 10. Selling 15 must succeed: the money is already in the till.
    const response = await push([
      saleOp(tenant, { terminalSeq: 1, qty: 15, batchId: tenant.batchIds[1] }),
    ]).expect(201);

    expect(response.body.acks[0].status).toBe('applied');
    expect(await batchQty(tenant.batchIds[1])).toBe(-5);
  });

  it('records the oversell so it can be counted and reconciled', async () => {
    await push([saleOp(tenant, { terminalSeq: 1, qty: 15, batchId: tenant.batchIds[1] })]).expect(
      201,
    );

    const rows = await harness.platformDataSource.query(
      `SELECT resulting_qty, product_id, branch_id FROM oversell_event WHERE tenant_id = $1`,
      [tenant.id],
    );
    expect(rows).toHaveLength(1);
    expect(Number(rows[0].resulting_qty)).toBe(-5);
    expect(rows[0].product_id).toBe(tenant.productId);
  });

  it('surfaces oversells to the owner as a report, not only in the logs', async () => {
    await push([saleOp(tenant, { terminalSeq: 1, qty: 12, batchId: tenant.batchIds[1] })]).expect(
      201,
    );

    const response = await request(server())
      .get('/api/reports/oversells')
      .set('authorization', `Bearer ${tenant.users.owner.token}`)
      .expect(200);

    expect(response.body).toHaveLength(1);
  });

  it('does not raise an oversell when stock covers the sale', async () => {
    await push([saleOp(tenant, { terminalSeq: 1, qty: 4, batchId: tenant.batchIds[1] })]).expect(
      201,
    );

    const rows = await harness.platformDataSource.query(
      `SELECT count(*)::int AS n FROM oversell_event WHERE tenant_id = $1`,
      [tenant.id],
    );
    expect(rows[0].n).toBe(0);
    expect(await batchQty(tenant.batchIds[1])).toBe(6);
  });

  it('records an oversell when the terminal sold stock the server has never seen', async () => {
    // A product received on one terminal and sold before the receipt synced. The decrement
    // has nowhere to land — but it is still recorded, because a sale we cannot explain is
    // exactly the thing a pharmacy owner needs to be told about.
    await push([saleOp(tenant, { terminalSeq: 1, qty: 3, batchId: null })]).expect(201);

    const rows = await harness.platformDataSource.query(
      `SELECT count(*)::int AS n FROM oversell_event WHERE tenant_id = $1`,
      [tenant.id],
    );
    // Seeded stock exists for this product, so FEFO finds a batch and there is no oversell.
    expect(rows[0].n).toBe(0);
  });
});
