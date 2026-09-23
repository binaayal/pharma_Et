import request from 'supertest';
import { uuidv7 } from 'uuidv7';
import { TestHarness, type SeededTenant } from '../harness';
import { TERMINAL, saleOp } from '../helpers/build-ops';

/**
 * G2 — SYNC INTEGRITY (docs/05-qa §4; AC-9.1, AC-9.2).
 *
 * The invariant: N operations created offline sync EXACTLY ONCE, in terminal_seq order,
 * with zero loss and zero duplication — including when the push is interrupted and retried.
 *
 * This is the single most consequential suite in the system. A sync bug does not throw an
 * error a pharmacist can see; it quietly doubles a day's takings or loses an afternoon of
 * sales, and nobody notices until the cash does not reconcile.
 */
describe('G2 — sync integrity', () => {
  let harness: TestHarness;
  let tenant: SeededTenant;
  const server = () => harness.app.getHttpServer();

  beforeAll(async () => {
    harness = await TestHarness.start();
  });

  beforeEach(async () => {
    await harness.reset();
    tenant = await harness.seedTenant('abay');
  });

  afterAll(async () => harness?.stop());

  const push = (operations: unknown[], token = tenant.users.cashier.token) =>
    request(server())
      .post('/api/sync/push')
      .set('authorization', `Bearer ${token}`)
      .send({ terminalId: TERMINAL, operations });

  const saleCount = async (): Promise<number> => {
    const rows = await harness.platformDataSource.query(
      `SELECT count(*)::int AS n FROM sale WHERE tenant_id = $1`,
      [tenant.id],
    );
    return rows[0].n;
  };

  it('applies a batch of offline operations exactly once (AC-9.1)', async () => {
    const ops = Array.from({ length: 25 }, (_, i) =>
      saleOp(tenant, { terminalSeq: i + 1, qty: 1, batchId: null }),
    );

    const response = await push(ops).expect(201);

    expect(response.body.acks).toHaveLength(25);
    expect(response.body.acks.every((a: { status: string }) => a.status === 'applied')).toBe(true);
    expect(await saleCount()).toBe(25);
  });

  it('treats a replayed push as a no-op rather than a second sale (AC-9.2)', async () => {
    // The real scenario: the terminal pushed successfully, then lost the connection before
    // it saw the acks. It has no way to know the batch landed, so it retries — and MUST NOT
    // ring up every one of those sales a second time.
    const ops = Array.from({ length: 10 }, (_, i) =>
      saleOp(tenant, { terminalSeq: i + 1, batchId: null }),
    );

    await push(ops).expect(201);
    const afterFirst = await saleCount();

    const replay = await push(ops).expect(201);

    expect(replay.body.acks.every((a: { status: string }) => a.status === 'duplicate')).toBe(true);
    expect(await saleCount()).toBe(afterFirst);
  });

  it('is idempotent per operation, not merely per batch', async () => {
    // A half-acknowledged batch is the common case after a dropped connection: the terminal
    // retries everything it has not seen an ack for, which overlaps what already landed.
    const first = Array.from({ length: 6 }, (_, i) =>
      saleOp(tenant, { terminalSeq: i + 1, batchId: null }),
    );
    await push(first).expect(201);

    const overlapping = [
      ...first.slice(3),
      ...Array.from({ length: 3 }, (_, i) => saleOp(tenant, { terminalSeq: i + 7, batchId: null })),
    ];
    const response = await push(overlapping).expect(201);

    const statuses = response.body.acks.map((a: { status: string }) => a.status);
    expect(statuses.slice(0, 3)).toEqual(['duplicate', 'duplicate', 'duplicate']);
    expect(statuses.slice(3)).toEqual(['applied', 'applied', 'applied']);
    expect(await saleCount()).toBe(9);
  });

  it('applies operations in terminal_seq order regardless of the order they arrive in', async () => {
    // Ordering comes from the monotonic per-terminal counter, never from a device clock
    // (ADR-006). Transport may reorder; the result must not depend on it.
    const ops = Array.from({ length: 8 }, (_, i) =>
      saleOp(tenant, { terminalSeq: i + 1, batchId: null }),
    );
    const shuffled = [...ops].reverse();

    await push(shuffled).expect(201);

    const rows = await harness.platformDataSource.query(
      `SELECT op_id, terminal_seq FROM applied_op WHERE tenant_id = $1 ORDER BY applied_at, terminal_seq`,
      [tenant.id],
    );
    const seqs = rows.map((r: { terminal_seq: string }) => Number(r.terminal_seq));
    expect(seqs).toEqual([...seqs].sort((a, b) => a - b));
  });

  it('does not let one rejected operation take valid ones down with it', async () => {
    // A push is a batch for transport efficiency, never an all-or-nothing transaction. If a
    // single bad operation could roll back the twenty good sales queued behind it, one
    // corrupt record would cost a pharmacy its whole day.
    const good1 = saleOp(tenant, { terminalSeq: 1, batchId: null });
    const poisoned = {
      ...saleOp(tenant, { terminalSeq: 2, batchId: null }),
      // A branch that does not exist: the insert fails the foreign key at the database.
      branchId: uuidv7(),
    };
    const good2 = saleOp(tenant, { terminalSeq: 3, batchId: null });

    const response = await push([good1, poisoned, good2]).expect(201);

    const statuses = response.body.acks.map((a: { status: string }) => a.status);
    expect(statuses).toEqual(['applied', 'rejected', 'applied']);
    expect(await saleCount()).toBe(2);

    // A rejected operation is never silently dropped: it comes back with a reason so the
    // client can park it in a "needs attention" queue rather than losing the transaction.
    const rejected = response.body.acks.find((a: { status: string }) => a.status === 'rejected');
    expect(rejected.reason).toBeTruthy();
  });

  it('does not record an applied_op for an operation it rejected', async () => {
    // Otherwise a transient failure would be remembered as success, and the terminal's
    // retry would come back "duplicate" — losing the transaction permanently and silently.
    const poisoned = { ...saleOp(tenant, { terminalSeq: 1, batchId: null }), branchId: uuidv7() };
    await push([poisoned]).expect(201);

    const rows = await harness.platformDataSource.query(
      `SELECT count(*)::int AS n FROM applied_op WHERE tenant_id = $1`,
      [tenant.id],
    );
    expect(rows[0].n).toBe(0);
  });

  it('refuses a malformed envelope instead of half-applying it', async () => {
    const malformed = saleOp(tenant, { terminalSeq: 1, batchId: null });
    delete (malformed as Record<string, unknown>).opId;

    await push([malformed]).expect(400);
    expect(await saleCount()).toBe(0);
  });

  it("accepts a batch at the contract's maximum size (NFR-1.1)", async () => {
    // Express defaults to a 100 KB body, which rejects any push past roughly 60 operations
    // with a 413. A terminal returning from the guaranteed 72-hour outage pushes exactly
    // such a batch; it would be refused, keep everything in its outbox because nothing was
    // acknowledged, and fail identically on every retry forever. The product's central
    // promise would break precisely in the situation it exists for.
    //
    // 500 is the contract's cap (`pushRequest`), so this is the largest legal request and
    // the server must always accept it.
    const ops = Array.from({ length: 500 }, (_, i) =>
      saleOp(tenant, { terminalSeq: i + 1, qty: 3, batchId: null }),
    );

    const response = await push(ops).expect(201);
    expect(response.body.acks).toHaveLength(500);
    expect(response.body.acks.every((a: { status: string }) => a.status === 'applied')).toBe(true);
    expect(await saleCount()).toBe(500);
  });

  it('advances the pull cursor monotonically as stock changes', async () => {
    const before = await request(server())
      .get('/api/sync/pull?cursor=0')
      .set('authorization', `Bearer ${tenant.users.cashier.token}`)
      .expect(200);

    await push([saleOp(tenant, { terminalSeq: 1, qty: 2 })]).expect(201);

    const after = await request(server())
      .get(`/api/sync/pull?cursor=${before.body.cursor}`)
      .set('authorization', `Bearer ${tenant.users.cashier.token}`)
      .expect(200);

    expect(after.body.cursor).toBeGreaterThan(before.body.cursor);
    // The terminal gets the corrected stock level back, so its local copy converges.
    expect(after.body.stockBatches.length).toBeGreaterThan(0);
  });
});
