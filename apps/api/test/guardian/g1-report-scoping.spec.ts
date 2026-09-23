import request from 'supertest';
import { uuidv7 } from 'uuidv7';
import { TestHarness, type SeededTenant } from '../harness';
import { TERMINAL, saleInShift, shiftOp } from '../helpers/build-ops';

/**
 * G1 — REPORT SCOPING (FR-2 matrix, FR-8, BR-3.4).
 *
 * RLS answers "which tenant". It cannot answer "which branch, for this role" — and the
 * permission matrix draws that line explicitly: a branch manager is **B**, an owner is
 * **T**. A manager reading another branch's takings is a real breach of a real expectation
 * even though both branches belong to the same tenant, so the application has to enforce
 * it, at every call site, deliberately (docs/04 §8).
 *
 * These assertions exist because that is exactly the kind of check that gets forgotten on
 * the fourth report somebody adds.
 */
describe('G1 — report scoping', () => {
  let harness: TestHarness;
  let abay: SeededTenant;
  let tana: SeededTenant;
  const server = () => harness.app.getHttpServer();

  beforeAll(async () => {
    harness = await TestHarness.start();
    await harness.reset();
    abay = await harness.seedTenant('abay', 1500);
    tana = await harness.seedTenant('tana', 2000);

    // A day's trade at abay's first branch, which is the only one its manager is assigned to.
    const shiftId = uuidv7();
    await request(server())
      .post('/api/sync/push')
      .set('authorization', `Bearer ${abay.users.cashier.token}`)
      .send({
        terminalId: TERMINAL,
        operations: [
          shiftOp(abay, { terminalSeq: 1, shiftId, openingFloatSantim: 10000 }),
          saleInShift(abay, { terminalSeq: 2, shiftId, qty: 2, unitPriceSantim: 1500 }),
          saleInShift(abay, {
            terminalSeq: 3,
            shiftId,
            qty: 1,
            unitPriceSantim: 1500,
            method: 'other_recorded',
          }),
        ],
      })
      .expect(201);
  });

  afterAll(async () => harness?.stop());

  const get = (path: string, token: string) =>
    request(server()).get(path).set('authorization', `Bearer ${token}`);

  describe('sales summary (AC-8.2)', () => {
    it('gives the owner per-branch AND consolidated figures', async () => {
      const response = await get(
        '/api/reports/sales-summary?from=2026-09-01&to=2027-01-01',
        abay.users.owner.token,
      ).expect(200);

      expect(response.body.branches.length).toBeGreaterThan(0);
      expect(response.body.total.saleCount).toBe(2);
      // Both figures present in one response: the owner's question is never one or the
      // other, it is "how did we do, and which shop is the reason".
      const summed = response.body.branches.reduce(
        (n: number, b: { grossSantim: number }) => n + b.grossSantim,
        0,
      );
      expect(response.body.total.grossSantim).toBe(summed);
    });

    it('separates cash from other tenders', async () => {
      // The cash figure is what reconciles against a drawer; conflating them would make the
      // sales summary disagree with the cash-up for a reason nobody could find.
      const response = await get(
        '/api/reports/sales-summary?from=2026-09-01&to=2027-01-01',
        abay.users.owner.token,
      ).expect(200);

      expect(response.body.total.cashSantim).toBe(3000);
      expect(response.body.total.otherTenderSantim).toBe(1500);
      expect(response.body.total.grossSantim).toBe(4500);
    });

    it('does not multiply line counts when a sale has several payments', async () => {
      // The classic join fan-out. It would silently double `itemsSold` and nobody would
      // question a plausible number.
      const response = await get(
        '/api/reports/sales-summary?from=2026-09-01&to=2027-01-01',
        abay.users.owner.token,
      ).expect(200);
      expect(response.body.total.itemsSold).toBe(3);
    });

    it("never shows one tenant another tenant's takings", async () => {
      const response = await get(
        '/api/reports/sales-summary?from=2026-09-01&to=2027-01-01',
        tana.users.owner.token,
      ).expect(200);
      expect(response.body.total.saleCount).toBe(0);
      expect(response.body.branches).toHaveLength(0);
    });

    it('narrows a branch manager to their own branches', async () => {
      const response = await get(
        '/api/reports/sales-summary?from=2026-09-01&to=2027-01-01',
        abay.users.manager.token,
      ).expect(200);
      const ids = response.body.branches.map((b: { branchId: string }) => b.branchId);
      expect(ids).toEqual([abay.branchIds[0]]);
      expect(ids).not.toContain(abay.branchIds[1]);
    });

    it('refuses a manager asking for a branch they do not run, rather than returning empty', async () => {
      // An empty report would tell them their colleague's branch took nothing today: a
      // confident, wrong answer, which is worse than an error.
      await get(
        `/api/reports/sales-summary?branchId=${abay.branchIds[1]}`,
        abay.users.manager.token,
      ).expect(403);
    });

    it('refuses a branch belonging to another tenant outright', async () => {
      await get(
        `/api/reports/sales-summary?branchId=${tana.branchIds[0]}`,
        abay.users.manager.token,
      ).expect(403);
    });

    it('denies a cashier the branch-wide summary (FR-2 matrix)', async () => {
      await get('/api/reports/sales-summary', abay.users.cashier.token).expect(403);
    });

    it('uses a half-open window, so consecutive days tile exactly', async () => {
      // A sale at midnight must be counted once, not twice and not never.
      const day = await get(
        '/api/reports/sales-summary?from=2026-09-22&to=2026-09-23',
        abay.users.owner.token,
      ).expect(200);
      const next = await get(
        '/api/reports/sales-summary?from=2026-09-23&to=2026-09-24',
        abay.users.owner.token,
      ).expect(200);
      const both = await get(
        '/api/reports/sales-summary?from=2026-09-22&to=2026-09-24',
        abay.users.owner.token,
      ).expect(200);
      expect(day.body.total.saleCount + next.body.total.saleCount).toBe(both.body.total.saleCount);
    });

    it('refuses an unbounded window rather than timing out under load', async () => {
      await get(
        '/api/reports/sales-summary?from=2000-01-01&to=2030-01-01',
        abay.users.owner.token,
      ).expect(400);
      await get(
        '/api/reports/sales-summary?from=2026-09-23&to=2026-09-23',
        abay.users.owner.token,
      ).expect(400);
    });
  });

  describe('stock & expiry (BR-3.4)', () => {
    it('surfaces near-expiry stock with what it is worth', async () => {
      const response = await get(
        '/api/reports/stock?expiringWithinDays=3650',
        abay.users.owner.token,
      ).expect(200);

      expect(response.body.rows.length).toBeGreaterThan(0);
      expect(response.body.summary.expiringValueSantim).toBeGreaterThan(0);
      // The point of the report is the money, not the listing: an owner who has to compute
      // the cost themselves will not look twice (Vision §1.1).
      expect(response.body.rows[0]).toHaveProperty('valueSantim');
    });

    it('returns dates as calendar dates, not stringified Date objects', async () => {
      // `String(new Date())` sliced to ten characters yields "Thu Dec 3", which is not a
      // date and sorts like nonsense.
      const response = await get(
        '/api/reports/stock?expiringWithinDays=3650',
        abay.users.owner.token,
      ).expect(200);
      for (const row of response.body.rows) {
        expect(row.expiryDate).toMatch(/^\d{4}-\d{2}-\d{2}$/);
      }
    });

    it('excludes controlled substances — their stock is a ledger projection', async () => {
      // Showing them from any other source would be inventing a number (BR-3.3), and the
      // ledger does not exist until A-1 clears.
      const response = await get(
        '/api/reports/stock?expiringWithinDays=3650',
        abay.users.owner.token,
      ).expect(200);
      const ids = response.body.rows.map((r: { productId: string }) => r.productId);
      expect(ids).not.toContain(abay.controlledProductId);
    });

    it('ranks oversold above expiring, because the count itself is in doubt', async () => {
      await harness.platformDataSource.query(
        `UPDATE stock_batch SET qty_on_hand = -4 WHERE id = $1`,
        [abay.batchIds[0]],
      );

      const response = await get(
        '/api/reports/stock?expiringWithinDays=3650',
        abay.users.owner.token,
      ).expect(200);

      expect(response.body.rows[0].status).toBe('oversold');
      expect(response.body.summary.oversoldBatches).toBe(1);

      await harness.platformDataSource.query(
        `UPDATE stock_batch SET qty_on_hand = 10 WHERE id = $1`,
        [abay.batchIds[0]],
      );
    });

    it('narrows a branch manager to their own branches here too', async () => {
      const response = await get(
        '/api/reports/stock?expiringWithinDays=3650',
        abay.users.manager.token,
      ).expect(200);
      const branches = new Set(response.body.rows.map((r: { branchId: string }) => r.branchId));
      expect([...branches].every((id) => id === abay.branchIds[0])).toBe(true);
    });

    it("never leaks another tenant's stock", async () => {
      const response = await get(
        '/api/reports/stock?expiringWithinDays=3650',
        tana.users.owner.token,
      ).expect(200);
      const names = response.body.rows.map((r: { productName: string }) => r.productName);
      expect(names.every((n: string) => n.startsWith('tana'))).toBe(true);
    });

    it('rejects a nonsensical expiry window', async () => {
      await get('/api/reports/stock?expiringWithinDays=-5', abay.users.owner.token).expect(400);
      await get('/api/reports/stock?expiringWithinDays=abc', abay.users.owner.token).expect(400);
    });
  });
});
