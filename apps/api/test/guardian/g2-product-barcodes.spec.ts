import request from 'supertest';
import { pullResponse } from '@pharmaet/contracts';
import { TestHarness, type SeededTenant } from '../harness';

/**
 * G2 / G1 — PRODUCT BARCODES (FR-13, ADR-031; contract 1.6.0).
 *
 * A scan is only as good as the link behind it. This suite holds the three things a wrong
 * link would break without anyone noticing:
 *
 *   - **one spelling** — the 13 digits on a box and the 14 inside its DataMatrix are stored
 *     as the same value, or a product linked one way is not found the other;
 *   - **one product per barcode** within a pharmacy — otherwise a scan picks between two
 *     prices, silently;
 *   - **per pharmacy** — two pharmacies stock the same box, and neither's link is the
 *     other's business (G1).
 *
 * And that a terminal which has never heard of barcodes keeps pulling its catalogue (ADR-009).
 */
describe('G2 — product barcodes', () => {
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

  const as = (tenant: SeededTenant, role: 'owner' | 'manager' | 'cashier') => ({
    post: (path: string, body: unknown) =>
      request(server())
        .post(`/api${path}`)
        .set('authorization', `Bearer ${tenant.users[role].token}`)
        .send(body as object),
    get: (path: string, version?: string) => {
      const call = request(server())
        .get(`/api${path}`)
        .set('authorization', `Bearer ${tenant.users[role].token}`);
      return version ? call.set('x-contract-version', version) : call;
    },
  });

  const stored = async (productId: string): Promise<string[]> =>
    (
      await harness.platformDataSource.query(`SELECT barcodes FROM product WHERE id = $1`, [
        productId,
      ])
    )[0].barcodes;

  const EAN13 = '6291100080014';
  const GTIN14 = '06291100080014';

  /** A second standard product in tenant A, so a barcode has somewhere else it could go. */
  const secondProduct = async (): Promise<string> =>
    (
      await as(a, 'owner')
        .post('/products', { name: 'Ibuprofen 400mg tablet', unit: 'tablet', priceSantim: 300 })
        .expect(201)
    ).body.id;

  describe('one spelling', () => {
    it('stores the EAN-13 on the box as the 14-digit GTIN', async () => {
      const response = await as(a, 'owner')
        .post(`/products/${a.productId}/barcodes`, { barcodes: [EAN13] })
        .expect(201);

      expect(response.body.barcodes).toEqual([GTIN14]);
      expect(await stored(a.productId)).toEqual([GTIN14]);
    });

    it('treats the two spellings of one GTIN as one barcode, not two', async () => {
      await as(a, 'owner')
        .post(`/products/${a.productId}/barcodes`, { barcodes: [EAN13, GTIN14, ` ${EAN13} `] })
        .expect(201);
      expect(await stored(a.productId)).toEqual([GTIN14]);
    });

    it('keeps an in-house label exactly as read', async () => {
      await as(a, 'owner')
        .post(`/products/${a.productId}/barcodes`, { barcodes: ['SHELF-0042'] })
        .expect(201);
      expect(await stored(a.productId)).toEqual(['SHELF-0042']);
    });

    it.each([
      ['a code with a space in it', ['has space 1']],
      ['a code too short to be one', ['abc']],
      ['a raw DataMatrix with its separator', ['\u001d0106291100080014']],
      [
        'more barcodes than one product has',
        Array.from({ length: 13 }, (_, i) => `CODE-${1000 + i}`),
      ],
    ])('refuses %s and leaves the product as it was', async (_what, barcodes) => {
      await as(a, 'owner').post(`/products/${a.productId}/barcodes`, { barcodes }).expect(400);
      expect(await stored(a.productId)).toEqual([]);
    });
  });

  describe('one product per barcode, within a pharmacy', () => {
    it('refuses a barcode another product already carries, and names that product', async () => {
      const other = await secondProduct();
      await as(a, 'owner')
        .post(`/products/${a.productId}/barcodes`, { barcodes: [EAN13] })
        .expect(201);

      // Sent in the other spelling on purpose: the rule is about the barcode, not the string.
      const response = await as(a, 'owner')
        .post(`/products/${other}/barcodes`, { barcodes: [GTIN14] })
        .expect(409);

      expect(response.body.message).toContain('abay paracetamol');
      expect(await stored(other)).toEqual([]);
      expect(await stored(a.productId)).toEqual([GTIN14]);
    });

    it('refuses it at product creation too', async () => {
      await as(a, 'owner')
        .post(`/products/${a.productId}/barcodes`, { barcodes: [EAN13] })
        .expect(201);
      await as(a, 'owner')
        .post('/products', {
          name: 'Duplicate',
          unit: 'tablet',
          priceSantim: 100,
          barcodes: [EAN13],
        })
        .expect(409);

      const rows = await harness.platformDataSource.query(
        `SELECT 1 FROM product WHERE tenant_id = $1 AND name = 'Duplicate'`,
        [a.id],
      );
      expect(rows).toHaveLength(0);
    });

    it('lets a product keep its own barcode when the list is saved again', async () => {
      await as(a, 'owner')
        .post(`/products/${a.productId}/barcodes`, { barcodes: [EAN13] })
        .expect(201);
      await as(a, 'owner')
        .post(`/products/${a.productId}/barcodes`, { barcodes: [EAN13, 'SHELF-0042'] })
        .expect(201);
      expect(await stored(a.productId)).toEqual([GTIN14, 'SHELF-0042']);
    });

    it('frees a barcode once it is removed, so it can be moved to the right product', async () => {
      const other = await secondProduct();
      await as(a, 'owner')
        .post(`/products/${a.productId}/barcodes`, { barcodes: [EAN13] })
        .expect(201);
      await as(a, 'owner').post(`/products/${a.productId}/barcodes`, { barcodes: [] }).expect(201);
      await as(a, 'owner')
        .post(`/products/${other}/barcodes`, { barcodes: [EAN13] })
        .expect(201);
      expect(await stored(other)).toEqual([GTIN14]);
    });
  });

  describe('per pharmacy (G1)', () => {
    it('lets two pharmacies link the same box — it is the same box', async () => {
      await as(a, 'owner')
        .post(`/products/${a.productId}/barcodes`, { barcodes: [EAN13] })
        .expect(201);
      await as(b, 'owner')
        .post(`/products/${b.productId}/barcodes`, { barcodes: [EAN13] })
        .expect(201);

      expect(await stored(a.productId)).toEqual([GTIN14]);
      expect(await stored(b.productId)).toEqual([GTIN14]);
    });

    it('never tells one pharmacy what another has linked', async () => {
      await as(b, 'owner')
        .post(`/products/${b.productId}/barcodes`, { barcodes: [EAN13] })
        .expect(201);

      const pull = await as(a, 'cashier').get('/sync/pull?cursor=0').expect(200);
      expect(JSON.stringify(pull.body)).not.toContain(GTIN14);
    });

    it('cannot relink a product of another pharmacy', async () => {
      const response = await as(a, 'owner').post(`/products/${b.productId}/barcodes`, {
        barcodes: [EAN13],
      });
      expect(response.status).toBe(404);
      expect(await stored(b.productId)).toEqual([]);
    });
  });

  describe('who may link, and what is recorded', () => {
    it('AC-2.1: a cashier is denied — a barcode decides which price a scan charges', async () => {
      await as(a, 'cashier')
        .post(`/products/${a.productId}/barcodes`, { barcodes: [EAN13] })
        .expect(403);
      expect(await stored(a.productId)).toEqual([]);
    });

    it('audits the change with the barcodes before and after', async () => {
      await as(a, 'owner')
        .post(`/products/${a.productId}/barcodes`, { barcodes: [EAN13] })
        .expect(201);
      await as(a, 'owner').post(`/products/${a.productId}/barcodes`, { barcodes: [] }).expect(201);

      const rows = await harness.platformDataSource.query(
        `SELECT payload, actor_id FROM event
          WHERE tenant_id = $1 AND event_type = 'audit.barcodes_changed' ORDER BY seq`,
        [a.id],
      );
      expect(rows).toHaveLength(2);
      expect(rows[1].actor_id).toBe(a.users.owner.id);
      expect(rows[1].payload.previous).toEqual([GTIN14]);
      expect(rows[1].payload.barcodes).toEqual([]);
    });
  });

  describe('reaching the till', () => {
    it('carries a new link to every terminal on its next pull', async () => {
      const cursor = (await as(a, 'cashier').get('/sync/pull?cursor=0').expect(200)).body.cursor;

      await as(a, 'owner')
        .post(`/products/${a.productId}/barcodes`, { barcodes: [EAN13] })
        .expect(201);

      const pull = await as(a, 'cashier').get(`/sync/pull?cursor=${cursor}`).expect(200);
      const parsed = pullResponse.parse(pull.body);
      expect(parsed.products).toHaveLength(1);
      expect(parsed.products[0].barcodes).toEqual([GTIN14]);
    });

    it('sends an empty list, never nothing, for a product with no barcode', async () => {
      const parsed = pullResponse.parse(
        (await as(a, 'cashier').get('/sync/pull?cursor=0').expect(200)).body,
      );
      for (const product of parsed.products) expect(product.barcodes).toEqual([]);
    });

    it('still serves a 1.5.0 terminal, which ignores the field (ADR-009)', async () => {
      await as(a, 'owner')
        .post(`/products/${a.productId}/barcodes`, { barcodes: [EAN13] })
        .expect(201);
      const pull = await as(a, 'cashier').get('/sync/pull?cursor=0', '1.5.0').expect(200);
      // Everything a 1.5.0 terminal reads is still there, unchanged in shape.
      const product = pull.body.products.find((p: { id: string }) => p.id === a.productId);
      expect(product.name).toBe('abay paracetamol');
      expect(product.packs).toEqual([]);
      expect(typeof product.currentPriceSantim).toBe('number');
    });
  });
});
