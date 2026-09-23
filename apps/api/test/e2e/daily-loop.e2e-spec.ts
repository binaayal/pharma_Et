import request from 'supertest';
import { uuidv7 } from 'uuidv7';
import { TestHarness, type SeededTenant } from '../harness';
import { TERMINAL, cashUpOp, receiptOp, saleInShift, shiftOp } from '../helpers/build-ops';

/**
 * CORE END-TO-END JOURNEYS — the Phase 1 exit gate (docs/06 §2).
 *
 * Guardian suites prove invariants in isolation: this one proves the **journey**, which is
 * the thing a pharmacy actually performs and the thing nobody tests until it breaks. The
 * core loop is stated in the SRS as *receive stock → sell/dispense → decrement → cash-up →
 * owner visibility*, and it is a loop: the end of one day is the start of the next, with
 * stock and cash carried across.
 *
 * Every journey here runs as a **terminal would run it** — operations pushed through
 * /sync/push in outbox order, not as direct API writes — because that is the path a real
 * sale takes (docs/04 §9) and a journey tested through a back door proves nothing about it.
 */
describe('core daily loop (Phase 1 exit gate)', () => {
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

  const push = (operations: unknown[], token = tenant.users.cashier.token) =>
    request(server())
      .post('/api/sync/push')
      .set('authorization', `Bearer ${token}`)
      .send({ terminalId: TERMINAL, operations });

  const asOwner = (path: string) =>
    request(server()).get(`/api${path}`).set('authorization', `Bearer ${tenant.users.owner.token}`);

  const stockOf = async (productId: string): Promise<number> => {
    const rows = await harness.platformDataSource.query(
      `SELECT coalesce(sum(qty_on_hand), 0)::int AS qty
         FROM stock_batch WHERE tenant_id = $1 AND product_id = $2 AND deleted_at IS NULL`,
      [tenant.id, productId],
    );
    return rows[0].qty;
  };

  it('receive → sell → decrement → cash-up → owner sees all of it', async () => {
    const opening = await stockOf(tenant.productId);
    const shiftId = uuidv7();
    let seq = 1;

    // ---- morning: goods arrive, the till opens -----------------------------
    await push([
      receiptOp(tenant, {
        terminalSeq: seq++,
        qty: 50,
        lotNo: 'LOT-MORNING',
        expiryDate: '2027-12-31',
      }),
      shiftOp(tenant, { terminalSeq: seq++, shiftId, openingFloatSantim: 20000 }),
    ]).expect(201);

    expect(await stockOf(tenant.productId)).toBe(opening + 50);

    // ---- trading: six sales, one on another tender -------------------------
    const cashSales = 5;
    await push([
      ...Array.from({ length: cashSales }, () =>
        saleInShift(tenant, { terminalSeq: seq++, shiftId, qty: 2, unitPriceSantim: 1500 }),
      ),
      saleInShift(tenant, {
        terminalSeq: seq++,
        shiftId,
        qty: 1,
        unitPriceSantim: 1500,
        method: 'other_recorded',
      }),
    ]).expect(201);

    // Stock decremented by every sale, regardless of how it was paid for.
    expect(await stockOf(tenant.productId)).toBe(opening + 50 - (cashSales * 2 + 1));

    // ---- close: count the drawer ------------------------------------------
    const expectedCash = 20000 + cashSales * 3000; // float + cash taken only
    await push([
      cashUpOp(tenant, {
        terminalSeq: seq++,
        shiftId,
        expectedSantim: expectedCash,
        countedSantim: expectedCash - 500,
        note: 'five birr short',
      }),
    ]).expect(201);

    // ---- the owner's morning -----------------------------------------------
    const cashUp = await asOwner(`/reports/cash-up/${shiftId}`).expect(200);
    expect(cashUp.body.serverExpectedSantim).toBe(expectedCash);
    expect(cashUp.body.varianceSantim).toBe(-500);
    expect(cashUp.body.saleCount).toBe(cashSales);
    expect(cashUp.body.note).toBe('five birr short');

    const summary = await asOwner('/reports/sales-summary?from=2026-09-01&to=2027-01-01').expect(
      200,
    );
    expect(summary.body.total.saleCount).toBe(cashSales + 1);
    expect(summary.body.total.cashSantim).toBe(cashSales * 3000);
    expect(summary.body.total.otherTenderSantim).toBe(1500);

    const sales = await asOwner('/reports/sales').expect(200);
    expect(sales.body).toHaveLength(cashSales + 1);
  });

  it('a day offline arrives whole on reconnect, in order, exactly once', async () => {
    // The journey this product exists for. Nothing is pushed until the end, and then
    // everything is — receipts, sales, the shift, the count — in one batch.
    const shiftId = uuidv7();
    let seq = 1;
    const day: unknown[] = [
      receiptOp(tenant, {
        terminalSeq: seq++,
        qty: 30,
        lotNo: 'LOT-OFF',
        expiryDate: '2027-06-30',
      }),
      shiftOp(tenant, { terminalSeq: seq++, shiftId, openingFloatSantim: 15000 }),
      ...Array.from({ length: 12 }, () =>
        saleInShift(tenant, { terminalSeq: seq++, shiftId, qty: 1, unitPriceSantim: 1500 }),
      ),
      cashUpOp(tenant, {
        terminalSeq: seq++,
        shiftId,
        expectedSantim: 15000 + 12 * 1500,
        countedSantim: 15000 + 12 * 1500,
      }),
    ];

    const first = await push(day).expect(201);
    expect(first.body.acks.every((a: { status: string }) => a.status === 'applied')).toBe(true);

    // The terminal never saw the acks and retries the whole day.
    const retry = await push(day).expect(201);
    expect(retry.body.acks.every((a: { status: string }) => a.status === 'duplicate')).toBe(true);

    const cashUp = await asOwner(`/reports/cash-up/${shiftId}`).expect(200);
    expect(cashUp.body.saleCount).toBe(12);
    expect(cashUp.body.varianceSantim).toBe(0);
  });

  it('two days in a row: stock and the cash float carry across', async () => {
    // A loop, not a line. Day two starts from whatever day one left behind, which is where
    // an off-by-one in stock or an orphaned shift shows itself.
    let seq = 1;
    const dayOne = uuidv7();
    const dayTwo = uuidv7();

    await push([
      receiptOp(tenant, { terminalSeq: seq++, qty: 20, lotNo: 'LOT-D1', expiryDate: '2027-06-30' }),
      shiftOp(tenant, { terminalSeq: seq++, shiftId: dayOne, openingFloatSantim: 10000 }),
      saleInShift(tenant, { terminalSeq: seq++, shiftId: dayOne, qty: 3, unitPriceSantim: 1500 }),
      cashUpOp(tenant, {
        terminalSeq: seq++,
        shiftId: dayOne,
        expectedSantim: 14500,
        countedSantim: 14500,
      }),
    ]).expect(201);

    const afterDayOne = await stockOf(tenant.productId);

    await push([
      shiftOp(tenant, { terminalSeq: seq++, shiftId: dayTwo, openingFloatSantim: 10000 }),
      saleInShift(tenant, { terminalSeq: seq++, shiftId: dayTwo, qty: 2, unitPriceSantim: 1500 }),
      cashUpOp(tenant, {
        terminalSeq: seq++,
        shiftId: dayTwo,
        expectedSantim: 13000,
        countedSantim: 13000,
      }),
    ]).expect(201);

    expect(await stockOf(tenant.productId)).toBe(afterDayOne - 2);

    // Counting the drawer closed day one's till, which is what made day two's shift
    // possible at all — the one-open-shift-per-user index would otherwise have rejected it.
    const shifts = await harness.platformDataSource.query(
      `SELECT closed_at FROM shift WHERE tenant_id = $1 ORDER BY opened_at`,
      [tenant.id],
    );
    expect(shifts).toHaveLength(2);
    expect(shifts.every((row: { closed_at: Date | null }) => row.closed_at !== null)).toBe(true);

    // Both shifts reconcile independently; day two's cash is not day one's.
    const summary = await asOwner('/reports/cash-up').expect(200);
    expect(summary.body).toHaveLength(2);
    for (const shift of summary.body) {
      expect(shift.varianceSantim).toBe(0);
    }
  });

  it('selling past zero completes, drives stock negative, and surfaces for a count', async () => {
    // The journey the product refuses to break: BR-3.2 says a sale is never blocked, and
    // the owner finds out through the report rather than the cashier finding out at the
    // counter.
    const shiftId = uuidv7();
    const opening = await stockOf(tenant.productId);

    await push([
      shiftOp(tenant, { terminalSeq: 1, shiftId }),
      saleInShift(tenant, {
        terminalSeq: 2,
        shiftId,
        qty: opening + 5,
        unitPriceSantim: 1500,
      }),
    ]).expect(201);

    const stock = await asOwner('/reports/stock?expiringWithinDays=3650').expect(200);
    const oversold = stock.body.rows.filter((r: { status: string }) => r.status === 'oversold');
    expect(oversold.length).toBeGreaterThan(0);
    expect(stock.body.summary.oversoldBatches).toBeGreaterThan(0);

    const oversells = await asOwner('/reports/oversells').expect(200);
    expect(oversells.body.length).toBeGreaterThan(0);
  });

  it('a second pharmacy runs the same day and sees none of the first', async () => {
    // The whole loop, twice, concurrently — the shape a multi-tenant bug actually takes.
    const other = await harness.seedTenant('tana', 2000);

    const runDay = async (t: SeededTenant, sales: number) => {
      const shiftId = uuidv7();
      let seq = 1;
      await request(server())
        .post('/api/sync/push')
        .set('authorization', `Bearer ${t.users.cashier.token}`)
        .send({
          terminalId: TERMINAL,
          operations: [
            shiftOp(t, { terminalSeq: seq++, shiftId, openingFloatSantim: 5000 }),
            ...Array.from({ length: sales }, () =>
              saleInShift(t, { terminalSeq: seq++, shiftId, qty: 1, unitPriceSantim: 1500 }),
            ),
          ],
        })
        .expect(201);
      return shiftId;
    };

    await runDay(tenant, 4);
    await runDay(other, 7);

    const mine = await asOwner('/reports/sales-summary?from=2026-09-01&to=2027-01-01').expect(200);
    expect(mine.body.total.saleCount).toBe(4);

    const theirs = await request(server())
      .get('/api/reports/sales-summary?from=2026-09-01&to=2027-01-01')
      .set('authorization', `Bearer ${other.users.owner.token}`)
      .expect(200);
    expect(theirs.body.total.saleCount).toBe(7);
  });

  it('a cashier lives the whole journey without ever being over-privileged', async () => {
    // The loop from the counter's point of view: everything they need, nothing they do not
    // (FR-2 matrix). A journey that only ever runs as an owner would never notice.
    const shiftId = uuidv7();
    const token = tenant.users.cashier.token;

    await push(
      [
        receiptOp(tenant, { terminalSeq: 1, qty: 10, lotNo: 'LOT-C', expiryDate: '2027-06-30' }),
        shiftOp(tenant, { terminalSeq: 2, shiftId, openingFloatSantim: 1000 }),
        saleInShift(tenant, { terminalSeq: 3, shiftId, qty: 1, unitPriceSantim: 1500 }),
        cashUpOp(tenant, {
          terminalSeq: 4,
          shiftId,
          expectedSantim: 2500,
          countedSantim: 2500,
        }),
      ],
      token,
    ).expect(201);

    // Their own shift: allowed.
    await request(server())
      .get(`/api/reports/cash-up/${shiftId}`)
      .set('authorization', `Bearer ${token}`)
      .expect(200);

    // The branch's takings, the staff list, a price change: not theirs.
    for (const path of ['/reports/sales-summary', '/reports/stock', '/users']) {
      await request(server())
        .get(`/api${path}`)
        .set('authorization', `Bearer ${token}`)
        .expect(403);
    }
    await request(server())
      .post(`/api/products/${tenant.productId}/price`)
      .set('authorization', `Bearer ${token}`)
      .send({ priceSantim: 1 })
      .expect(403);
  });
});
