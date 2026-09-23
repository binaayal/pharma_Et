import request from 'supertest';
import { uuidv7 } from 'uuidv7';
import { TestHarness, type SeededTenant } from '../harness';
import { TERMINAL, adjustmentOp, saleInShift, shiftOp } from '../helpers/build-ops';

/**
 * G5 — OVERSELL IS RECONCILABLE, not merely detectable (BR-3.2, FR-3).
 *
 * BR-3.2 promises an oversell is "recorded and **flagged for physical reconciliation**". A
 * system that flags one and offers no way to resolve it leaves the counter with a
 * permanently negative number and no honest action to take — which is how people learn the
 * stock figures are not worth maintaining, and the whole inventory feature quietly dies.
 *
 * So this suite covers the other half of G5: somebody counted the shelf, the shelf won, and
 * the correction is recorded in a way that can be read back a year later.
 */
describe('G5 — stock reconciliation', () => {
  let harness: TestHarness;
  let tenant: SeededTenant;
  const server = () => harness.app.getHttpServer();

  beforeAll(async () => {
    harness = await TestHarness.start();
  });

  beforeEach(async () => {
    await harness.reset();
    tenant = await harness.seedTenant('abay', 1500);
  });

  afterAll(async () => harness?.stop());

  const push = (operations: unknown[]) =>
    request(server())
      .post('/api/sync/push')
      .set('authorization', `Bearer ${tenant.users.cashier.token}`)
      .send({ terminalId: TERMINAL, operations });

  const qtyOf = async (batchId: string): Promise<number> => {
    const rows = await harness.platformDataSource.query(
      `SELECT qty_on_hand FROM stock_batch WHERE id = $1`,
      [batchId],
    );
    return Number(rows[0].qty_on_hand);
  };

  it('resolves an oversell: the shelf is counted and the count wins', async () => {
    const shiftId = uuidv7();
    // Seeded at 10; sell 15 and the batch goes to −5 (BR-3.2, never blocked).
    await push([
      shiftOp(tenant, { terminalSeq: 1, shiftId }),
      saleInShift(tenant, { terminalSeq: 2, shiftId, qty: 15 }),
    ]).expect(201);
    expect(await qtyOf(tenant.batchIds[1])).toBe(-5);

    // Somebody counts the shelf and finds 3 boxes: the correction is +8.
    await push([adjustmentOp(tenant, { terminalSeq: 3, delta: 8, previousQtyOnHand: -5 })]).expect(
      201,
    );

    expect(await qtyOf(tenant.batchIds[1])).toBe(3);
  });

  it('applies a delta, never an absolute', async () => {
    // The terminal counted against 10 while offline; two sales synced in between. Applying
    // "set it to 8" would silently discard them. Applying −2 composes with whatever
    // happened, which is the only version that survives an offline window.
    const shiftId = uuidv7();
    await push([
      shiftOp(tenant, { terminalSeq: 1, shiftId }),
      saleInShift(tenant, { terminalSeq: 2, shiftId, qty: 4 }),
    ]).expect(201);
    expect(await qtyOf(tenant.batchIds[1])).toBe(6);

    await push([adjustmentOp(tenant, { terminalSeq: 3, delta: -2, previousQtyOnHand: 10 })]).expect(
      201,
    );

    // 6 − 2 = 4. Not 8, which is what the terminal's own arithmetic would have produced.
    expect(await qtyOf(tenant.batchIds[1])).toBe(4);
  });

  it('records what the terminal believed, so the decision can be reconstructed', async () => {
    // A write-off of 5 from a believed 5 is a different act from one from a believed 500.
    await push([
      adjustmentOp(tenant, {
        terminalSeq: 1,
        delta: -5,
        reason: 'damage',
        note: 'water damage in the back room',
        previousQtyOnHand: 10,
      }),
    ]).expect(201);

    const rows = await harness.platformDataSource.query(
      `SELECT * FROM stock_adjustment WHERE tenant_id = $1`,
      [tenant.id],
    );
    expect(rows).toHaveLength(1);
    expect(Number(rows[0].delta)).toBe(-5);
    expect(Number(rows[0].previous_qty_on_hand)).toBe(10);
    expect(rows[0].reason).toBe('damage');
    expect(rows[0].note).toBe('water damage in the back room');
    expect(rows[0].actor_id).toBe(tenant.users.cashier.id);
  });

  it('requires an explanation for anything but a recount', async () => {
    // An unexplained write-off is indistinguishable from a covered-up one.
    const noNote = adjustmentOp(tenant, { terminalSeq: 1, delta: -5, reason: 'theft_or_loss' });
    await push([noNote]).expect(400);

    const blank = adjustmentOp(tenant, {
      terminalSeq: 1,
      delta: -5,
      reason: 'theft_or_loss',
      note: '   ',
    });
    await push([blank]).expect(400);
  });

  it('accepts a recount without one, because most corrections genuinely have no story', async () => {
    // Forcing a cause on every correction produces invented causes.
    await push([adjustmentOp(tenant, { terminalSeq: 1, delta: -1 })]).expect(201);
    expect(await qtyOf(tenant.batchIds[1])).toBe(9);
  });

  it('refuses an adjustment of zero', async () => {
    await push([adjustmentOp(tenant, { terminalSeq: 1, delta: 0 })]).expect(400);
  });

  it('writes an audit entry naming the person, in the same transaction', async () => {
    await push([
      adjustmentOp(tenant, {
        terminalSeq: 1,
        delta: -3,
        reason: 'expiry_writeoff',
        note: 'expired, disposed',
      }),
    ]).expect(201);

    const events = await harness.platformDataSource.query(
      `SELECT * FROM event WHERE tenant_id = $1 AND event_type = 'audit.stock_adjusted'`,
      [tenant.id],
    );
    expect(events).toHaveLength(1);
    expect(events[0].actor_id).toBe(tenant.users.cashier.id);
    expect(events[0].payload.delta).toBe(-3);
    expect(events[0].payload.reason).toBe('expiry_writeoff');
    // Both figures, because where they disagree, sales synced after the count was taken.
    expect(events[0].payload.terminalBelievedQty).toBe(10);
    expect(events[0].payload.resultingQtyOnHand).toBe(7);
  });

  it('is idempotent — a retried batch adjusts stock once', async () => {
    // Adjustments are the operation most likely to be double-applied by an anxious retry,
    // and a doubled write-off is a real loss of stock on paper.
    const ops = [adjustmentOp(tenant, { terminalSeq: 1, delta: -4 })];
    await push(ops).expect(201);
    const after = await qtyOf(tenant.batchIds[1]);

    const replay = await push(ops).expect(201);
    expect(replay.body.acks[0].status).toBe('duplicate');
    expect(await qtyOf(tenant.batchIds[1])).toBe(after);
  });

  it('refuses an adjustment whose batch has not arrived', async () => {
    const orphan = await push([
      adjustmentOp(tenant, { terminalSeq: 1, batchId: uuidv7(), delta: -1 }),
    ]).expect(201);
    expect(orphan.body.acks[0].status).toBe('rejected');
    expect(orphan.body.acks[0].reason).toMatch(/batch/i);
  });

  it('rejects a reason outside the closed list', async () => {
    // Free-text reasons make the reconciliation report uncountable: "shrinkage happened 40
    // times" is a finding, "somebody typed something 40 ways" is not.
    const bad = adjustmentOp(tenant, { terminalSeq: 1, delta: -1 });
    (bad.payload as { reason: string }).reason = 'vibes';
    await push([bad]).expect(400);
  });

  it('clears the oversell from the stock report once reconciled', async () => {
    const shiftId = uuidv7();
    await push([
      shiftOp(tenant, { terminalSeq: 1, shiftId }),
      saleInShift(tenant, { terminalSeq: 2, shiftId, qty: 15 }),
    ]).expect(201);

    const before = await request(server())
      .get('/api/reports/stock?expiringWithinDays=3650')
      .set('authorization', `Bearer ${tenant.users.owner.token}`)
      .expect(200);
    expect(before.body.summary.oversoldBatches).toBe(1);

    await push([adjustmentOp(tenant, { terminalSeq: 3, delta: 8, previousQtyOnHand: -5 })]).expect(
      201,
    );

    const after = await request(server())
      .get('/api/reports/stock?expiringWithinDays=3650')
      .set('authorization', `Bearer ${tenant.users.owner.token}`)
      .expect(200);
    // The loop closes: flagged, counted, corrected, and no longer flagged.
    expect(after.body.summary.oversoldBatches).toBe(0);
  });

  it("never lets one tenant adjust another's stock", async () => {
    const other = await harness.seedTenant('tana');
    const cross = adjustmentOp(tenant, { terminalSeq: 1, delta: -5 });
    (cross.payload as { batchId: string }).batchId = other.batchIds[0];

    const response = await push([cross]).expect(201);
    expect(response.body.acks[0].status).toBe('rejected');

    const rows = await harness.platformDataSource.query(
      `SELECT qty_on_hand FROM stock_batch WHERE id = $1`,
      [other.batchIds[0]],
    );
    expect(Number(rows[0].qty_on_hand)).toBe(10);
  });
});
