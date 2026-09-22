import request from 'supertest';
import { salePayload, santim } from '@pharmaet/contracts';
import { TestHarness, type SeededTenant } from '../harness';
import { TERMINAL, saleOp } from '../helpers/build-ops';

/**
 * G4 — MONEY INTEGRITY (docs/05-qa §4).
 *
 * The invariant: money is an integer count of santim everywhere, and a sale's total equals
 * the sum of its line totals.
 *
 * Money errors are S1 (docs/05-qa §14) and, unlike a crash, they are invisible: a rounding
 * drift of a few santim per sale is never noticed until the till does not reconcile. So the
 * rule is enforced three times over — in the contract, in the domain, and in the database —
 * because each layer can be bypassed by a path that skips the others.
 */
describe('G4 — money integrity', () => {
  let harness: TestHarness;
  let tenant: SeededTenant;
  const server = () => harness.app.getHttpServer();

  beforeAll(async () => {
    harness = await TestHarness.start();
  });

  beforeEach(async () => {
    await harness.reset();
    tenant = await harness.seedTenant('abay', 1999);
  });

  afterAll(async () => harness?.stop());

  const push = (operations: unknown[]) =>
    request(server())
      .post('/api/sync/push')
      .set('authorization', `Bearer ${tenant.users.cashier.token}`)
      .send({ terminalId: TERMINAL, operations });

  it('rejects a fractional amount at the contract boundary', () => {
    expect(santim.safeParse(19.99).success).toBe(false);
    expect(santim.safeParse(1999).success).toBe(true);
  });

  it('rejects a sale whose total does not equal the sum of its lines', () => {
    const op = saleOp(tenant, { terminalSeq: 1, qty: 3, unitPriceSantim: 1999 });
    const tampered = { ...op.payload, totalSantim: op.payload.totalSantim - 1 };
    expect(salePayload.safeParse(tampered).success).toBe(false);
  });

  it('refuses an inconsistent total over the wire, not just in a unit test', async () => {
    const op = saleOp(tenant, { terminalSeq: 1, qty: 3, unitPriceSantim: 1999, totalOverride: 1 });
    await push([op]).expect(400);
  });

  it('stores money exactly, with no drift through the driver', async () => {
    // 1999 santim x 7 = 13,993. A float pipeline anywhere in this path would show up as
    // 13992.999... or a silently rounded 13993.0 that is no longer an integer.
    await push([saleOp(tenant, { terminalSeq: 1, qty: 7, unitPriceSantim: 1999 })]).expect(201);

    const rows = await harness.platformDataSource.query(
      `SELECT total_santim, pg_typeof(total_santim)::text AS type FROM sale WHERE tenant_id = $1`,
      [tenant.id],
    );
    expect(rows[0].type).toBe('bigint');
    expect(Number(rows[0].total_santim)).toBe(13993);
  });

  it('keeps sale totals equal to the sum of their lines in the database', async () => {
    await push([
      saleOp(tenant, { terminalSeq: 1, qty: 2, unitPriceSantim: 1999 }),
      saleOp(tenant, { terminalSeq: 2, qty: 5, unitPriceSantim: 733 }),
      saleOp(tenant, { terminalSeq: 3, qty: 1, unitPriceSantim: 1 }),
    ]).expect(201);

    const mismatches = await harness.platformDataSource.query(
      `SELECT s.id
         FROM sale s
         JOIN (SELECT sale_id, sum(line_total_santim) AS total
                 FROM sale_line GROUP BY sale_id) l ON l.sale_id = s.id
        WHERE s.tenant_id = $1 AND s.total_santim <> l.total`,
      [tenant.id],
    );
    expect(mismatches).toHaveLength(0);
  });

  it('reconciles payments against sale totals', async () => {
    await push([saleOp(tenant, { terminalSeq: 1, qty: 4, unitPriceSantim: 1999 })]).expect(201);

    const rows = await harness.platformDataSource.query(
      `SELECT s.total_santim, sum(p.amount_santim) AS paid
         FROM sale s JOIN payment p ON p.sale_id = s.id
        WHERE s.tenant_id = $1 GROUP BY s.id, s.total_santim`,
      [tenant.id],
    );
    expect(rows).toHaveLength(1);
    expect(Number(rows[0].paid)).toBe(Number(rows[0].total_santim));
  });

  it('will not accept an inconsistent line total even from a direct database write', async () => {
    // The database constraint is the last line of defence, for any path that bypassed the
    // contract and the domain — a migration, a support script, a future endpoint.
    await expect(
      harness.platformDataSource.query(
        `INSERT INTO sale_line (id, tenant_id, sale_id, product_id, qty, unit_price_santim, line_total_santim)
         VALUES ($1, $2, $3, $4, 3, 1000, 2999)`,
        [
          '01930000-0000-7000-8000-0000000000c1',
          tenant.id,
          '01930000-0000-7000-8000-0000000000c2',
          tenant.productId,
        ],
      ),
    ).rejects.toThrow();
  });
});
