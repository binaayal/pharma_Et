import request from 'supertest';
import { pullResponse } from '@pharmaet/contracts';
import { uuidv7 } from 'uuidv7';
import { TestHarness, type SeededTenant } from '../harness';
import {
  TERMINAL,
  cashUpOp,
  creditPaymentOp,
  creditSaleOp,
  customerOp,
  saleInShift,
  saleOp,
  shiftOp,
} from '../helpers/build-ops';

/**
 * G4 — THE CUSTOMER CREDIT LEDGER (FR-16, ADR-034; contract 1.7.0).
 *
 * A debt is money the pharmacy has earned and not yet got. A ledger that loses one, counts
 * one twice, or shows it to the wrong pharmacy is worse than the paper book it replaces —
 * the paper book at least is wrong where the owner can see it.
 *
 * What this suite holds:
 *
 *   - **what a customer owes is exactly their credit sales less their repayments**, after
 *     any sequence, replayed or concurrent (G4, G2);
 *   - **cash taken against a debt is in the drawer**, so the cash-up expects it (BR-8.2);
 *   - **credit is not money received**, so no report counts it as cash;
 *   - **one pharmacy's debtors are invisible to another** (G1);
 *   - a terminal that has never heard of credit keeps selling (ADR-009).
 */
describe('G4 — customer credit ledger', () => {
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

  const push = (tenant: SeededTenant, operations: unknown[], version?: string) => {
    const call = request(server())
      .post('/api/sync/push')
      .set('authorization', `Bearer ${tenant.users.cashier.token}`);
    if (version) call.set('x-contract-version', version);
    return call.send({ terminalId: TERMINAL, operations });
  };

  const pull = async (tenant: SeededTenant, cursor = 0, version?: string) => {
    const call = request(server())
      .get(`/api/sync/pull?cursor=${cursor}`)
      .set('authorization', `Bearer ${tenant.users.cashier.token}`);
    if (version) call.set('x-contract-version', version);
    return (await call.expect(200)).body;
  };

  const query = (sql: string, params: unknown[] = []) =>
    harness.platformDataSource.query(sql, params);

  const balance = async (customerId: string): Promise<number> =>
    Number(
      (await query(`SELECT balance_santim FROM customer WHERE id = $1`, [customerId]))[0]
        .balance_santim,
    );

  /** The truth, recomputed from the rows: credit on their sales, less what they repaid. */
  const owedByRows = async (customerId: string): Promise<number> =>
    Number(
      (
        await query(
          `SELECT (SELECT coalesce(sum(p.amount_santim), 0)
                     FROM sale s JOIN payment p ON p.sale_id = s.id AND p.method = 'credit'
                    WHERE s.customer_id = $1)
                - (SELECT coalesce(sum(amount_santim), 0) FROM credit_payment WHERE customer_id = $1)
                  AS owed`,
          [customerId],
        )
      )[0].owed,
    );

  /** A customer in tenant A, already synced. */
  const customer = async (name = 'Abebe Kebede'): Promise<string> => {
    const id = uuidv7();
    const response = await push(a, [
      customerOp(a, { terminalSeq: 1, customerId: id, name }),
    ]).expect(201);
    expect(response.body.acks[0].status).toBe('applied');
    return id;
  };

  describe('a customer', () => {
    it('created at one counter reaches every other terminal on its next pull', async () => {
      const id = await customer();
      const parsed = pullResponse.parse(await pull(a));

      expect(parsed.customers).toHaveLength(1);
      expect(parsed.customers?.[0]).toMatchObject({
        id,
        name: 'Abebe Kebede',
        phone: '0911 23 45 67',
        balanceSantim: 0,
      });
    });

    it('is created once when the push is replayed (G2)', async () => {
      const op = customerOp(a, { terminalSeq: 1 });
      await push(a, [op]).expect(201);
      const replay = await push(a, [op]).expect(201);

      expect(replay.body.acks[0].status).toBe('duplicate');
      expect(await query(`SELECT 1 FROM customer WHERE tenant_id = $1`, [a.id])).toHaveLength(1);
    });

    it('records nothing about the person beyond who owes the money', async () => {
      await customer();
      const columns = (
        await query(
          `SELECT column_name FROM information_schema.columns WHERE table_name = 'customer'`,
        )
      ).map((r: { column_name: string }) => r.column_name);
      // docs/01 §2.3: a debt book, not a patient record.
      for (const never of ['date_of_birth', 'address', 'diagnosis', 'gender', 'national_id']) {
        expect(columns).not.toContain(never);
      }
    });
  });

  describe('selling on credit', () => {
    it('part paid now, the rest owed: the customer owes exactly the rest', async () => {
      const id = await customer();
      // 3 × 15.00 = 45.00; 20.00 in cash, 25.00 on credit.
      const op = creditSaleOp(a, { terminalSeq: 2, customerId: id, paidNowSantim: 2000 });
      const response = await push(a, [op]).expect(201);

      expect(response.body.acks[0].status).toBe('applied');
      expect(await balance(id)).toBe(2500);

      const [sale] = await query(`SELECT customer_id, total_santim FROM sale WHERE id = $1`, [
        op.entityId,
      ]);
      expect(sale.customer_id).toBe(id);
      expect(Number(sale.total_santim)).toBe(4500);

      const payments = await query(
        `SELECT method, amount_santim FROM payment WHERE sale_id = $1 ORDER BY method`,
        [op.entityId],
      );
      expect(
        payments.map((p: { method: string; amount_santim: string }) => [
          p.method,
          Number(p.amount_santim),
        ]),
      ).toEqual([
        ['cash', 2000],
        ['credit', 2500],
      ]);
    });

    it('wholly on credit: the customer owes the whole sale', async () => {
      const id = await customer();
      await push(a, [creditSaleOp(a, { terminalSeq: 2, customerId: id })]).expect(201);
      expect(await balance(id)).toBe(4500);
    });

    it('still takes the stock off the shelf — the medicine left, paid for or not', async () => {
      const id = await customer();
      await push(a, [creditSaleOp(a, { terminalSeq: 2, customerId: id, qty: 3 })]).expect(201);
      const [batch] = await query(`SELECT qty_on_hand FROM stock_batch WHERE id = $1`, [
        a.batchIds[1],
      ]);
      expect(Number(batch.qty_on_hand)).toBe(7);
    });

    it('carries the new balance to the terminals', async () => {
      const id = await customer();
      const cursor = (await pull(a)).cursor;
      await push(a, [creditSaleOp(a, { terminalSeq: 2, customerId: id })]).expect(201);

      const parsed = pullResponse.parse(await pull(a, cursor));
      expect(parsed.customers?.find((c) => c.id === id)?.balanceSantim).toBe(4500);
    });

    it('counts the debt once when the push is replayed (G2)', async () => {
      const id = await customer();
      const op = creditSaleOp(a, { terminalSeq: 2, customerId: id });
      await push(a, [op]).expect(201);
      const replay = await push(a, [op]).expect(201);

      expect(replay.body.acks[0].status).toBe('duplicate');
      expect(await balance(id)).toBe(4500);
    });

    it('applies customer and first credit sale from one batch, in terminal order', async () => {
      // The first time someone asks to pay later, the till is very likely offline: the
      // customer and the sale that names them arrive together.
      const id = uuidv7();
      const response = await push(a, [
        // Deliberately listed out of order; the server applies by terminalSeq.
        creditSaleOp(a, { terminalSeq: 2, customerId: id }),
        customerOp(a, { terminalSeq: 1, customerId: id }),
      ]).expect(201);

      expect(response.body.acks.map((k: { status: string }) => k.status)).toEqual([
        'applied',
        'applied',
      ]);
      expect(await balance(id)).toBe(4500);
    });

    it('refuses credit owed by nobody, at the boundary, writing nothing', async () => {
      const op = creditSaleOp(a, { terminalSeq: 1, customerId: uuidv7() });
      delete (op.payload as { customerId?: string }).customerId;
      await push(a, [op]).expect(400);
      expect(await query(`SELECT 1 FROM sale WHERE id = $1`, [op.entityId])).toHaveLength(0);
    });

    it('refuses a credit sale whose payments do not add up to the total (G4)', async () => {
      const id = await customer();
      const op = creditSaleOp(a, { terminalSeq: 2, customerId: id, paidNowSantim: 2000 });
      op.payload.payments[1].amountSantim = 2400;
      await push(a, [op]).expect(400);
      expect(await balance(id)).toBe(0);
    });

    it('parks a sale naming a customer the server has never heard of — sale and stock untouched', async () => {
      const op = creditSaleOp(a, { terminalSeq: 1, customerId: uuidv7() });
      const response = await push(a, [op]).expect(201);

      // Rejected, not dropped: the terminal keeps it for a person to look at (BR-4.1).
      expect(response.body.acks[0].status).toBe('rejected');
      expect(response.body.acks[0].reason).toContain('unknown customer');
      // And the whole operation rolled back — no sale with no debtor, no stock moved.
      expect(await query(`SELECT 1 FROM sale WHERE id = $1`, [op.entityId])).toHaveLength(0);
      const [batch] = await query(`SELECT qty_on_hand FROM stock_batch WHERE id = $1`, [
        a.batchIds[1],
      ]);
      expect(Number(batch.qty_on_hand)).toBe(10);
    });
  });

  describe('taking a repayment', () => {
    it('reduces what the customer owes by exactly what was paid', async () => {
      const id = await customer();
      await push(a, [creditSaleOp(a, { terminalSeq: 2, customerId: id })]).expect(201);
      await push(a, [
        creditPaymentOp(a, { terminalSeq: 3, customerId: id, amountSantim: 2000 }),
      ]).expect(201);

      expect(await balance(id)).toBe(2500);
    });

    it('lets a customer pay ahead: the balance goes below zero and says so', async () => {
      const id = await customer();
      await push(a, [creditSaleOp(a, { terminalSeq: 2, customerId: id })]).expect(201);
      // Owes 45.00, hands over 50.00.
      await push(a, [
        creditPaymentOp(a, { terminalSeq: 3, customerId: id, amountSantim: 5000 }),
      ]).expect(201);

      expect(await balance(id)).toBe(-500);
    });

    it('counts a repayment once when the push is replayed (G2)', async () => {
      const id = await customer();
      await push(a, [creditSaleOp(a, { terminalSeq: 2, customerId: id })]).expect(201);
      const op = creditPaymentOp(a, { terminalSeq: 3, customerId: id, amountSantim: 2000 });
      await push(a, [op]).expect(201);
      const replay = await push(a, [op]).expect(201);

      expect(replay.body.acks[0].status).toBe('duplicate');
      expect(await balance(id)).toBe(2500);
      expect(await query(`SELECT 1 FROM credit_payment WHERE customer_id = $1`, [id])).toHaveLength(
        1,
      );
    });

    it.each([0, -500, 12.5])('refuses a repayment of %s at the boundary', async (amountSantim) => {
      const id = await customer();
      await push(a, [creditPaymentOp(a, { terminalSeq: 2, customerId: id, amountSantim })]).expect(
        400,
      );
      expect(await balance(id)).toBe(0);
    });

    it('refuses settling a debt with more credit', async () => {
      const id = await customer();
      const op = creditPaymentOp(a, { terminalSeq: 2, customerId: id, amountSantim: 1000 });
      (op.payload as { method: string }).method = 'credit';
      await push(a, [op]).expect(400);
    });

    it('parks a repayment for a customer the server has never heard of', async () => {
      const response = await push(a, [
        creditPaymentOp(a, { terminalSeq: 1, customerId: uuidv7(), amountSantim: 1000 }),
      ]).expect(201);
      expect(response.body.acks[0].status).toBe('rejected');
      expect(await query(`SELECT 1 FROM credit_payment WHERE tenant_id = $1`, [a.id])).toHaveLength(
        0,
      );
    });
  });

  describe('what a customer owes is their credit sales less their repayments', () => {
    it('after a long mixed sequence, the running balance equals the rows', async () => {
      const id = await customer();
      let seq = 2;
      const ops: unknown[] = [];
      // Deterministic, and deliberately uneven: part-paid, whole, small and large
      // repayments, an overpayment in the middle.
      const steps: Array<['sale', number, number] | ['pay', number]> = [
        ['sale', 3, 0],
        ['pay', 1000],
        ['sale', 5, 2500],
        ['sale', 1, 1500],
        ['pay', 9000],
        ['sale', 7, 100],
        ['pay', 1],
        ['sale', 2, 0],
        ['pay', 4321],
      ];
      for (const step of steps) {
        ops.push(
          step[0] === 'sale'
            ? creditSaleOp(a, {
                terminalSeq: seq++,
                customerId: id,
                qty: step[1],
                paidNowSantim: step[2],
              })
            : creditPaymentOp(a, { terminalSeq: seq++, customerId: id, amountSantim: step[1] }),
        );
      }
      const response = await push(a, ops).expect(201);
      expect(response.body.acks.every((k: { status: string }) => k.status === 'applied')).toBe(
        true,
      );

      const rows = await owedByRows(id);
      expect(await balance(id)).toBe(rows);
      // By hand: sold 18 × 15.00 = 270.00, less 41.00 paid at the time, less 143.22 repaid.
      expect(rows).toBe(27000 - 4100 - 14322);
    });

    it('holds when two terminals sync debts for one customer at the same moment', async () => {
      const id = await customer('Clinic next door');
      const other = '01930000-0000-7000-8000-0000000000e2';

      const one = Array.from({ length: 8 }, (_, i) =>
        creditSaleOp(a, { terminalSeq: 10 + i, customerId: id, qty: 1 }),
      );
      const two = Array.from({ length: 8 }, (_, i) =>
        creditSaleOp(a, { terminalSeq: 10 + i, customerId: id, qty: 1, terminalId: other }),
      );

      const send = (terminalId: string, operations: unknown[]) =>
        request(server())
          .post('/api/sync/push')
          .set('authorization', `Bearer ${a.users.cashier.token}`)
          .send({ terminalId, operations });
      const [r1, r2] = await Promise.all([send(TERMINAL, one), send(other, two)]);
      expect(r1.status).toBe(201);
      expect(r2.status).toBe(201);
      const reasons = [...r1.body.acks, ...r2.body.acks]
        .filter((k: { status: string }) => k.status !== 'applied')
        .map((k: { reason: string }) => k.reason);
      expect(reasons).toEqual([]);

      // Sixteen debts of 15.00. A read-then-write without a lock loses some of them.
      expect(await balance(id)).toBe(16 * 1500);
      expect(await balance(id)).toBe(await owedByRows(id));
    });
  });

  describe('the cash-up (BR-8.2)', () => {
    const shiftId = uuidv7();

    it('expects cash taken against a debt, and not the credit it was sold on', async () => {
      const id = await customer();
      await push(a, [
        shiftOp(a, { terminalSeq: 2, shiftId, openingFloatSantim: 20000 }),
        // A cash sale of 15.00 — in the drawer.
        saleInShift(a, { terminalSeq: 3, shiftId }),
        // 45.00 sold, 10.00 of it in cash; 35.00 owed — NOT in the drawer.
        creditSaleOp(a, { terminalSeq: 4, customerId: id, paidNowSantim: 1000, shiftId }),
        // 25.00 handed over against the debt — in the drawer.
        creditPaymentOp(a, { terminalSeq: 5, customerId: id, amountSantim: 2500, shiftId }),
        // 5.00 by Telebirr against the debt — not in the drawer.
        creditPaymentOp(a, {
          terminalSeq: 6,
          customerId: id,
          amountSantim: 500,
          method: 'other_recorded',
          shiftId,
        }),
      ]).expect(201);

      const expected = 20000 + 1500 + 1000 + 2500;
      await push(a, [
        cashUpOp(a, { terminalSeq: 7, shiftId, expectedSantim: expected, countedSantim: expected }),
      ]).expect(201);

      const [row] = await query(
        `SELECT expected_santim, server_expected_santim, variance_santim FROM cash_up WHERE shift_id = $1`,
        [shiftId],
      );
      // The server's own recomputation agrees with the till's, to the santim.
      expect(Number(row.server_expected_santim)).toBe(expected);
      expect(Number(row.expected_santim)).toBe(expected);
      expect(Number(row.variance_santim)).toBe(0);
      expect(await balance(id)).toBe(3500 - 2500 - 500);
    });

    it('parks a repayment naming a till that never arrived', async () => {
      const id = await customer();
      const response = await push(a, [
        creditPaymentOp(a, {
          terminalSeq: 2,
          customerId: id,
          amountSantim: 1000,
          shiftId: uuidv7(),
        }),
      ]).expect(201);
      expect(response.body.acks[0].status).toBe('rejected');
      expect(await balance(id)).toBe(0);
    });
  });

  describe('credit is not money received', () => {
    it('is reported apart from cash and from other tender', async () => {
      const id = await customer();
      await push(a, [
        saleOp(a, { terminalSeq: 2 }),
        creditSaleOp(a, { terminalSeq: 3, customerId: id, paidNowSantim: 2000 }),
      ]).expect(201);

      const summary = (
        await request(server())
          .get(
            '/api/reports/sales-summary?from=2026-09-01T00:00:00.000Z&to=2026-12-01T00:00:00.000Z',
          )
          .set('authorization', `Bearer ${a.users.owner.token}`)
          .expect(200)
      ).body.total;

      expect(summary.grossSantim).toBe(1500 + 4500);
      expect(summary.cashSantim).toBe(1500 + 2000);
      expect(summary.creditSantim).toBe(2500);
      // A debt lumped into "other tender" would read as money that came in.
      expect(summary.otherTenderSantim).toBe(0);
      expect(summary.cashSantim + summary.otherTenderSantim + summary.creditSantim).toBe(
        summary.grossSantim,
      );
    });
  });

  describe("one pharmacy's debtors are invisible to another (G1)", () => {
    it("never pulls another tenant's customers", async () => {
      await customer('Only abay knows me');
      const theirs = await pull(b);
      expect(JSON.stringify(theirs)).not.toContain('Only abay knows me');
      expect(theirs.customers).toEqual([]);
    });

    it("cannot sell on credit to another tenant's customer", async () => {
      const id = await customer();
      const response = await push(b, [creditSaleOp(b, { terminalSeq: 1, customerId: id })]).expect(
        201,
      );

      expect(response.body.acks[0].status).toBe('rejected');
      expect(await balance(id)).toBe(0);
      expect(await query(`SELECT 1 FROM sale WHERE tenant_id = $1`, [b.id])).toHaveLength(0);
    });

    it("cannot take — or forge — a repayment against another tenant's customer", async () => {
      const id = await customer();
      await push(a, [creditSaleOp(a, { terminalSeq: 2, customerId: id })]).expect(201);

      const response = await push(b, [
        creditPaymentOp(b, { terminalSeq: 1, customerId: id, amountSantim: 4500 }),
      ]).expect(201);

      expect(response.body.acks[0].status).toBe('rejected');
      // Abay is still owed every santim.
      expect(await balance(id)).toBe(4500);
    });
  });

  describe('a terminal that has never heard of credit (ADR-009)', () => {
    it('syncs a 1.6.0 cash sale unchanged, with no customer on it', async () => {
      const op = saleOp(a, { terminalSeq: 1 });
      const response = await push(a, [op], '1.6.0').expect(201);
      expect(response.body.acks[0].status).toBe('applied');
      const [sale] = await query(`SELECT customer_id FROM sale WHERE id = $1`, [op.entityId]);
      expect(sale.customer_id).toBeNull();
    });

    it('is not held to the payments-add-up rule it was never asked for', async () => {
      // The contract has always allowed a sale with an empty payments list. Tightening
      // that for everyone would start refusing sales from tills in the field.
      const op = saleOp(a, { terminalSeq: 1 });
      op.payload.payments = [];
      const response = await push(a, [op], '1.0.0').expect(201);
      expect(response.body.acks[0].status).toBe('applied');
    });

    it('pulls under 1.6.0 with everything it reads still in place', async () => {
      await customer();
      const body = await pull(a, 0, '1.6.0');
      expect(body.products.length).toBeGreaterThan(0);
      expect(Array.isArray(body.stockBatches)).toBe(true);
    });
  });
});
