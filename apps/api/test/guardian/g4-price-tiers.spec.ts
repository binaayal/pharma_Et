import request from 'supertest';
import { pullResponse } from '@pharmaet/contracts';
import { TestHarness, type SeededTenant } from '../harness';
import { TERMINAL, saleOp } from '../helpers/build-ops';

/**
 * G4 — PRICE TIERS (FR-19, ADR-037; contract 1.8.0).
 *
 * A pharmacy sells to a walk-in customer at one price and to a clinic at another. Once a
 * product can carry both, three things must hold:
 *
 *   - **the price charged is the price recorded** — a wholesale sale is exact at the
 *     wholesale price, and the tier is a label on the sale, never a recalculation (G4);
 *   - **a wholesale price is a price** — set only by someone who may set prices, audited
 *     with before and after, and carried to every terminal;
 *   - a terminal that has never heard of tiers keeps selling at the one price it knows
 *     (ADR-009).
 */
describe('G4 — price tiers', () => {
  let harness: TestHarness;
  let a: SeededTenant;
  let b: SeededTenant;
  const server = () => harness.app.getHttpServer();

  beforeAll(async () => {
    harness = await TestHarness.start();
  });

  beforeEach(async () => {
    await harness.reset();
    a = await harness.seedTenant('abay');
    b = await harness.seedTenant('blue');
  });

  afterAll(async () => harness?.stop());

  const push = (operations: unknown[], version?: string) => {
    const call = request(server())
      .post('/api/sync/push')
      .set('authorization', `Bearer ${a.users.cashier.token}`);
    if (version) call.set('x-contract-version', version);
    return call.send({ terminalId: TERMINAL, operations });
  };

  const as = (tenant: SeededTenant, role: 'owner' | 'manager' | 'cashier') => ({
    post: (path: string, body: unknown) =>
      request(server())
        .post(`/api${path}`)
        .set('authorization', `Bearer ${tenant.users[role].token}`)
        .send(body as object),
    get: (path: string) =>
      request(server())
        .get(`/api${path}`)
        .set('authorization', `Bearer ${tenant.users[role].token}`),
  });

  const query = (sql: string, params: unknown[] = []) =>
    harness.platformDataSource.query(sql, params);

  const wholesaleOf = async (productId: string): Promise<number | null> => {
    const [row] = await query(`SELECT wholesale_price_santim FROM product WHERE id = $1`, [
      productId,
    ]);
    return row.wholesale_price_santim === null ? null : Number(row.wholesale_price_santim);
  };

  describe('a sale rung up at wholesale', () => {
    it('records the tier, and the price that was actually charged (G4)', async () => {
      // Retail is 15.00. This clinic pays 12.00.
      const op = saleOp(a, {
        terminalSeq: 1,
        qty: 10,
        unitPriceSantim: 1200,
        priceTier: 'wholesale',
      });
      const response = await push([op]).expect(201);
      expect(response.body.acks[0].status).toBe('applied');

      const [sale] = await query(`SELECT price_tier, total_santim FROM sale WHERE id = $1`, [
        op.entityId,
      ]);
      expect(sale.price_tier).toBe('wholesale');
      expect(Number(sale.total_santim)).toBe(12000);

      const [line] = await query(
        `SELECT qty, unit_price_santim, line_total_santim FROM sale_line WHERE sale_id = $1`,
        [op.entityId],
      );
      // Stored as sent — not re-priced from the catalogue, in either direction.
      expect(Number(line.unit_price_santim)).toBe(1200);
      expect(Number(line.line_total_santim)).toBe(Number(line.qty) * 1200);
    });

    it('takes the same stock off the shelf as any other sale', async () => {
      await push([
        saleOp(a, { terminalSeq: 1, qty: 4, unitPriceSantim: 1200, priceTier: 'wholesale' }),
      ]).expect(201);
      const [batch] = await query(`SELECT qty_on_hand FROM stock_batch WHERE id = $1`, [
        a.batchIds[1],
      ]);
      expect(Number(batch.qty_on_hand)).toBe(6);
    });

    it('does not let the tier excuse a total that is not qty × the price (G4)', async () => {
      const op = saleOp(a, {
        terminalSeq: 1,
        qty: 10,
        unitPriceSantim: 1200,
        priceTier: 'wholesale',
      });
      op.payload.lines[0].lineTotalSantim = 11000;
      op.payload.totalSantim = 11000;
      await push([op]).expect(400);
      expect(await query(`SELECT 1 FROM sale WHERE id = $1`, [op.entityId])).toHaveLength(0);
    });

    it('refuses a tier that is not one of the two', async () => {
      const op = saleOp(a, { terminalSeq: 1 });
      (op.payload as Record<string, unknown>).priceTier = 'staff';
      await push([op]).expect(400);
    });

    it('applies a wholesale sale at a price the product no longer has', async () => {
      // A till offline for days holds yesterday's price list. The sale still happened.
      await as(a, 'owner')
        .post(`/products/${a.productId}/wholesale-price`, { priceSantim: 1300 })
        .expect(201);
      const response = await push([
        saleOp(a, { terminalSeq: 1, qty: 2, unitPriceSantim: 1100, priceTier: 'wholesale' }),
      ]).expect(201);
      expect(response.body.acks[0].status).toBe('applied');
    });

    it('is reported apart, as part of what was sold', async () => {
      await push([
        saleOp(a, { terminalSeq: 1, qty: 2 }), // retail, 30.00
        saleOp(a, { terminalSeq: 2, qty: 10, unitPriceSantim: 1200, priceTier: 'wholesale' }), // 120.00
      ]).expect(201);

      const total = (
        await as(a, 'owner')
          .get('/reports/sales-summary?from=2026-09-01T00:00:00.000Z&to=2026-12-01T00:00:00.000Z')
          .expect(200)
      ).body.total;
      expect(total.grossSantim).toBe(15000);
      expect(total.wholesaleSantim).toBe(12000);
    });
  });

  describe('a terminal that has never heard of tiers (ADR-009)', () => {
    it('syncs a 1.7.0 sale unchanged: no tier on the row', async () => {
      const op = saleOp(a, { terminalSeq: 1 });
      expect(op.payload).not.toHaveProperty('priceTier');
      const response = await push([op], '1.7.0').expect(201);
      expect(response.body.acks[0].status).toBe('applied');

      const [sale] = await query(`SELECT price_tier FROM sale WHERE id = $1`, [op.entityId]);
      expect(sale.price_tier).toBeNull();
    });

    it('stores retail one way — null — however it is spelled on the wire', async () => {
      const explicit = saleOp(a, { terminalSeq: 1, priceTier: 'retail' });
      const nulled = saleOp(a, { terminalSeq: 2 });
      (nulled.payload as Record<string, unknown>).priceTier = null;
      await push([explicit, nulled]).expect(201);

      const rows = await query(`SELECT price_tier FROM sale WHERE tenant_id = $1`, [a.id]);
      expect(rows.map((r: { price_tier: string | null }) => r.price_tier)).toEqual([null, null]);
    });

    it('is refused by the database too, if a path skipped the contract', async () => {
      const op = saleOp(a, { terminalSeq: 1 });
      await push([op]).expect(201);
      await expect(
        query(`UPDATE sale SET price_tier = 'staff' WHERE id = $1`, [op.entityId]),
      ).rejects.toThrow(/sale_price_tier_known/);
    });
  });

  describe('setting a wholesale price', () => {
    it('lets an owner set it, and every terminal learns on its next pull', async () => {
      const cursor = (await as(a, 'cashier').get('/sync/pull?cursor=0').expect(200)).body.cursor;

      const response = await as(a, 'owner')
        .post(`/products/${a.productId}/wholesale-price`, { priceSantim: 1200 })
        .expect(201);
      expect(response.body).toMatchObject({ previousPriceSantim: null, priceSantim: 1200 });

      const parsed = pullResponse.parse(
        (await as(a, 'cashier').get(`/sync/pull?cursor=${cursor}`).expect(200)).body,
      );
      expect(parsed.products).toHaveLength(1);
      expect(parsed.products[0].wholesalePriceSantim).toBe(1200);
      // The retail price is untouched.
      expect(parsed.products[0].currentPriceSantim).toBe(1500);
    });

    it('sends null, never nothing, for a product without one', async () => {
      const parsed = pullResponse.parse(
        (await as(a, 'cashier').get('/sync/pull?cursor=0').expect(200)).body,
      );
      for (const product of parsed.products) expect(product.wholesalePriceSantim).toBeNull();
    });

    it('AC-2.1: a cashier is denied', async () => {
      await as(a, 'cashier')
        .post(`/products/${a.productId}/wholesale-price`, { priceSantim: 1 })
        .expect(403);
      expect(await wholesaleOf(a.productId)).toBeNull();
    });

    it('audits the change with the price before and after', async () => {
      await as(a, 'owner')
        .post(`/products/${a.productId}/wholesale-price`, { priceSantim: 1200 })
        .expect(201);
      await as(a, 'owner')
        .post(`/products/${a.productId}/wholesale-price`, { priceSantim: 900 })
        .expect(201);

      const rows = await query(
        `SELECT payload, actor_id FROM event
          WHERE tenant_id = $1 AND event_type = 'audit.wholesale_price_changed' ORDER BY seq`,
        [a.id],
      );
      expect(rows).toHaveLength(2);
      expect(rows[1].actor_id).toBe(a.users.owner.id);
      expect(rows[1].payload).toMatchObject({ previousPriceSantim: 1200, priceSantim: 900 });
    });

    it('can be removed, and the product goes back to one price', async () => {
      await as(a, 'owner')
        .post(`/products/${a.productId}/wholesale-price`, { priceSantim: 1200 })
        .expect(201);
      await as(a, 'owner')
        .post(`/products/${a.productId}/wholesale-price`, { priceSantim: null })
        .expect(201);
      expect(await wholesaleOf(a.productId)).toBeNull();
    });

    it.each([-1, 12.5, 'cheap'])(
      'refuses %s and leaves the product as it was',
      async (priceSantim) => {
        await as(a, 'owner')
          .post(`/products/${a.productId}/wholesale-price`, { priceSantim })
          .expect(400);
        expect(await wholesaleOf(a.productId)).toBeNull();
      },
    );

    it('refuses one on a controlled substance', async () => {
      await as(a, 'owner')
        .post(`/products/${a.controlledProductId}/wholesale-price`, { priceSantim: 3000 })
        .expect(400);
    });

    it('cannot reprice a product of another pharmacy (G1)', async () => {
      const response = await as(a, 'owner').post(`/products/${b.productId}/wholesale-price`, {
        priceSantim: 1,
      });
      expect(response.status).toBe(404);
      expect(await wholesaleOf(b.productId)).toBeNull();
    });

    it("never tells one pharmacy another's wholesale price", async () => {
      await as(b, 'owner')
        .post(`/products/${b.productId}/wholesale-price`, { priceSantim: 777 })
        .expect(201);
      const pull = (await as(a, 'cashier').get('/sync/pull?cursor=0').expect(200)).body;
      expect(JSON.stringify(pull)).not.toContain('777');
    });
  });

  describe('a pack with a wholesale price', () => {
    const BOX = { name: 'box', size: 30, priceSantim: 10_000, wholesalePriceSantim: 9_000 };

    it('is stored and pulled with both its prices', async () => {
      await as(a, 'owner')
        .post(`/products/${a.productId}/packs`, { packs: [BOX] })
        .expect(201);
      const parsed = pullResponse.parse(
        (await as(a, 'cashier').get('/sync/pull?cursor=0').expect(200)).body,
      );
      const product = parsed.products.find((p) => p.id === a.productId);
      expect(product?.packs).toEqual([BOX]);
    });

    it('refuses a fractional wholesale price on a pack (G4)', async () => {
      await as(a, 'owner')
        .post(`/products/${a.productId}/packs`, { packs: [{ ...BOX, wholesalePriceSantim: 89.5 }] })
        .expect(400);
    });

    it("sells by the box at the box's wholesale price, stock in base units", async () => {
      await query(`UPDATE stock_batch SET qty_on_hand = 100 WHERE id = $1`, [a.batchIds[1]]);
      const op = saleOp(a, {
        terminalSeq: 1,
        qty: 2,
        unitPriceSantim: 9_000,
        packSize: 30,
        packName: 'box',
        priceTier: 'wholesale',
      });
      await push([op]).expect(201);

      const [sale] = await query(`SELECT price_tier, total_santim FROM sale WHERE id = $1`, [
        op.entityId,
      ]);
      expect(sale.price_tier).toBe('wholesale');
      expect(Number(sale.total_santim)).toBe(18_000);
      const [batch] = await query(`SELECT qty_on_hand FROM stock_batch WHERE id = $1`, [
        a.batchIds[1],
      ]);
      expect(Number(batch.qty_on_hand)).toBe(40);
    });
  });

  it('creates a product with a wholesale price in one step', async () => {
    const created = await as(a, 'owner')
      .post('/products', {
        name: 'Ibuprofen 400mg',
        unit: 'tablet',
        priceSantim: 300,
        wholesalePriceSantim: 250,
      })
      .expect(201);
    expect(await wholesaleOf(created.body.id)).toBe(250);
  });
});
