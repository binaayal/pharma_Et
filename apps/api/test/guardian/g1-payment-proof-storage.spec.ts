import request from 'supertest';
import { uuidv7 } from 'uuidv7';
import { TestHarness, type SeededTenant } from '../harness';

/**
 * PAYMENT SCREENSHOTS IN POSTGRES, DELETED ONCE DECIDED (ADR-028).
 *
 * While there is no object storage, screenshots live in `payment_proof_blob`. Three
 * properties carry the decision:
 *
 *  - **The pharmacy's own connection cannot read them.** The app role has no grant; only
 *    the logged platform connection touches the table. One pharmacy's bank app must never be
 *    one query away from another's.
 *  - **Deciding can delete the image and keeps the record.** The amount, the decision, who
 *    made it and when are the billing record; the picture is not. Deleting it frees the
 *    database, which on Neon's free plan is the scarce thing.
 *  - **Nothing is deleted before a decision.** A pending proof with no image could never be
 *    verified.
 */
describe('G1 / ADR-028 — payment screenshots stored in the database', () => {
  let harness: TestHarness;
  let abay: SeededTenant;
  let platform: string;
  const server = () => harness.app.getHttpServer();

  const PNG = Buffer.concat([
    Buffer.from('89504e470d0a1a0a0000000d49484452', 'hex'),
    Buffer.alloc(64, 7),
  ]);

  beforeAll(async () => {
    process.env.PROOF_STORAGE = 'db';
    harness = await TestHarness.start();
  });

  afterAll(async () => {
    delete process.env.PROOF_STORAGE;
    await harness?.stop();
  });

  beforeEach(async () => {
    await harness.reset();
    abay = await harness.seedTenant('abay');
    platform = await harness.seedPlatformAdmin();
    await harness.platformDataSource.query(
      `INSERT INTO subscription (id, tenant_id, state, current_period_end, price_santim)
       VALUES ($1, $2, 'suspended', NULL, 100000)`,
      [uuidv7(), abay.id],
    );
  });

  async function submit(): Promise<string> {
    const response = await request(server())
      .post('/api/billing/payment-proofs')
      .set('authorization', `Bearer ${abay.users.owner.token}`)
      .field('amountSantim', '100000')
      .field('note', 'CBE FT26273')
      .attach('screenshot', PNG, { filename: 'transfer.png', contentType: 'image/png' })
      .expect(201);
    return response.body.id;
  }

  const blobs = async () =>
    (await harness.platformDataSource.query(`SELECT count(*)::int AS n FROM payment_proof_blob`))[0]
      .n;

  it('stores the screenshot in the database, out of the pharmacy connection’s reach', async () => {
    await submit();
    expect(await blobs()).toBe(1);
    await expect(
      harness.appDataSource.query(`SELECT bytes FROM payment_proof_blob`),
    ).rejects.toThrow(/permission denied/);
  });

  it('shows the platform the screenshot it is deciding on', async () => {
    const id = await submit();
    const response = await request(server())
      .get(`/api/platform/payment-proofs/${id}/image`)
      .set('authorization', `Bearer ${platform}`)
      .buffer(true)
      .parse((res, done) => {
        const chunks: Buffer[] = [];
        res.on('data', (c: Buffer) => chunks.push(c));
        res.on('end', () => done(null, Buffer.concat(chunks)));
      })
      .expect(200);
    expect(Buffer.compare(response.body as Buffer, PNG)).toBe(0);
  });

  it('deletes the screenshot when deciding, and keeps the billing record', async () => {
    const id = await submit();
    const decided = await request(server())
      .post(`/api/platform/payment-proofs/${id}/decide`)
      .set('authorization', `Bearer ${platform}`)
      .send({ accept: true, deleteImage: true })
      .expect(201);
    expect(decided.body.imageDeleted).toBe(true);

    expect(await blobs()).toBe(0);
    const [row] = await harness.platformDataSource.query(
      `SELECT result, amount_santim, verified_by, image_deleted_at FROM payment_proof WHERE id = $1`,
      [id],
    );
    expect(row.result).toBe('accepted');
    expect(Number(row.amount_santim)).toBe(100000);
    expect(row.verified_by).toEqual(expect.any(String));
    expect(row.image_deleted_at).not.toBeNull();

    // The subscription the payment bought is untouched by the deletion.
    const [sub] = await harness.platformDataSource.query(
      `SELECT state FROM subscription WHERE tenant_id = $1`,
      [abay.id],
    );
    expect(sub.state).toBe('active');

    await request(server())
      .get(`/api/platform/payment-proofs/${id}/image`)
      .set('authorization', `Bearer ${platform}`)
      .expect(410);

    const events = await harness.platformDataSource.query(
      `SELECT event_type FROM event WHERE tenant_id = $1 AND event_type = 'audit.payment_proof_image_deleted'`,
      [abay.id],
    );
    expect(events).toHaveLength(1);
  });

  it('keeps the screenshot when the admin chooses to', async () => {
    const id = await submit();
    await request(server())
      .post(`/api/platform/payment-proofs/${id}/decide`)
      .set('authorization', `Bearer ${platform}`)
      .send({ accept: false, reason: 'Amount does not match.', deleteImage: false })
      .expect(201);
    expect(await blobs()).toBe(1);
  });

  it('cannot delete a screenshot before the payment is decided', async () => {
    await submit();
    await request(server())
      .post('/api/platform/payment-proofs/purge-decided-images')
      .set('authorization', `Bearer ${platform}`)
      .expect(201)
      .expect(({ body }) => expect(body.deleted).toBe(0));
    expect(await blobs()).toBe(1);
  });

  it('frees every decided screenshot left behind in one action', async () => {
    const first = await submit();
    const second = await submit();
    for (const id of [first, second]) {
      await request(server())
        .post(`/api/platform/payment-proofs/${id}/decide`)
        .set('authorization', `Bearer ${platform}`)
        .send({ accept: false, reason: 'Duplicate submission.' })
        .expect(201);
    }
    const listed = await request(server())
      .get('/api/platform/payment-proofs/decided-images')
      .set('authorization', `Bearer ${platform}`)
      .expect(200);
    expect(listed.body).toHaveLength(2);

    const purged = await request(server())
      .post('/api/platform/payment-proofs/purge-decided-images')
      .set('authorization', `Bearer ${platform}`)
      .expect(201);
    expect(purged.body.deleted).toBe(2);
    expect(purged.body.bytesFreed).toBeGreaterThan(0);
    expect(await blobs()).toBe(0);
  });

  it('is the platform’s action only', async () => {
    await request(server())
      .post('/api/platform/payment-proofs/purge-decided-images')
      .set('authorization', `Bearer ${abay.users.owner.token}`)
      .expect(401);
  });
});
