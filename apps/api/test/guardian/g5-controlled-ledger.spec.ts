import request from 'supertest';
import { uuidv7 } from 'uuidv7';
import { PSYCHOTROPIC_RULES } from '@pharmaet/contracts';
import { TestHarness, type SeededTenant } from '../harness';
import { TERMINAL, controlledAdjustmentOp, dispenseOp, saleOp } from '../helpers/build-ops';

/**
 * THE CONTROLLED-SUBSTANCE LEDGER (FR-4 §4a–4b, FR-6; ADR-004, ADR-024).
 *
 * Built ahead of A-1 by owner decision, so this suite asserts two things at once:
 *
 *  - **With the switch off, nothing regulated happens.** Every controlled operation is
 *    refused and writes nothing — the state every deployed environment is in until A-1 is
 *    verified.
 *  - **With the switch on, the rules hold.** AC-4.2 (one psychotropic per prescription,
 *    blocked), AC-4.3 (expired prescription rejected), AC-6.1 (no edit, no delete — only a
 *    compensating event), AC-6.2 (a complete, ordered history), BR-3.3 (stock is a projection
 *    over events and rebuilds exactly), and tenant isolation.
 *
 * The rule *numbers* are provisional (`PSYCHOTROPIC_RULES.status`); the mechanism is not.
 * When A-1 is verified, the numbers change in one file and these assertions follow them.
 */
describe('G5 — the controlled-substance ledger (ADR-024)', () => {
  let harness: TestHarness;
  let tenant: SeededTenant;
  let other: SeededTenant;
  const server = () => harness.app.getHttpServer();
  let seq = 0;

  const push = (t: SeededTenant, ops: unknown[], token = t.users.cashier.token) =>
    request(server())
      .post('/api/sync/push')
      .set('authorization', `Bearer ${token}`)
      .send({ terminalId: TERMINAL, operations: ops })
      .expect(201);

  const controlledCount = async (tenantId: string) =>
    (
      await harness.platformDataSource.query(
        `SELECT count(*)::int AS n FROM event WHERE tenant_id = $1 AND stream = 'controlled_stock'`,
        [tenantId],
      )
    )[0].n;

  const projected = async (t: SeededTenant, productId = t.controlledProductId) => {
    const rows = await harness.platformDataSource.query(
      `SELECT qty_on_hand FROM controlled_stock_view WHERE tenant_id = $1 AND product_id = $2`,
      [t.id, productId],
    );
    return rows.length ? Number(rows[0].qty_on_hand) : 0;
  };

  const receiveControlled = (t: SeededTenant, qty: number) => ({
    opId: uuidv7(),
    terminalId: TERMINAL,
    terminalSeq: ++seq,
    entityId: uuidv7(),
    opType: 'create' as const,
    baseVersion: null,
    tenantId: t.id,
    branchId: t.branchIds[0],
    actorId: t.users.manager.id,
    clientTs: '2026-09-21T08:00:00.000Z',
    entityType: 'goods_receipt' as const,
    payload: {
      supplierName: 'EPSA',
      receivedAt: '2026-09-21T08:00:00.000Z',
      lines: [
        {
          id: uuidv7(),
          productId: t.controlledProductId,
          lotNo: 'DZP-40',
          expiryDate: '2028-01-31',
          qty,
          costSantim: 2500,
        },
      ],
    },
  });

  beforeAll(async () => {
    harness = await TestHarness.start();
  });

  beforeEach(async () => {
    delete process.env.CONTROLLED_DISPENSING;
    await harness.reset();
    tenant = await harness.seedTenant('abay', 1500);
    other = await harness.seedTenant('tana', 1500);
  });

  afterEach(() => {
    delete process.env.CONTROLLED_DISPENSING;
  });

  afterAll(async () => harness?.stop());

  describe('switched off — the state until A-1 is verified', () => {
    it('refuses a dispense and writes nothing: no event, no sale, no projection', async () => {
      const response = await push(tenant, [dispenseOp(tenant, { terminalSeq: ++seq })]);

      expect(response.body.acks[0].status).toBe('rejected');
      expect(response.body.acks[0].reason).toMatch(/switched off.*A-1/);
      expect(await controlledCount(tenant.id)).toBe(0);
      const sales = await harness.platformDataSource.query(
        `SELECT count(*)::int AS n FROM sale WHERE tenant_id = $1`,
        [tenant.id],
      );
      expect(sales[0].n).toBe(0);
    });

    it('refuses a controlled receipt and an adjustment the same way', async () => {
      const response = await push(tenant, [
        receiveControlled(tenant, 40),
        controlledAdjustmentOp(tenant, { terminalSeq: ++seq, delta: 1 }),
      ]);
      expect(response.body.acks.map((a: { status: string }) => a.status)).toEqual([
        'rejected',
        'rejected',
      ]);
      expect(await controlledCount(tenant.id)).toBe(0);
    });

    it('reports itself off, so a terminal can hide dispensing', async () => {
      const health = await request(server()).get('/api/health').expect(200);
      expect(health.body.features.controlledDispensing).toBe(false);
    });
  });

  describe('switched on', () => {
    beforeEach(() => {
      process.env.CONTROLLED_DISPENSING = 'on';
    });

    it('a receipt of controlled stock is an event, not a batch', async () => {
      await push(tenant, [receiveControlled(tenant, 40)], tenant.users.manager.token);

      expect(await projected(tenant)).toBe(40);
      const batches = await harness.platformDataSource.query(
        `SELECT count(*)::int AS n FROM stock_batch WHERE product_id = $1`,
        [tenant.controlledProductId],
      );
      expect(batches[0].n).toBe(0);
    });

    it('a dispense writes the sale and the ledger event together, and counts toward the till', async () => {
      await push(tenant, [receiveControlled(tenant, 40)], tenant.users.manager.token);
      const response = await push(tenant, [dispenseOp(tenant, { terminalSeq: ++seq, qty: 2 })]);
      expect(response.body.acks[0].status).toBe('applied');

      expect(await projected(tenant)).toBe(38);
      const [event] = await harness.platformDataSource.query(
        `SELECT event_type, payload FROM event
          WHERE tenant_id = $1 AND event_type = 'controlled.dispensed'`,
        [tenant.id],
      );
      // BR-4.3 — who, when, where, and the prescription it was dispensed against.
      expect(event.payload.prescriptionNumber).toBe('RX-PSY-00417');
      expect(event.payload.dispensedBy).toBe(tenant.users.cashier.id);
      expect(event.payload.rules).toBe(PSYCHOTROPIC_RULES.status);

      const payments = await harness.platformDataSource.query(
        `SELECT method, amount_santim FROM payment WHERE tenant_id = $1`,
        [tenant.id],
      );
      expect(payments).toEqual([{ method: 'cash', amount_santim: '8000' }]);
    });

    it('AC-4.2 — a second psychotropic on the same prescription is blocked', async () => {
      const lorazepam = uuidv7();
      await harness.platformDataSource.query(
        `INSERT INTO product (id, tenant_id, name, unit, is_controlled, psychotropic_class, current_price_santim, change_seq)
         VALUES ($1, $2, 'lorazepam 1mg', 'tablet', true, 'schedule-iv', 3000, 999)`,
        [lorazepam, tenant.id],
      );

      const first = await push(tenant, [dispenseOp(tenant, { terminalSeq: ++seq })]);
      expect(first.body.acks[0].status).toBe('applied');

      // Written differently, same paper: the rule compares the normalised number.
      const second = await push(tenant, [
        dispenseOp(tenant, { terminalSeq: ++seq, productId: lorazepam, rxNumber: 'rx psy 00417' }),
      ]);
      expect(second.body.acks[0].status).toBe('rejected');
      expect(second.body.acks[0].reason).toMatch(/only one is allowed per prescription/);

      // The same substance again on the same paper — a split dispense — is allowed.
      const again = await push(tenant, [dispenseOp(tenant, { terminalSeq: ++seq })]);
      expect(again.body.acks[0].status).toBe('applied');
    });

    it(`AC-4.3 — a prescription older than ${PSYCHOTROPIC_RULES.psychotropicValidityDays} days is rejected as expired`, async () => {
      const lastGoodDay = await push(tenant, [
        dispenseOp(tenant, {
          terminalSeq: ++seq,
          rxNumber: 'RX-1',
          issuedOn: '2026-09-01',
          dispensedAt: '2026-09-16T08:00:00.000Z',
        }),
      ]);
      expect(lastGoodDay.body.acks[0].status).toBe('applied');

      const expired = await push(tenant, [
        dispenseOp(tenant, {
          terminalSeq: ++seq,
          rxNumber: 'RX-2',
          issuedOn: '2026-09-01',
          dispensedAt: '2026-09-17T08:00:00.000Z',
        }),
      ]);
      expect(expired.body.acks[0].status).toBe('rejected');
      expect(expired.body.acks[0].reason).toMatch(/expired/);
    });

    it('a controlled product can never leave through the standard sale path', async () => {
      const op = saleOp(tenant, { terminalSeq: ++seq, batchId: null });
      op.payload.lines[0].productId = tenant.controlledProductId;
      const response = await push(tenant, [op]);
      expect(response.body.acks[0].status).toBe('rejected');
      expect(response.body.acks[0].reason).toMatch(/through the ledger/);
    });

    it('AC-6.1 — an event cannot be edited or deleted; a correction is a new event', async () => {
      await push(tenant, [receiveControlled(tenant, 40)], tenant.users.manager.token);
      const [event] = await harness.platformDataSource.query(
        `SELECT id FROM event WHERE tenant_id = $1 AND stream = 'controlled_stock'`,
        [tenant.id],
      );

      // Refused by the database itself, even on the owner-privileged connection.
      await expect(
        harness.platformDataSource.query(
          `UPDATE event SET payload = '{}'::jsonb WHERE id = $1`,
          [event.id],
        ),
      ).rejects.toThrow();
      await expect(
        harness.platformDataSource.query(`DELETE FROM event WHERE id = $1`, [event.id]),
      ).rejects.toThrow();

      const correction = await push(
        tenant,
        [controlledAdjustmentOp(tenant, { terminalSeq: ++seq, delta: -1, correctsEventId: event.id })],
        tenant.users.manager.token,
      );
      expect(correction.body.acks[0].status).toBe('applied');
      expect(await projected(tenant)).toBe(39);
      expect(await controlledCount(tenant.id)).toBe(2);
    });

    it('AC-6.2 — the ledger reads back complete and ordered, and exports for an inspector', async () => {
      await push(tenant, [receiveControlled(tenant, 40)], tenant.users.manager.token);
      await push(tenant, [dispenseOp(tenant, { terminalSeq: ++seq, qty: 3 })]);
      await push(
        tenant,
        [controlledAdjustmentOp(tenant, { terminalSeq: ++seq, delta: 1 })],
        tenant.users.manager.token,
      );

      const ledger = await request(server())
        .get('/api/ledger?from=2026-09-01&to=2026-10-01')
        .set('authorization', `Bearer ${tenant.users.owner.token}`)
        .expect(200);
      expect(ledger.body.map((e: { eventType: string }) => e.eventType)).toEqual([
        'controlled.received',
        'controlled.dispensed',
        'controlled.adjusted',
      ]);
      expect(ledger.body.map((e: { seq: number }) => e.seq)).toEqual([1, 2, 3]);

      const csv = await request(server())
        .get('/api/ledger/export?from=2026-09-01&to=2026-10-01')
        .set('authorization', `Bearer ${tenant.users.owner.token}`)
        .expect(200);
      expect(csv.headers['content-type']).toMatch(/text\/csv/);
      expect(csv.text).toContain('RX-PSY-00417');
      expect(csv.text).toContain('provisional');
    });

    it('BR-3.3 — the projection is exactly the sum of the events', async () => {
      await push(tenant, [receiveControlled(tenant, 40)], tenant.users.manager.token);
      await push(tenant, [dispenseOp(tenant, { terminalSeq: ++seq, qty: 5 })]);
      await push(
        tenant,
        [controlledAdjustmentOp(tenant, { terminalSeq: ++seq, delta: -2 })],
        tenant.users.manager.token,
      );

      const { LedgerService } = await import('../../src/modules/ledger/ledger.service');
      const ledger = harness.app.get(LedgerService);
      const drift = await harness.platformDataSource.transaction((em) =>
        ledger.verifyProjection(em, tenant.id),
      );
      expect(drift).toEqual([]);
      expect(await projected(tenant)).toBe(33);
    });

    it('a pharmacy never sees another pharmacy’s ledger, nor a cashier any ledger', async () => {
      await push(other, [receiveControlled(other, 12)], other.users.manager.token);

      const mine = await request(server())
        .get('/api/ledger?from=2026-09-01&to=2026-10-01')
        .set('authorization', `Bearer ${tenant.users.owner.token}`)
        .expect(200);
      expect(mine.body).toEqual([]);

      const stock = await request(server())
        .get('/api/ledger/stock')
        .set('authorization', `Bearer ${tenant.users.owner.token}`)
        .expect(200);
      expect(stock.body).toEqual([]);

      await request(server())
        .get('/api/ledger')
        .set('authorization', `Bearer ${tenant.users.cashier.token}`)
        .expect(403);
    });

    it('a replayed dispense is a duplicate, never a second dispense', async () => {
      const op = dispenseOp(tenant, { terminalSeq: ++seq });
      await push(tenant, [op]);
      const replay = await push(tenant, [op]);
      expect(replay.body.acks[0].status).toBe('duplicate');
      expect(await controlledCount(tenant.id)).toBe(1);
    });
  });
});
