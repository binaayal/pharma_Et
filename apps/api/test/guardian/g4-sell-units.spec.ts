import request from 'supertest';
import { pullResponse } from '@pharmaet/contracts';
import { TestHarness, type SeededTenant } from '../harness';
import { TERMINAL, receiptOp, saleOp } from '../helpers/build-ops';

/**
 * G4 / G5 — SELL UNITS (FR-11, ADR-030; contract 1.5.0).
 *
 * A pharmacy buys a box and sells a strip. This suite holds the two things that must both be
 * true once a line can be rung up in a pack:
 *
 *   - **the money is exact in the unit sold** — two boxes at the box price, to the santim,
 *     with no tablet price derived by division (G4);
 *   - **the shelf moves in base units** — those two boxes of thirty take sixty off the
 *     batch, and an oversell by the box is detected like any other (G5).
 *
 * And the third, which is the one that breaks quietly: a terminal that has never heard of
 * packs keeps syncing exactly as before (ADR-009).
 */
describe('G4 — sell units', () => {
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

  const push = (operations: unknown[], version?: string) => {
    const call = request(server())
      .post('/api/sync/push')
      .set('authorization', `Bearer ${tenant.users.cashier.token}`);
    if (version) call.set('x-contract-version', version);
    return call.send({ terminalId: TERMINAL, operations });
  };

  const as = (role: 'owner' | 'manager' | 'cashier') => ({
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

  const batchQty = async (batchId: string): Promise<number> =>
    Number(
      (await query(`SELECT qty_on_hand FROM stock_batch WHERE id = $1`, [batchId]))[0].qty_on_hand,
    );

  const BOX = { name: 'box', size: 30, priceSantim: 10_000 };
  const STRIP = { name: 'strip', size: 10, priceSantim: 3_600 };

  describe('a sale rung up by the pack', () => {
    it('records the pack count and the pack price, and the total is exact (G4)', async () => {
      // 100.00 for a box of 30. No whole number of santim per tablet multiplies to this —
      // which is the whole reason the line carries the pack rather than 30 tablets.
      const op = saleOp(tenant, {
        terminalSeq: 1,
        qty: 2,
        unitPriceSantim: 10_000,
        packSize: 30,
        packName: 'box',
      });
      const response = await push([op]).expect(201);
      expect(response.body.acks[0].status).toBe('applied');

      const [line] = await query(
        `SELECT qty, unit_price_santim, line_total_santim, pack_size, pack_name
           FROM sale_line WHERE sale_id = $1`,
        [op.entityId],
      );
      expect(Number(line.qty)).toBe(2);
      expect(Number(line.unit_price_santim)).toBe(10_000);
      expect(Number(line.line_total_santim)).toBe(20_000);
      expect(line.pack_size).toBe(30);
      expect(line.pack_name).toBe('box');

      const [sale] = await query(`SELECT total_santim FROM sale WHERE id = $1`, [op.entityId]);
      expect(Number(sale.total_santim)).toBe(20_000);
    });

    it('takes qty × pack size off the shelf, in base units', async () => {
      await query(`UPDATE stock_batch SET qty_on_hand = 100 WHERE id = $1`, [tenant.batchIds[1]]);

      await push([
        saleOp(tenant, { terminalSeq: 1, qty: 2, unitPriceSantim: 10_000, packSize: 30 }),
      ]).expect(201);

      expect(await batchQty(tenant.batchIds[1])).toBe(40);
    });

    it('detects an oversell by the box exactly as it does by the tablet (G5)', async () => {
      // The seeded batch holds 10. One box of 30 leaves it 20 short.
      const response = await push([
        saleOp(tenant, { terminalSeq: 1, qty: 1, unitPriceSantim: 10_000, packSize: 30 }),
      ]).expect(201);

      // Never blocked (BR-3.2): the box is already in the customer's bag.
      expect(response.body.acks[0].status).toBe('applied');
      expect(await batchQty(tenant.batchIds[1])).toBe(-20);

      const rows = await query(`SELECT resulting_qty FROM oversell_event WHERE tenant_id = $1`, [
        tenant.id,
      ]);
      expect(rows).toHaveLength(1);
      expect(Number(rows[0].resulting_qty)).toBe(-20);
    });

    it('moves stock once when the push is replayed (G2)', async () => {
      await query(`UPDATE stock_batch SET qty_on_hand = 100 WHERE id = $1`, [tenant.batchIds[1]]);
      const op = saleOp(tenant, { terminalSeq: 1, qty: 1, unitPriceSantim: 10_000, packSize: 30 });

      await push([op]).expect(201);
      const replay = await push([op]).expect(201);

      expect(replay.body.acks[0].status).toBe('duplicate');
      expect(await batchQty(tenant.batchIds[1])).toBe(70);
    });

    it('rejects a line whose total is not qty × the pack price — and writes nothing (G4)', async () => {
      const op = saleOp(tenant, { terminalSeq: 1, qty: 2, unitPriceSantim: 10_000, packSize: 30 });
      op.payload.lines[0].lineTotalSantim = 19_999;
      op.payload.totalSantim = 19_999;
      op.payload.payments[0].amountSantim = 19_999;

      await push([op]).expect(400);

      expect(await query(`SELECT 1 FROM sale WHERE id = $1`, [op.entityId])).toHaveLength(0);
      expect(await batchQty(tenant.batchIds[1])).toBe(10);
    });

    it.each([1, 0, -3, 2.5, 100_001])('refuses a pack size of %s at the boundary', async (size) => {
      const op = saleOp(tenant, { terminalSeq: 1, qty: 1, unitPriceSantim: 10_000 });
      (op.payload.lines[0] as Record<string, unknown>).packSize = size;
      await push([op]).expect(400);
      expect(await batchQty(tenant.batchIds[1])).toBe(10);
    });

    it('is refused by the database too, if a path skipped the contract', async () => {
      const op = saleOp(tenant, { terminalSeq: 1 });
      await push([op]).expect(201);
      await expect(
        query(`UPDATE sale_line SET pack_size = 1 WHERE sale_id = $1`, [op.entityId]),
      ).rejects.toThrow(/sale_line_pack_size_valid/);
    });
  });

  describe('a terminal that has never heard of packs (ADR-009)', () => {
    it('syncs a 1.4.0 sale unchanged: no pack on the row, qty off the shelf', async () => {
      const op = saleOp(tenant, { terminalSeq: 1, qty: 3 });
      expect(op.payload.lines[0]).not.toHaveProperty('packSize');

      const response = await push([op], '1.4.0').expect(201);
      expect(response.body.acks[0].status).toBe('applied');

      const [line] = await query(
        `SELECT qty, pack_size, pack_name FROM sale_line WHERE sale_id = $1`,
        [op.entityId],
      );
      expect(Number(line.qty)).toBe(3);
      expect(line.pack_size).toBeNull();
      expect(line.pack_name).toBeNull();
      expect(await batchQty(tenant.batchIds[1])).toBe(7);
    });

    it('accepts explicit nulls, which is what the generated Dart sends for a loose sale', async () => {
      const op = saleOp(tenant, { terminalSeq: 1, qty: 3 });
      Object.assign(op.payload.lines[0], { packSize: null, packName: null });

      await push([op]).expect(201);
      expect(await batchQty(tenant.batchIds[1])).toBe(7);
    });

    it('syncs a 1.4.0 receipt unchanged', async () => {
      const op = receiptOp(tenant, {
        terminalSeq: 1,
        qty: 40,
        lotNo: 'LOT-OLD',
        expiryDate: '2028-01-31',
      });
      const call = request(server())
        .post('/api/sync/push')
        .set('authorization', `Bearer ${tenant.users.manager.token}`)
        .set('x-contract-version', '1.4.0');
      await call.send({ terminalId: TERMINAL, operations: [op] }).expect(201);

      const [batch] = await query(`SELECT qty_on_hand FROM stock_batch WHERE lot_no = 'LOT-OLD'`);
      expect(Number(batch.qty_on_hand)).toBe(40);
    });
  });

  describe('a receipt counted by the pack', () => {
    const pushAsManager = (operations: unknown[]) =>
      request(server())
        .post('/api/sync/push')
        .set('authorization', `Bearer ${tenant.users.manager.token}`)
        .send({ terminalId: TERMINAL, operations });

    it('credits the shelf qty × pack size and keeps the invoice line as written', async () => {
      const op = receiptOp(tenant, {
        terminalSeq: 1,
        qty: 5,
        lotNo: 'LOT-BOX',
        expiryDate: '2028-01-31',
        packSize: 30,
        costSantim: 9_000,
      });
      const response = await pushAsManager([op]).expect(201);
      expect(response.body.acks[0].status).toBe('applied');

      const [batch] = await query(`SELECT qty_on_hand FROM stock_batch WHERE lot_no = 'LOT-BOX'`);
      expect(Number(batch.qty_on_hand)).toBe(150);

      // Five boxes at 90.00, not 150 tablets at 3.00: the second is not what the invoice
      // says, and the first is what a margin report will need to be exact.
      const [line] = await query(
        `SELECT qty, cost_santim, pack_size FROM goods_receipt_line WHERE goods_receipt_id = $1`,
        [op.entityId],
      );
      expect(Number(line.qty)).toBe(5);
      expect(Number(line.cost_santim)).toBe(9_000);
      expect(line.pack_size).toBe(30);
    });

    it('tops up an existing lot in base units', async () => {
      const first = receiptOp(tenant, {
        terminalSeq: 1,
        qty: 2,
        lotNo: 'LOT-MIX',
        expiryDate: '2028-01-31',
        packSize: 30,
      });
      const second = receiptOp(tenant, {
        terminalSeq: 2,
        qty: 7,
        lotNo: 'LOT-MIX',
        expiryDate: '2028-01-31',
      });
      await pushAsManager([first, second]).expect(201);

      const [batch] = await query(`SELECT qty_on_hand FROM stock_batch WHERE lot_no = 'LOT-MIX'`);
      expect(Number(batch.qty_on_hand)).toBe(67);
    });
  });

  describe("defining a product's packs", () => {
    const packsOf = async () =>
      (await query(`SELECT packs FROM product WHERE id = $1`, [tenant.productId]))[0].packs;

    it('lets an owner set them, and every terminal learns on its next pull', async () => {
      const cursor = (await as('cashier').get('/sync/pull?cursor=0').expect(200)).body.cursor;

      await as('owner')
        .post(`/products/${tenant.productId}/packs`, { packs: [STRIP, BOX] })
        .expect(201);

      // Only what changed since the cursor: without the bumped change_seq the counter
      // would go on selling by the tablet until something unrelated forced a full pull.
      const pull = await as('cashier').get(`/sync/pull?cursor=${cursor}`).expect(200);
      const parsed = pullResponse.parse(pull.body);
      expect(parsed.products).toHaveLength(1);
      expect(parsed.products[0].id).toBe(tenant.productId);
      expect(parsed.products[0].packs).toEqual([STRIP, BOX]);
    });

    it('sends an empty list, never nothing, for a product without packs', async () => {
      const pull = await as('cashier').get('/sync/pull?cursor=0').expect(200);
      const parsed = pullResponse.parse(pull.body);
      expect(parsed.products.length).toBeGreaterThan(0);
      for (const product of parsed.products) expect(product.packs).toEqual([]);
    });

    it('AC-2.1: a cashier is denied — a pack price is a price', async () => {
      await as('cashier')
        .post(`/products/${tenant.productId}/packs`, { packs: [BOX] })
        .expect(403);
      expect(await packsOf()).toEqual([]);
    });

    it('audits the change with the packs before and after', async () => {
      await as('owner')
        .post(`/products/${tenant.productId}/packs`, { packs: [BOX] })
        .expect(201);
      await as('owner')
        .post(`/products/${tenant.productId}/packs`, { packs: [{ ...BOX, priceSantim: 9_000 }] })
        .expect(201);

      const rows = await query(
        `SELECT payload, actor_id FROM event
          WHERE tenant_id = $1 AND event_type = 'audit.packs_changed' ORDER BY seq`,
        [tenant.id],
      );
      expect(rows).toHaveLength(2);
      expect(rows[1].actor_id).toBe(tenant.users.owner.id);
      expect(rows[1].payload.previous).toEqual([BOX]);
      expect(rows[1].payload.packs).toEqual([{ ...BOX, priceSantim: 9_000 }]);
    });

    it('does not rewrite a sale already rung up when a pack is later changed', async () => {
      await as('owner')
        .post(`/products/${tenant.productId}/packs`, { packs: [BOX] })
        .expect(201);
      const op = saleOp(tenant, { terminalSeq: 1, qty: 1, unitPriceSantim: 10_000, packSize: 30 });
      await push([op]).expect(201);

      await as('owner')
        .post(`/products/${tenant.productId}/packs`, {
          packs: [{ name: 'box', size: 50, priceSantim: 15_000 }],
        })
        .expect(201);

      const [line] = await query(
        `SELECT pack_size, unit_price_santim FROM sale_line WHERE sale_id = $1`,
        [op.entityId],
      );
      expect(line.pack_size).toBe(30);
      expect(Number(line.unit_price_santim)).toBe(10_000);
    });

    it("applies a sale in a pack the product no longer has — the till's figure is the record", async () => {
      // A terminal offline for days holds yesterday's packs. Its sale still happened.
      const response = await push([
        saleOp(tenant, { terminalSeq: 1, qty: 1, unitPriceSantim: 4_200, packSize: 12 }),
      ]).expect(201);
      expect(response.body.acks[0].status).toBe('applied');
      expect(await batchQty(tenant.batchIds[1])).toBe(-2);
    });

    it.each([
      ['a fractional pack price', [{ ...BOX, priceSantim: 99.5 }]],
      ['a pack of one', [{ ...BOX, size: 1 }]],
      ['two packs with one name', [BOX, { ...STRIP, name: 'Box' }]],
      ['two packs of one size', [BOX, { ...STRIP, size: 30 }]],
      ['a nameless pack', [{ ...BOX, name: '  ' }]],
      [
        'more packs than anyone has',
        [2, 3, 4, 5, 6].map((n) => ({ name: `p${n}`, size: n, priceSantim: 100 })),
      ],
    ])('refuses %s and leaves the product as it was', async (_what, packs) => {
      await as('owner').post(`/products/${tenant.productId}/packs`, { packs }).expect(400);
      expect(await packsOf()).toEqual([]);
    });

    it('refuses packs on a controlled substance — the ledger counts in one unit', async () => {
      await as('owner')
        .post(`/products/${tenant.controlledProductId}/packs`, { packs: [BOX] })
        .expect(400);
    });

    it('creates a product with its packs in one step', async () => {
      const created = await as('owner')
        .post('/products', {
          name: 'Amoxicillin 500mg',
          unit: 'capsule',
          priceSantim: 400,
          packs: [STRIP],
        })
        .expect(201);

      const [row] = await query(`SELECT packs FROM product WHERE id = $1`, [created.body.id]);
      expect(row.packs).toEqual([STRIP]);
    });
  });
});
