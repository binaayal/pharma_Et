import request from 'supertest';
import { uuidv7 } from 'uuidv7';
import { TestHarness, type SeededTenant } from '../harness';
import { TERMINAL, cashUpOp, saleInShift, shiftOp } from '../helpers/build-ops';

/**
 * G4 — MONEY INTEGRITY, cash reconciliation (FR-8, BR-8.2, AC-8.1).
 *
 * Vision §2.1.1 calls per-shift cash-up the owner's primary anti-shrinkage control and the
 * strongest single reason to adopt this product. That makes its arithmetic load-bearing in
 * a way ordinary reporting is not: a variance that is wrong in either direction destroys
 * the control. Report a shortfall that is not real and the owner learns to ignore it;
 * report a clean till that is not clean and the product is actively covering for theft.
 */
describe('G4 — cash-up integrity', () => {
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

  const report = (shiftId: string, token = tenant.users.owner.token) =>
    request(server())
      .get(`/api/reports/cash-up/${shiftId}`)
      .set('authorization', `Bearer ${token}`);

  it('expected cash is the opening float plus cash taken, and nothing else', async () => {
    const shiftId = uuidv7();
    await push([
      shiftOp(tenant, { terminalSeq: 1, shiftId, openingFloatSantim: 20000 }),
      saleInShift(tenant, { terminalSeq: 2, shiftId, qty: 2, unitPriceSantim: 1500 }), // 3000
      saleInShift(tenant, { terminalSeq: 3, shiftId, qty: 1, unitPriceSantim: 1500 }), // 1500
    ]).expect(201);

    const response = await report(shiftId).expect(200);
    expect(response.body.cashTakenSantim).toBe(4500);
    expect(response.body.serverExpectedSantim).toBe(24500);
    expect(response.body.saleCount).toBe(2);
  });

  it('excludes non-cash tenders — they never reached the drawer', async () => {
    // Counting them would manufacture a shortfall on every shift that took a transfer, and
    // a control that is always wrong is a control that gets switched off.
    const shiftId = uuidv7();
    await push([
      shiftOp(tenant, { terminalSeq: 1, shiftId, openingFloatSantim: 10000 }),
      saleInShift(tenant, { terminalSeq: 2, shiftId, qty: 1, unitPriceSantim: 1500 }),
      saleInShift(tenant, {
        terminalSeq: 3,
        shiftId,
        qty: 4,
        unitPriceSantim: 1500,
        method: 'other_recorded',
      }),
    ]).expect(201);

    const response = await report(shiftId).expect(200);
    expect(response.body.cashTakenSantim).toBe(1500);
    expect(response.body.serverExpectedSantim).toBe(11500);
  });

  it('records a shortfall against the user and the shift (AC-8.1)', async () => {
    const shiftId = uuidv7();
    await push([
      shiftOp(tenant, { terminalSeq: 1, shiftId, openingFloatSantim: 20000 }),
      saleInShift(tenant, { terminalSeq: 2, shiftId, qty: 2, unitPriceSantim: 1500 }),
      cashUpOp(tenant, {
        terminalSeq: 3,
        shiftId,
        expectedSantim: 23000,
        countedSantim: 22150, // 8.50 ETB short
        note: 'checking receipts',
      }),
    ]).expect(201);

    const response = await report(shiftId).expect(200);
    expect(response.body.varianceSantim).toBe(-850);
    expect(response.body.countedSantim).toBe(22150);
    expect(response.body.userId).toBe(tenant.users.cashier.id);
    expect(response.body.note).toBe('checking receipts');
  });

  it('records an overage too — cash appearing is as much a signal as cash missing', async () => {
    const shiftId = uuidv7();
    await push([
      shiftOp(tenant, { terminalSeq: 1, shiftId, openingFloatSantim: 20000 }),
      cashUpOp(tenant, { terminalSeq: 2, shiftId, expectedSantim: 20000, countedSantim: 20300 }),
    ]).expect(201);

    expect((await report(shiftId).expect(200)).body.varianceSantim).toBe(300);
  });

  it('refuses a variance that does not equal counted minus expected', async () => {
    const shiftId = uuidv7();
    await push([shiftOp(tenant, { terminalSeq: 1, shiftId })]).expect(201);

    const tampered = cashUpOp(tenant, {
      terminalSeq: 2,
      shiftId,
      expectedSantim: 30000,
      countedSantim: 25000,
    });
    // A client claiming a clean till while the numbers say 50 ETB is missing is exactly the
    // fraud this control exists to catch, so the contract refuses the envelope outright.
    (tampered.payload as { varianceSantim: number }).varianceSantim = 0;

    await push([tampered]).expect(400);
  });

  it('never overwrites the figure the cashier was shown (ADR-012 §3)', async () => {
    // The cashier counted against 23,000 because one sale had not synced. The server now
    // knows better — and records its own figure beside, not over, theirs. Rewriting it
    // would destroy the evidence of what they actually agreed to.
    const shiftId = uuidv7();
    await push([
      shiftOp(tenant, { terminalSeq: 1, shiftId, openingFloatSantim: 20000 }),
      saleInShift(tenant, { terminalSeq: 2, shiftId, qty: 2, unitPriceSantim: 1500 }),
      cashUpOp(tenant, { terminalSeq: 3, shiftId, expectedSantim: 23000, countedSantim: 23000 }),
      // The straggler lands afterwards, as it would on reconnect.
      saleInShift(tenant, { terminalSeq: 4, shiftId, qty: 1, unitPriceSantim: 1500 }),
    ]).expect(201);

    const response = await report(shiftId).expect(200);
    expect(response.body.terminalExpectedSantim).toBe(23000);
    expect(response.body.varianceSantim).toBe(0);
    expect(response.body.serverExpectedSantim).toBe(24500);
    // The gap is surfaced rather than reconciled away — it is the finding.
    expect(response.body.expectationGapSantim).toBe(1500);
  });

  it('shows an unreconciled shift rather than hiding it', async () => {
    // A till closed with nobody counting it is exactly what an owner needs to notice.
    const shiftId = uuidv7();
    await push([shiftOp(tenant, { terminalSeq: 1, shiftId, openingFloatSantim: 5000 })]).expect(
      201,
    );

    const response = await report(shiftId).expect(200);
    expect(response.body.countedSantim).toBeNull();
    expect(response.body.varianceSantim).toBeNull();
    expect(response.body.serverExpectedSantim).toBe(5000);
  });

  it('reconciles a shift exactly once', async () => {
    // Two conflicting statements about one till, with no way to tell which a person signed.
    const shiftId = uuidv7();
    await push([
      shiftOp(tenant, { terminalSeq: 1, shiftId }),
      cashUpOp(tenant, { terminalSeq: 2, shiftId, expectedSantim: 20000, countedSantim: 20000 }),
    ]).expect(201);

    const second = await push([
      cashUpOp(tenant, { terminalSeq: 3, shiftId, expectedSantim: 20000, countedSantim: 19000 }),
    ]).expect(201);

    expect(second.body.acks[0].status).toBe('rejected');
  });

  it('refuses a cash-up whose shift has not arrived', async () => {
    // Rejected, not orphaned: the client parks it and retries once the shift lands.
    const orphan = await push([
      cashUpOp(tenant, {
        terminalSeq: 1,
        shiftId: uuidv7(),
        expectedSantim: 1000,
        countedSantim: 1000,
      }),
    ]).expect(201);

    expect(orphan.body.acks[0].status).toBe('rejected');
    expect(orphan.body.acks[0].reason).toMatch(/shift/i);
  });

  it('stores cash-up money as bigint, with no float anywhere in the path', async () => {
    const shiftId = uuidv7();
    await push([
      shiftOp(tenant, { terminalSeq: 1, shiftId, openingFloatSantim: 19999 }),
      cashUpOp(tenant, { terminalSeq: 2, shiftId, expectedSantim: 19999, countedSantim: 19998 }),
    ]).expect(201);

    const rows = await harness.platformDataSource.query(
      `SELECT pg_typeof(counted_santim)::text AS t, variance_santim FROM cash_up WHERE tenant_id = $1`,
      [tenant.id],
    );
    expect(rows[0].t).toBe('bigint');
    expect(Number(rows[0].variance_santim)).toBe(-1);
  });

  it("keeps one tenant's cash-ups out of another's report (G1 still holds)", async () => {
    const other = await harness.seedTenant('tana');
    const shiftId = uuidv7();
    await push([
      shiftOp(tenant, { terminalSeq: 1, shiftId }),
      cashUpOp(tenant, { terminalSeq: 2, shiftId, expectedSantim: 20000, countedSantim: 19000 }),
    ]).expect(201);

    await request(server())
      .get(`/api/reports/cash-up/${shiftId}`)
      .set('authorization', `Bearer ${other.users.owner.token}`)
      .expect(500); // RLS makes the row invisible; the lookup finds nothing

    const summary = await request(server())
      .get('/api/reports/cash-up')
      .set('authorization', `Bearer ${other.users.owner.token}`)
      .expect(200);
    expect(summary.body).toHaveLength(0);
  });

  it("lets a cashier read their own shift but not a colleague's (FR-2 matrix)", async () => {
    const shiftId = uuidv7();
    await push([shiftOp(tenant, { terminalSeq: 1, shiftId })]).expect(201);
    await report(shiftId, tenant.users.cashier.token).expect(200);

    const managersShift = uuidv7();
    await push([
      {
        ...shiftOp(tenant, { terminalSeq: 2, shiftId: managersShift }),
        payload: {
          userId: tenant.users.manager.id,
          openedAt: '2026-09-23T06:00:00.000Z',
          closedAt: null,
          openingFloatSantim: 20000,
        },
      },
    ]).expect(201);

    await report(managersShift, tenant.users.cashier.token).expect(403);
  });
});
