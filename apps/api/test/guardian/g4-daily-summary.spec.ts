import request from 'supertest';
import { uuidv7 } from 'uuidv7';
import { TestHarness, type SeededTenant } from '../harness';
import {
  TERMINAL,
  adjustmentOp,
  cashUpOp,
  creditPaymentOp,
  creditSaleOp,
  customerOp,
  receiptOp,
  saleInShift,
  saleOp,
  shiftOp,
} from '../helpers/build-ops';

/**
 * G4 — THE END-OF-DAY SUMMARY (FR-17, ADR-035).
 *
 * This is the one screen an owner who is not in the shop reads every evening, and they will
 * act on it: ask about a shortage, chase a debt, reorder a medicine. A summary that is
 * confidently wrong is worse than none, so each figure here is held to the rows it is
 * supposed to be adding up — and to the reports that already show the same thing.
 *
 * The rules that are easy to get subtly wrong:
 *
 *   - a shortage in one till and an overage in another are **two findings**, never a net;
 *   - money sold on credit is **not** money in;
 *   - a branch manager sees their branch, another pharmacy sees nothing (G1).
 */
describe('G4 — daily summary', () => {
  let harness: TestHarness;
  let a: SeededTenant;
  let b: SeededTenant;
  const server = () => harness.app.getHttpServer();

  /** Wide enough for every fixed timestamp the op builders use. */
  const WINDOW = 'from=2026-09-01&to=2026-12-01';

  beforeAll(async () => {
    harness = await TestHarness.start();
  });

  beforeEach(async () => {
    await harness.reset();
    a = await harness.seedTenant('abay');
    b = await harness.seedTenant('blue');
  });

  afterAll(async () => harness?.stop());

  const push = (
    tenant: SeededTenant,
    operations: unknown[],
    role: 'cashier' | 'manager' = 'cashier',
  ) =>
    request(server())
      .post('/api/sync/push')
      .set('authorization', `Bearer ${tenant.users[role].token}`)
      .send({ terminalId: TERMINAL, operations })
      .expect(201);

  const get = (
    path: string,
    tenant: SeededTenant,
    role: 'owner' | 'manager' | 'cashier' = 'owner',
  ) =>
    request(server()).get(`/api${path}`).set('authorization', `Bearer ${tenant.users[role].token}`);

  const summary = async (tenant = a, query = WINDOW) =>
    (await get(`/reports/daily-summary?${query}`, tenant).expect(200)).body;

  it('a day with nothing in it is all zeros, not an error', async () => {
    const s = await summary(a, 'from=2020-01-01&to=2020-01-02');

    expect(s.sales).toMatchObject({ saleCount: 0, grossSantim: 0, cashSantim: 0, creditSantim: 0 });
    expect(s.cash).toEqual({
      countedShifts: 0,
      countedSantim: 0,
      shortageSantim: 0,
      overageSantim: 0,
      openShifts: 0,
    });
    expect(s.shifts).toEqual([]);
    expect(s.attention).toEqual({ priceChanges: 0, stockWriteOffs: 0, expiredDispenses: 0 });
    expect(s.lastSyncedAt).toBeNull();
  });

  describe('sales', () => {
    it('agrees with the sales summary to the santim, credit kept apart', async () => {
      const customerId = uuidv7();
      await push(a, [
        customerOp(a, { terminalSeq: 1, customerId }),
        saleOp(a, { terminalSeq: 2 }),
        creditSaleOp(a, { terminalSeq: 3, customerId, paidNowSantim: 1000 }),
      ]);

      const s = await summary();
      const reference = (await get(`/reports/sales-summary?${WINDOW}`, a).expect(200)).body.total;

      expect(s.sales).toEqual(reference);
      expect(s.sales.grossSantim).toBe(1500 + 4500);
      expect(s.sales.cashSantim).toBe(1500 + 1000);
      // Sold, not received.
      expect(s.sales.creditSantim).toBe(3500);
      expect(s.lastSyncedAt).not.toBeNull();
    });
  });

  describe('the drawer', () => {
    /** One complete till session: opened, traded, counted. */
    const till = async (seq: number, countedDelta: number) => {
      const shiftId = uuidv7();
      await push(a, [
        shiftOp(a, { terminalSeq: seq, shiftId, openingFloatSantim: 20000 }),
        saleInShift(a, { terminalSeq: seq + 1, shiftId }),
        cashUpOp(a, {
          terminalSeq: seq + 2,
          shiftId,
          expectedSantim: 21500,
          countedSantim: 21500 + countedDelta,
        }),
      ]);
      return shiftId;
    };

    it('reports a shortage as a shortage, with who was on', async () => {
      await till(1, -500);
      const s = await summary();

      expect(s.cash.countedShifts).toBe(1);
      expect(s.cash.countedSantim).toBe(21000);
      expect(s.cash.shortageSantim).toBe(500);
      expect(s.cash.overageSantim).toBe(0);
      expect(s.shifts).toHaveLength(1);
      expect(s.shifts[0]).toMatchObject({
        branchName: expect.any(String),
        userName: expect.any(String),
        expectedSantim: 21500,
        countedSantim: 21000,
        varianceSantim: -500,
      });
      expect(s.shifts[0].closedAt).not.toBeNull();
    });

    it('never nets a shortage in one till against an overage in another', async () => {
      await till(1, -500);
      await till(10, 300);
      const s = await summary();

      // Net would be 200 short. Reported as it is: 500 missing here, 300 extra there.
      expect(s.cash.shortageSantim).toBe(500);
      expect(s.cash.overageSantim).toBe(300);
      expect(s.cash.countedShifts).toBe(2);
    });

    it('says when a till was opened and never counted', async () => {
      await push(a, [shiftOp(a, { terminalSeq: 1, shiftId: uuidv7() })]);
      const s = await summary();

      expect(s.cash.openShifts).toBe(1);
      expect(s.cash.countedShifts).toBe(0);
      expect(s.shifts[0].closedAt).toBeNull();
      expect(s.shifts[0].varianceSantim).toBeNull();
    });

    it('agrees with the cash-up report for the same shift', async () => {
      const shiftId = await till(1, -500);
      const s = await summary();
      const report = (await get(`/reports/cash-up/${shiftId}`, a).expect(200)).body;

      expect(s.shifts[0].varianceSantim).toBe(report.varianceSantim);
      expect(s.shifts[0].countedSantim).toBe(report.countedSantim);
    });

    it('leaves out a till that was closed before the day began', async () => {
      await till(1, -500); // opened 2026-09-23T06:00, counted 17:00
      const s = await summary(a, 'from=2026-09-24&to=2026-09-25');
      expect(s.shifts).toEqual([]);
      expect(s.cash.shortageSantim).toBe(0);
    });
  });

  describe('money owed', () => {
    it('shows what came in against debts today, and everything still owed', async () => {
      const one = uuidv7();
      const two = uuidv7();
      await push(a, [
        customerOp(a, { terminalSeq: 1, customerId: one, name: 'Abebe' }),
        customerOp(a, { terminalSeq: 2, customerId: two, name: 'Clinic' }),
        creditSaleOp(a, { terminalSeq: 3, customerId: one }), // owes 45.00
        creditSaleOp(a, { terminalSeq: 4, customerId: two }), // owes 45.00
        creditPaymentOp(a, { terminalSeq: 5, customerId: one, amountSantim: 2000 }),
        // The clinic pays 60.00 against 45.00: 15.00 ahead.
        creditPaymentOp(a, {
          terminalSeq: 6,
          customerId: two,
          amountSantim: 6000,
          method: 'other_recorded',
        }),
      ]);

      const s = await summary();
      expect(s.credit.repaidSantim).toBe(8000);
      // Abebe's 25.00. The clinic's 15.00 in hand does not reduce it.
      expect(s.credit.owedSantim).toBe(2500);
      expect(s.credit.customersOwing).toBe(1);
    });
  });

  describe('stock', () => {
    it('lists what is running low, lowest first, and stops listing it once restocked', async () => {
      // Seeded: two batches of 10 — twenty in all, which is "low".
      let s = await summary();
      expect(s.stock.lowCount).toBe(1);
      expect(s.stock.low[0]).toMatchObject({
        productName: 'abay paracetamol',
        onHand: 20,
        unit: 'tablet',
      });

      await push(
        a,
        [receiptOp(a, { terminalSeq: 1, qty: 500, lotNo: 'LOT-NEW', expiryDate: '2035-01-31' })],
        'manager',
      );
      s = await summary();
      expect(s.stock.lowCount).toBe(0);
    });

    it('counts a batch about to expire, and one sold below zero', async () => {
      const before = await summary();

      const soon = new Date(Date.now() + 30 * 86_400_000).toISOString().slice(0, 10);
      await push(
        a,
        [receiptOp(a, { terminalSeq: 1, qty: 40, lotNo: 'LOT-SOON', expiryDate: soon })],
        'manager',
      );
      // Twenty-five out of a batch of ten.
      await push(a, [saleOp(a, { terminalSeq: 2, qty: 25, batchId: a.batchIds[0] })]);

      const after = await summary();
      expect(after.stock.expiringBatches).toBe(before.stock.expiringBatches + 1);
      expect(after.stock.oversoldBatches).toBe(before.stock.oversoldBatches + 1);
    });

    it("does not list controlled substances — their stock is the ledger's", async () => {
      const s = await summary();
      expect(s.stock.low.map((r: { productName: string }) => r.productName)).not.toContain(
        'abay diazepam',
      );
    });
  });

  describe('what an owner should have been told', () => {
    it('counts a price change', async () => {
      await request(server())
        .post(`/api/products/${a.productId}/price`)
        .set('authorization', `Bearer ${a.users.owner.token}`)
        .send({ priceSantim: 1750 })
        .expect(201);

      // Made now, so it is in today's window and not in a past one.
      const today = new Date().toISOString().slice(0, 10);
      const tomorrow = new Date(Date.now() + 86_400_000).toISOString().slice(0, 10);
      expect((await summary(a, `from=${today}&to=${tomorrow}`)).attention.priceChanges).toBe(1);
      expect((await summary(a, 'from=2020-01-01&to=2020-01-02')).attention.priceChanges).toBe(0);
    });

    it('counts a write-off, and not an ordinary recount', async () => {
      await push(
        a,
        [
          adjustmentOp(a, { terminalSeq: 1, delta: -3, reason: 'damage', note: 'dropped' }),
          // Counted the shelf and corrected the number: not a write-off.
          adjustmentOp(a, { terminalSeq: 2, delta: -1, reason: 'recount' }),
          // Stock found: not a write-off either.
          adjustmentOp(a, {
            terminalSeq: 3,
            delta: 2,
            reason: 'receipt_correction',
            note: 'miscounted',
          }),
        ],
        'manager',
      );
      expect((await summary()).attention.stockWriteOffs).toBe(1);
    });
  });

  describe('who may read it (G1)', () => {
    it('refuses a cashier', async () => {
      await get(`/reports/daily-summary?${WINDOW}`, a, 'cashier').expect(403);
    });

    it('shows a branch manager their own branch only', async () => {
      // One sale at the manager's branch, one at the pharmacy's other branch.
      await push(a, [saleOp(a, { terminalSeq: 1 })]);
      await push(a, [saleOp(a, { terminalSeq: 2, branchId: a.branchIds[1], batchId: null })]);

      const owner = await summary();
      const manager = (await get(`/reports/daily-summary?${WINDOW}`, a, 'manager').expect(200))
        .body;
      expect(owner.sales.saleCount).toBe(2);
      expect(manager.sales.saleCount).toBe(1);
    });

    it("never shows one pharmacy another's day", async () => {
      const customerId = uuidv7();
      await push(a, [
        customerOp(a, { terminalSeq: 1, customerId }),
        creditSaleOp(a, { terminalSeq: 2, customerId }),
      ]);

      const theirs = await summary(b);
      expect(theirs.sales.saleCount).toBe(0);
      expect(theirs.credit.owedSantim).toBe(0);
      expect(theirs.shifts).toEqual([]);
      expect(JSON.stringify(theirs)).not.toContain('abay');
    });

    it('refuses a window longer than a year', async () => {
      await get('/reports/daily-summary?from=2020-01-01&to=2026-01-01', a).expect(400);
    });
  });
});
