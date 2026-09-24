import request from 'supertest';
import { uuidv7 } from 'uuidv7';
import { TestHarness, TEST_TERMINAL, type SeededTenant } from '../harness';
import { saleOp } from '../helpers/build-ops';

/**
 * G5 — EXPIRED DISPENSE IS RECORDED (E-4.2, ADR-020).
 *
 * Until now an expired batch was simply hidden from FEFO, so when the only stock was expired
 * the terminal offered no batch, the sale completed unattributed, and nobody was warned. The
 * box still left the shelf — the software just had nothing to say about it.
 *
 * The control is at the counter (a warning, and an override only an authorised role can give).
 * This suite defends the half that survives afterwards: **the server records every dispense
 * from an expired batch, and derives it from the batch's own expiry date rather than from
 * anything the client claims.** A client cannot make an expired dispense invisible by leaving
 * a field out, and an older terminal that has never heard of the field is recorded exactly as
 * accurately as a current one.
 */
describe('G5 — a dispense from expired stock is always recorded', () => {
  let harness: TestHarness;
  let tenant: SeededTenant;
  const server = () => harness.app.getHttpServer();

  // The fixture's sale is dated 2026-09-22 by `saleOp`, and expiry is judged against the
  // sale's own `soldAt` rather than the wall clock — a terminal offline for three days pushes
  // sales made before a batch expired, and those were not expired dispenses. So these dates
  // are relative to the SALE, not to today; using "yesterday" here tested nothing, because
  // yesterday is months after the fixture sells.
  const SALE_DATE = '2026-09-22';
  const DAY_BEFORE_SALE = '2026-09-21';

  /** A batch that had already expired when the fixture's sale was made. */
  const seedExpiredBatch = async (): Promise<string> => {
    const id = uuidv7();
    await harness.platformDataSource.query(
      `INSERT INTO stock_batch (id, tenant_id, branch_id, product_id, lot_no, expiry_date, qty_on_hand, change_seq)
       VALUES ($1, $2, $3, $4, 'LOT-EXPIRED', $5, 50, 0)`,
      [id, tenant.id, tenant.branchIds[0], tenant.productId, DAY_BEFORE_SALE],
    );
    return id;
  };

  const push = (operations: unknown[]) =>
    request(server())
      .post('/api/sync/push')
      .set('authorization', `Bearer ${tenant.users.cashier.token}`)
      .send({ terminalId: TEST_TERMINAL, operations });

  const expiredEvents = () =>
    harness.platformDataSource.query(
      `SELECT payload FROM event
        WHERE tenant_id = $1 AND event_type = 'audit.expired_dispense'
        ORDER BY seq`,
      [tenant.id],
    );

  beforeAll(async () => {
    harness = await TestHarness.start();
  });

  beforeEach(async () => {
    await harness.reset();
    tenant = await harness.seedTenant('exp');
  });

  afterAll(async () => harness?.stop());

  it('records the dispense, and who authorised it', async () => {
    const batchId = await seedExpiredBatch();
    const op = saleOp(tenant, { terminalSeq: 1, qty: 2, batchId });
    (op.payload.lines[0] as Record<string, unknown>).expiryOverrideBy =
      tenant.users.manager.id;

    const response = await push([op]).expect(201);
    expect(response.body.acks[0].status).toBe('applied');

    const events = await expiredEvents();
    expect(events).toHaveLength(1);
    expect(events[0].payload.batchId).toBe(batchId);
    expect(events[0].payload.lotNo).toBe('LOT-EXPIRED');
    expect(events[0].payload.authorisedBy).toBe(tenant.users.manager.id);
    expect(events[0].payload.qty).toBe(2);
  });

  it('records it just as loudly when nobody authorised it', async () => {
    const batchId = await seedExpiredBatch();

    // No override field at all — a 1.2.0 terminal, or a cashier who declined. This is the
    // case most worth having: expired stock stays on the books at full quantity while the
    // medicine is in a customer's bag, and this event is what connects that discrepancy to
    // the moment it was created.
    const response = await push([saleOp(tenant, { terminalSeq: 1, qty: 1, batchId })]);
    expect(response.status).toBe(201);

    const events = await expiredEvents();
    expect(events).toHaveLength(1);
    expect(events[0].payload.authorisedBy).toBeNull();
  });

  it('never refuses the sale', async () => {
    const batchId = await seedExpiredBatch();

    // BR-4.1 and NFR-1.2. Rejecting would strand a legitimate, properly authorised sale in an
    // outbox and would arrive days later at a terminal rather than at the counter where the
    // box was handed over. The control is the warning; this is the record.
    const response = await push([saleOp(tenant, { terminalSeq: 1, qty: 1, batchId })]);

    expect(response.body.acks[0].status).toBe('applied');
    const sales = await harness.platformDataSource.query(
      `SELECT id FROM sale WHERE tenant_id = $1`,
      [tenant.id],
    );
    expect(sales).toHaveLength(1);
  });

  it('says nothing about a batch that is still in date', async () => {
    // The ordinary path, and the one that must stay quiet. An audit log that fires on every
    // sale is one nobody reads, and the expiry report would drown.
    const response = await push([
      saleOp(tenant, { terminalSeq: 1, qty: 1, batchId: tenant.batchIds[0] }),
    ]);
    expect(response.body.acks[0].status).toBe('applied');
    expect(await expiredEvents()).toHaveLength(0);
  });

  it('treats a batch expiring on the day of the sale as still good', async () => {
    // `expiry_date` is a calendar date, not an instant. A box stamped with the sale's own
    // date is sellable that day, and a terminal in Addis is nowhere near UTC midnight when it
    // matters. The boundary is the assertion — a future date would pass whatever the code did.
    const id = uuidv7();
    await harness.platformDataSource.query(
      `INSERT INTO stock_batch (id, tenant_id, branch_id, product_id, lot_no, expiry_date, qty_on_hand, change_seq)
       VALUES ($1, $2, $3, $4, 'LOT-TODAY', $5, 10, 0)`,
      [id, tenant.id, tenant.branchIds[0], tenant.productId, SALE_DATE],
    );

    await push([saleOp(tenant, { terminalSeq: 1, qty: 1, batchId: id })]).expect(201);
    expect(await expiredEvents()).toHaveLength(0);
  });

  it('is itself immutable, like everything else in the log (G3)', async () => {
    const batchId = await seedExpiredBatch();
    await push([saleOp(tenant, { terminalSeq: 1, qty: 1, batchId })]).expect(201);

    // The record of an expired dispense is exactly the record somebody would most want to
    // edit later. The append-only triggers cover it because it is an ordinary event — which
    // is the reason it was put in the event log rather than a table of its own.
    await expect(
      harness.platformDataSource.query(
        `UPDATE event SET payload = '{}'::jsonb WHERE event_type = 'audit.expired_dispense'`,
      ),
    ).rejects.toThrow();
  });
});
