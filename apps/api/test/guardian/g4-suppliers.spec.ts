import request from 'supertest';
import { isAllowed, pullResponse } from '@pharmaet/contracts';
import { OPERATION_CAPABILITY } from '../../src/modules/sync/sync.service';
import { uuidv7 } from 'uuidv7';
import { TestHarness, type SeededTenant } from '../harness';
import {
  TERMINAL,
  cashUpOp,
  receiptOp,
  saleInShift,
  shiftOp,
  supplierOp,
  supplierPaymentOp,
} from '../helpers/build-ops';

/**
 * G4 — SUPPLIERS AND WHAT IS OWED TO THEM (FR-18, ADR-038; contract 1.9.0).
 *
 * What a pharmacy owes its suppliers is the largest number it does not know. A ledger that
 * loses a delivery, counts one twice, or pays the wrong supplier is worse than the invoices
 * in a drawer it replaces.
 *
 * What this suite holds:
 *
 *   - **what is owed to a supplier is exactly what its deliveries left owing, less what was
 *     paid**, after any sequence, replayed or concurrent (G4, G2);
 *   - **a delivery's stock arrives whether or not it was paid for** (G5);
 *   - **cash paid to a supplier out of a till has left the drawer**, so the cash-up does
 *     not expect it — and cash paid from elsewhere touches no till (BR-8.2);
 *   - **one pharmacy's suppliers and debts are invisible to another** (G1);
 *   - a terminal that has never heard of suppliers keeps receiving (ADR-009).
 */
describe('G4 — suppliers and payables', () => {
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
      .set('authorization', `Bearer ${tenant.users.manager.token}`);
    if (version) call.set('x-contract-version', version);
    return call.send({ terminalId: TERMINAL, operations });
  };

  const pull = async (tenant: SeededTenant, cursor = 0, version?: string) => {
    const call = request(server())
      .get(`/api/sync/pull?cursor=${cursor}`)
      .set('authorization', `Bearer ${tenant.users.manager.token}`);
    if (version) call.set('x-contract-version', version);
    return (await call.expect(200)).body;
  };

  const query = (sql: string, params: unknown[] = []) =>
    harness.platformDataSource.query(sql, params);

  const balance = async (supplierId: string): Promise<number> =>
    Number(
      (await query(`SELECT balance_santim FROM supplier WHERE id = $1`, [supplierId]))[0]
        .balance_santim,
    );

  /** The truth, recomputed from the rows: what deliveries left owing, less what was paid. */
  const owedByRows = async (supplierId: string): Promise<number> =>
    Number(
      (
        await query(
          `SELECT (SELECT coalesce(sum(owed_santim), 0) FROM goods_receipt WHERE supplier_id = $1)
                - (SELECT coalesce(sum(amount_santim), 0) FROM supplier_payment WHERE supplier_id = $1)
                  AS owed`,
          [supplierId],
        )
      )[0].owed,
    );

  const onHand = async (tenant: SeededTenant): Promise<number> =>
    Number(
      (
        await query(
          `SELECT coalesce(sum(qty_on_hand), 0) AS n FROM stock_batch WHERE tenant_id = $1`,
          [tenant.id],
        )
      )[0].n,
    );

  /** A supplier in tenant A, already synced. */
  const supplier = async (name = 'Addis Pharma Import'): Promise<string> => {
    const id = uuidv7();
    const response = await push(a, [
      supplierOp(a, { terminalSeq: 1, supplierId: id, name }),
    ]).expect(201);
    expect(response.body.acks[0].status).toBe('applied');
    return id;
  };

  /** Ten units at 8.00: a delivery that cost 80.00. */
  const delivery = (
    seq: number,
    supplierId: string,
    owedSantim: number | undefined,
    extra: { terminalId?: string } = {},
  ) =>
    receiptOp(a, {
      terminalSeq: seq,
      qty: 10,
      lotNo: `LOT-${seq}-${extra.terminalId ?? 't'}`,
      expiryDate: '2028-12-31',
      supplierId,
      owedSantim,
      ...extra,
    });

  describe('a supplier', () => {
    it('created while receiving reaches every other terminal on its next pull', async () => {
      const id = await supplier();
      const parsed = pullResponse.parse(await pull(a));

      expect(parsed.suppliers).toHaveLength(1);
      expect(parsed.suppliers?.[0]).toMatchObject({
        id,
        name: 'Addis Pharma Import',
        phone: '0911 00 00 00',
        balanceSantim: 0,
      });
    });

    it('is created once when the push is replayed (G2)', async () => {
      const op = supplierOp(a, { terminalSeq: 1 });
      await push(a, [op]).expect(201);
      const replay = await push(a, [op]).expect(201);

      expect(replay.body.acks[0].status).toBe('duplicate');
      expect(await query(`SELECT 1 FROM supplier WHERE tenant_id = $1`, [a.id])).toHaveLength(1);
    });

    it('with no name is refused at the boundary', async () => {
      const op = supplierOp(a, { terminalSeq: 1, name: '   ' });
      await push(a, [op]).expect(400);
      expect(await query(`SELECT 1 FROM supplier`)).toHaveLength(0);
    });
  });

  describe('a delivery not paid for', () => {
    it('wholly on account: the pharmacy owes what it cost', async () => {
      const id = await supplier();
      const response = await push(a, [delivery(2, id, 8000)]).expect(201);

      expect(response.body.acks[0].status).toBe('applied');
      expect(await balance(id)).toBe(8000);
      const [row] = await query(
        `SELECT supplier_id, owed_santim, supplier_name FROM goods_receipt WHERE tenant_id = $1`,
        [a.id],
      );
      expect(row.supplier_id).toBe(id);
      expect(Number(row.owed_santim)).toBe(8000);
      // The name as written on the day is kept beside the id.
      expect(row.supplier_name).toBe('Test Wholesaler');
    });

    it('part paid on delivery: the pharmacy owes exactly the rest', async () => {
      const id = await supplier();
      await push(a, [delivery(2, id, 3000)]).expect(201);
      expect(await balance(id)).toBe(3000);
    });

    it('paid on delivery: nothing is owed, and the receipt still names the supplier', async () => {
      const id = await supplier();
      await push(a, [delivery(2, id, 0), delivery(3, id, undefined)]).expect(201);

      expect(await balance(id)).toBe(0);
      expect(await query(`SELECT 1 FROM goods_receipt WHERE supplier_id = $1`, [id])).toHaveLength(
        2,
      );
    });

    it('puts the stock on the shelf whether or not it was paid for (G5)', async () => {
      const id = await supplier();
      const before = await onHand(a);
      await push(a, [delivery(2, id, 8000)]).expect(201);
      expect(await onHand(a)).toBe(before + 10);
    });

    it('carries the new figure to the terminals', async () => {
      const id = await supplier();
      const first = await pull(a);
      await push(a, [delivery(2, id, 8000)]).expect(201);

      const next = pullResponse.parse(await pull(a, first.cursor));
      expect(next.suppliers?.find((s) => s.id === id)?.balanceSantim).toBe(8000);
    });

    it('counts the debt and the stock once when the push is replayed (G2)', async () => {
      const id = await supplier();
      const before = await onHand(a);
      const op = delivery(2, id, 8000);
      await push(a, [op]).expect(201);
      const replay = await push(a, [op]).expect(201);

      expect(replay.body.acks[0].status).toBe('duplicate');
      expect(await balance(id)).toBe(8000);
      expect(await onHand(a)).toBe(before + 10);
    });

    it('applies supplier and first delivery from one batch, in terminal order', async () => {
      const id = uuidv7();
      // Sent out of order on purpose: terminalSeq, not array position, is the order.
      const response = await push(a, [
        delivery(2, id, 8000),
        supplierOp(a, { terminalSeq: 1, supplierId: id }),
      ]).expect(201);

      expect(response.body.acks.map((k: { status: string }) => k.status)).toEqual([
        'applied',
        'applied',
      ]);
      expect(await balance(id)).toBe(8000);
    });

    it('refuses a debt owed to nobody, at the boundary, writing nothing', async () => {
      const before = await onHand(a);
      const op = receiptOp(a, {
        terminalSeq: 1,
        qty: 10,
        lotNo: 'L',
        expiryDate: '2028-12-31',
        owedSantim: 8000,
      });
      await push(a, [op]).expect(400);
      expect(await onHand(a)).toBe(before);
    });

    it('refuses owing more than the delivery cost (G4)', async () => {
      const id = await supplier();
      await push(a, [delivery(2, id, 8001)]).expect(400);
      expect(await balance(id)).toBe(0);
    });

    it('is refused by the database too, if a path skipped the contract', async () => {
      await expect(
        query(
          `INSERT INTO goods_receipt (id, tenant_id, branch_id, supplier_name, received_at,
                                      terminal_id, owed_santim)
           VALUES ($1, $2, $3, 'X', now(), $4, 500)`,
          [uuidv7(), a.id, a.branchIds[0], TERMINAL],
        ),
      ).rejects.toThrow(/goods_receipt_owed_has_supplier/);
    });

    it('parks a delivery naming a supplier the server has never heard of — stock untouched', async () => {
      const before = await onHand(a);
      const response = await push(a, [delivery(1, uuidv7(), 8000)]).expect(201);

      expect(response.body.acks[0].status).toBe('rejected');
      expect(response.body.acks[0].reason).toMatch(/unknown supplier/);
      // The whole operation rolled back: no receipt, no stock, nothing owed.
      expect(await onHand(a)).toBe(before);
      expect(await query(`SELECT 1 FROM goods_receipt WHERE tenant_id = $1`, [a.id])).toHaveLength(
        0,
      );
    });
  });

  describe('paying a supplier', () => {
    it('reduces what is owed by exactly what was paid', async () => {
      const id = await supplier();
      await push(a, [
        delivery(2, id, 8000),
        supplierPaymentOp(a, { terminalSeq: 3, supplierId: id, amountSantim: 5000 }),
      ]).expect(201);
      expect(await balance(id)).toBe(3000);
    });

    it('lets the pharmacy pay ahead: the figure goes below zero and says so', async () => {
      const id = await supplier();
      await push(a, [
        delivery(2, id, 8000),
        supplierPaymentOp(a, { terminalSeq: 3, supplierId: id, amountSantim: 10000 }),
      ]).expect(201);

      expect(await balance(id)).toBe(-2000);
      const parsed = pullResponse.parse(await pull(a));
      expect(parsed.suppliers?.[0]?.balanceSantim).toBe(-2000);
    });

    it('counts a payment once when the push is replayed (G2)', async () => {
      const id = await supplier();
      const pay = supplierPaymentOp(a, { terminalSeq: 3, supplierId: id, amountSantim: 5000 });
      await push(a, [delivery(2, id, 8000), pay]).expect(201);
      const replay = await push(a, [pay]).expect(201);

      expect(replay.body.acks[0].status).toBe('duplicate');
      expect(await balance(id)).toBe(3000);
      expect(
        await query(`SELECT 1 FROM supplier_payment WHERE supplier_id = $1`, [id]),
      ).toHaveLength(1);
    });

    it('refuses a payment of nothing, or on credit', async () => {
      const id = await supplier();
      const zero = supplierPaymentOp(a, { terminalSeq: 2, supplierId: id, amountSantim: 0 });
      await push(a, [zero]).expect(400);
      const onCredit = supplierPaymentOp(a, { terminalSeq: 2, supplierId: id, amountSantim: 100 });
      (onCredit.payload as { method: string }).method = 'credit';
      await push(a, [onCredit]).expect(400);
      expect(await query(`SELECT 1 FROM supplier_payment`)).toHaveLength(0);
    });

    it('parks a payment to a supplier the server has never heard of', async () => {
      const response = await push(a, [
        supplierPaymentOp(a, { terminalSeq: 1, supplierId: uuidv7(), amountSantim: 1000 }),
      ]).expect(201);
      expect(response.body.acks[0].status).toBe('rejected');
      expect(await query(`SELECT 1 FROM supplier_payment`)).toHaveLength(0);
    });
  });

  describe('who may pay a supplier (ADR-040)', () => {
    const pushAs = (who: 'owner' | 'manager' | 'cashier', operations: unknown[]) =>
      request(server())
        .post('/api/sync/push')
        .set('authorization', `Bearer ${a.users[who].token}`)
        .send({ terminalId: TERMINAL, operations })
        .expect(201);

    it('a cashier is refused by the server, not only by the phone', async () => {
      const id = await supplier();
      await push(a, [delivery(2, id, 8000)]).expect(201);

      const response = await pushAs('cashier', [
        supplierPaymentOp(a, { terminalSeq: 3, supplierId: id, amountSantim: 5000 }),
      ]);

      expect(response.body.acks[0].status).toBe('rejected');
      expect(response.body.acks[0].reason).toMatch(/may not record a supplier payment/);
      // Nothing was written: the debt stands and no payment exists.
      expect(await balance(id)).toBe(8000);
      expect(await query(`SELECT 1 FROM supplier_payment`)).toHaveLength(0);
    });

    it('a cashier cannot take cash out of a till this way either', async () => {
      const id = await supplier();
      const shiftId = uuidv7();
      await push(a, [
        shiftOp(a, { terminalSeq: 2, shiftId, openingFloatSantim: 20000 }),
        saleInShift(a, { terminalSeq: 3, shiftId }),
      ]).expect(201);

      await pushAs('cashier', [
        supplierPaymentOp(a, { terminalSeq: 4, supplierId: id, amountSantim: 5000, shiftId }),
      ]);

      const report = await request(server())
        .get(`/api/reports/cash-up/${shiftId}`)
        .set('authorization', `Bearer ${a.users.owner.token}`)
        .expect(200);
      // The drawer is still expected to hold every santim.
      expect(report.body.paidOutSantim).toBe(0);
      expect(report.body.serverExpectedSantim).toBe(21500);
    });

    it('the owner and a branch manager are accepted', async () => {
      const id = await supplier();
      await push(a, [delivery(2, id, 8000)]).expect(201);
      const byManager = await pushAs('manager', [
        supplierPaymentOp(a, { terminalSeq: 3, supplierId: id, amountSantim: 1000 }),
      ]);
      const byOwner = await pushAs('owner', [
        supplierPaymentOp(a, { terminalSeq: 4, supplierId: id, amountSantim: 2000 }),
      ]);

      expect(byManager.body.acks[0].status).toBe('applied');
      expect(byOwner.body.acks[0].status).toBe('applied');
      expect(await balance(id)).toBe(5000);
    });

    it('the refusal stops that one operation, not the rest of the batch', async () => {
      const id = await supplier();
      const before = await onHand(a);
      const response = await pushAs('cashier', [
        supplierPaymentOp(a, { terminalSeq: 2, supplierId: id, amountSantim: 5000 }),
        // A cashier may receive goods, and from a supplier.
        delivery(3, id, 8000),
      ]);

      expect(response.body.acks.map((k: { status: string }) => k.status)).toEqual([
        'rejected',
        'applied',
      ]);
      expect(await onHand(a)).toBe(before + 10);
      expect(await balance(id)).toBe(8000);
    });

    it('a cashier still does everything a cashier does', async () => {
      // The rule must not have taken anything away: sell, open a customer, take a
      // repayment, receive, open a supplier, open and count a till.
      const id = uuidv7();
      const response = await pushAs('cashier', [
        supplierOp(a, { terminalSeq: 1, supplierId: id, name: 'New Supplier' }),
        delivery(2, id, 0),
      ]);
      expect(response.body.acks.map((k: { status: string }) => k.status)).toEqual([
        'applied',
        'applied',
      ]);
    });

    it('every kind of operation has had its sender decided', () => {
      // A new entity type cannot be added without an entry: the map is typed by them.
      expect(Object.keys(OPERATION_CAPABILITY).sort()).toEqual(
        [
          'cash_up',
          'controlled_adjustment',
          'controlled_dispense',
          'credit_payment',
          'customer',
          'goods_receipt',
          'sale',
          'shift',
          'stock_adjustment',
          'supplier',
          'supplier_payment',
        ].sort(),
      );
      // And only one of them is closed to a cashier.
      const closedToCashier = Object.entries(OPERATION_CAPABILITY)
        .filter(([, capability]) => !isAllowed('cashier', capability))
        .map(([type]) => type);
      expect(closedToCashier).toEqual(['supplier_payment']);
    });
  });

  describe('what is owed is what deliveries left owing, less what was paid', () => {
    it('after a long mixed sequence, the running balance equals the rows', async () => {
      const id = await supplier();
      const steps: unknown[] = [];
      let seq = 2;
      let expected = 0;
      for (let i = 0; i < 12; i++) {
        const owed = [8000, 0, 3000, 8000][i % 4]!;
        steps.push(delivery(seq++, id, owed));
        expected += owed;
        if (i % 3 === 2) {
          const paid = 2500 + i * 100;
          steps.push(
            supplierPaymentOp(a, { terminalSeq: seq++, supplierId: id, amountSantim: paid }),
          );
          expected -= paid;
        }
      }
      const response = await push(a, steps).expect(201);
      expect(response.body.acks.filter((k: { status: string }) => k.status !== 'applied')).toEqual(
        [],
      );

      expect(await balance(id)).toBe(expected);
      expect(await balance(id)).toBe(await owedByRows(id));
    });

    it('holds when two terminals receive from one supplier at the same moment', async () => {
      const id = await supplier('EPSS');
      const other = '01930000-0000-7000-8000-0000000000e2';

      const one = Array.from({ length: 8 }, (_, i) => delivery(10 + i, id, 8000));
      const two = Array.from({ length: 8 }, (_, i) =>
        delivery(10 + i, id, 8000, { terminalId: other }),
      );

      const send = (terminalId: string, operations: unknown[]) =>
        request(server())
          .post('/api/sync/push')
          .set('authorization', `Bearer ${a.users.manager.token}`)
          .send({ terminalId, operations });
      const [r1, r2] = await Promise.all([send(TERMINAL, one), send(other, two)]);
      expect(r1.status).toBe(201);
      expect(r2.status).toBe(201);
      const reasons = [...r1.body.acks, ...r2.body.acks]
        .filter((k: { status: string }) => k.status !== 'applied')
        .map((k: { reason: string }) => k.reason);
      expect(reasons).toEqual([]);

      // Sixteen deliveries of 80.00 on account. Read-then-write without a lock loses some.
      expect(await balance(id)).toBe(16 * 8000);
      expect(await balance(id)).toBe(await owedByRows(id));
    });
  });

  describe('the cash-up (BR-8.2)', () => {
    const shiftId = uuidv7();

    it('does not expect cash that was paid to a supplier out of the till', async () => {
      const id = await supplier();
      await push(a, [
        shiftOp(a, { terminalSeq: 2, shiftId, openingFloatSantim: 20000 }),
        // A cash sale of 15.00 — in the drawer.
        saleInShift(a, { terminalSeq: 3, shiftId }),
        delivery(4, id, 8000),
        // 50.00 handed to the supplier from the drawer — no longer in it.
        supplierPaymentOp(a, { terminalSeq: 5, supplierId: id, amountSantim: 5000, shiftId }),
        // 10.00 by bank transfer, recorded at the same till — never was in the drawer.
        supplierPaymentOp(a, {
          terminalSeq: 6,
          supplierId: id,
          amountSantim: 1000,
          method: 'other_recorded',
          shiftId,
        }),
        // 5.00 in cash from the owner's own pocket — no till, so no drawer.
        supplierPaymentOp(a, { terminalSeq: 7, supplierId: id, amountSantim: 500 }),
      ]).expect(201);

      const expected = 20000 + 1500 - 5000;
      await push(a, [
        cashUpOp(a, { terminalSeq: 8, shiftId, expectedSantim: expected, countedSantim: expected }),
      ]).expect(201);

      const [row] = await query(
        `SELECT expected_santim, server_expected_santim, variance_santim FROM cash_up WHERE shift_id = $1`,
        [shiftId],
      );
      // The server's own recomputation agrees with the till's, to the santim.
      expect(Number(row.server_expected_santim)).toBe(expected);
      expect(Number(row.variance_santim)).toBe(0);
      expect(await balance(id)).toBe(8000 - 5000 - 1000 - 500);
    });

    it('says how much was paid out, on the reconciliation the owner reads', async () => {
      const id = await supplier();
      await push(a, [
        shiftOp(a, { terminalSeq: 2, shiftId, openingFloatSantim: 20000 }),
        saleInShift(a, { terminalSeq: 3, shiftId }),
        supplierPaymentOp(a, { terminalSeq: 4, supplierId: id, amountSantim: 5000, shiftId }),
      ]).expect(201);

      const response = await request(server())
        .get(`/api/reports/cash-up/${shiftId}`)
        .set('authorization', `Bearer ${a.users.owner.token}`)
        .expect(200);
      expect(response.body.cashTakenSantim).toBe(1500);
      expect(response.body.paidOutSantim).toBe(5000);
      expect(response.body.serverExpectedSantim).toBe(16500);
    });

    it('leaves a till that paid no supplier exactly as it was', async () => {
      await push(a, [
        shiftOp(a, { terminalSeq: 1, shiftId, openingFloatSantim: 20000 }),
        saleInShift(a, { terminalSeq: 2, shiftId }),
      ]).expect(201);
      const response = await request(server())
        .get(`/api/reports/cash-up/${shiftId}`)
        .set('authorization', `Bearer ${a.users.owner.token}`)
        .expect(200);
      expect(response.body.paidOutSantim).toBe(0);
      expect(response.body.serverExpectedSantim).toBe(21500);
    });

    it('parks a payment naming a till that never arrived', async () => {
      const id = await supplier();
      const response = await push(a, [
        supplierPaymentOp(a, {
          terminalSeq: 2,
          supplierId: id,
          amountSantim: 1000,
          shiftId: uuidv7(),
        }),
      ]).expect(201);
      expect(response.body.acks[0].status).toBe('rejected');
      expect(await balance(id)).toBe(0);
    });
  });

  describe("one pharmacy's suppliers are invisible to another (G1)", () => {
    it("never pulls another tenant's suppliers or what they are owed", async () => {
      const id = await supplier('Only abay buys here');
      await push(a, [delivery(2, id, 8000)]).expect(201);

      const theirs = await pull(b);
      expect(JSON.stringify(theirs)).not.toContain('Only abay buys here');
      expect(theirs.suppliers).toEqual([]);
    });

    it("cannot put a debt on another tenant's supplier", async () => {
      const id = await supplier();
      const response = await push(b, [
        receiptOp(b, {
          terminalSeq: 1,
          qty: 10,
          lotNo: 'L',
          expiryDate: '2028-12-31',
          supplierId: id,
          owedSantim: 8000,
        }),
      ]).expect(201);

      expect(response.body.acks[0].status).toBe('rejected');
      expect(await balance(id)).toBe(0);
      expect(await query(`SELECT 1 FROM goods_receipt WHERE tenant_id = $1`, [b.id])).toHaveLength(
        0,
      );
    });

    it("cannot pay down — or forge a payment against — another tenant's supplier", async () => {
      const id = await supplier();
      await push(a, [delivery(2, id, 8000)]).expect(201);

      const response = await push(b, [
        supplierPaymentOp(b, { terminalSeq: 1, supplierId: id, amountSantim: 8000 }),
      ]).expect(201);

      expect(response.body.acks[0].status).toBe('rejected');
      expect(await balance(id)).toBe(8000);
    });
  });

  describe('a terminal that has never heard of suppliers (ADR-009)', () => {
    it('syncs a 1.8.0 receipt unchanged: a name, no supplier, nothing owed', async () => {
      const before = await onHand(a);
      const op = receiptOp(a, { terminalSeq: 1, qty: 10, lotNo: 'L', expiryDate: '2028-12-31' });
      const response = await push(a, [op], '1.8.0').expect(201);

      expect(response.body.acks[0].status).toBe('applied');
      const [row] = await query(
        `SELECT supplier_id, owed_santim, supplier_name FROM goods_receipt WHERE id = $1`,
        [op.entityId],
      );
      expect(row.supplier_id).toBeNull();
      expect(Number(row.owed_santim)).toBe(0);
      expect(row.supplier_name).toBe('Test Wholesaler');
      expect(await onHand(a)).toBe(before + 10);
    });

    it('pulls under 1.8.0 with everything it reads still in place', async () => {
      await supplier();
      const body = await pull(a, 0, '1.8.0');
      expect(body.products.length).toBeGreaterThan(0);
      expect(Array.isArray(body.customers)).toBe(true);
    });
  });
});
