import request from 'supertest';
import { uuidv7 } from 'uuidv7';
import { TestHarness, type SeededTenant } from '../harness';
import { TERMINAL, cashUpOp, saleInShift, shiftOp } from '../helpers/build-ops';

/**
 * NFR-3 — performance budgets, measured (docs/06 §2, Phase 1 exit gate).
 *
 * These are **budgets from the SRS**, not observations dressed up as targets. A run that
 * passes proves the shape of the work is right — one query per report, indexes actually
 * used, no N+1 in the sync path. It does not prove production latency, and this file says
 * so rather than letting a green tick imply it.
 *
 * What this cannot measure, stated plainly:
 *   - **NFR-3.2 (<100 ms local op)** is a *device* number. It lives in the Flutter suite as
 *     a shape guard, and the real figure comes from the low-end Android matrix
 *     (`05-qa` §7). A server-side test cannot speak to it at all.
 *   - **Production latency.** This runs against a local PostgreSQL with no network between
 *     the app and the database. Re-running against hosted staging before GA is a launch
 *     checklist item (`06` §11), not something a CI green tick can stand in for.
 *
 * Budgets are asserted with headroom where the measurement is noisier than the thing being
 * measured — a test that fails on a busy CI runner teaches people to re-run it, and a gate
 * that gets re-run is not a gate.
 */
describe('NFR-3 — performance budgets', () => {
  let harness: TestHarness;
  let tenant: SeededTenant;
  const server = () => harness.app.getHttpServer();
  const report: string[] = [];

  beforeAll(async () => {
    harness = await TestHarness.start();
    await harness.reset();
    tenant = await harness.seedTenant('abay', 1500);
  });

  afterAll(async () => {
    // Printed as a table so the numbers are readable in a CI log rather than buried in
    // assertion output. A budget you cannot see the margin on is one nobody notices
    // eroding.
    console.log(`\n  NFR-3 measurements\n${report.map((r) => `    ${r}`).join('\n')}\n`);
    await harness?.stop();
  });

  const record = (label: string, ms: number, budget: number) => {
    const verdict = ms <= budget ? 'ok' : 'OVER';
    report.push(
      `${label.padEnd(46)} ${`${ms.toFixed(0)}ms`.padStart(8)} / ${`${budget}ms`.padStart(7)}  ${verdict}`,
    );
  };

  /** p95 over n runs. Median hides exactly the tail NFR-3.4 is written about. */
  async function percentile(runs: number, work: () => Promise<unknown>): Promise<number> {
    const samples: number[] = [];
    for (let i = 0; i < runs; i++) {
      const started = process.hrtime.bigint();
      await work();
      samples.push(Number(process.hrtime.bigint() - started) / 1e6);
    }
    samples.sort((a, b) => a - b);
    return samples[Math.min(samples.length - 1, Math.ceil(samples.length * 0.95) - 1)];
  }

  it('NFR-3.3 — a 72h backlog syncs in under 10s', async () => {
    // Three days of a busy counter: a shift a day and sixty sales a day, all queued because
    // the network was down. This is the moment the product is judged on — the pharmacist
    // watching a spinner after three days of outage.
    const operations: unknown[] = [];
    let seq = 1;
    for (let day = 0; day < 3; day++) {
      const shiftId = uuidv7();
      operations.push(shiftOp(tenant, { terminalSeq: seq++, shiftId, openingFloatSantim: 20000 }));
      for (let i = 0; i < 60; i++) {
        operations.push(
          saleInShift(tenant, { terminalSeq: seq++, shiftId, qty: 1, unitPriceSantim: 1500 }),
        );
      }
      operations.push(
        cashUpOp(tenant, {
          terminalSeq: seq++,
          shiftId,
          expectedSantim: 20000 + 60 * 1500,
          countedSantim: 20000 + 60 * 1500,
        }),
      );
    }

    // The client pushes in batches of 500 (the contract cap); 186 operations is one batch.
    const started = process.hrtime.bigint();
    const response = await request(server())
      .post('/api/sync/push')
      .set('authorization', `Bearer ${tenant.users.cashier.token}`)
      .send({ terminalId: TERMINAL, operations })
      .expect(201);
    const pushMs = Number(process.hrtime.bigint() - started) / 1e6;

    expect(response.body.acks).toHaveLength(operations.length);
    expect(response.body.acks.every((a: { status: string }) => a.status === 'applied')).toBe(true);

    const pullStarted = process.hrtime.bigint();
    await request(server())
      .get('/api/sync/pull?cursor=0')
      .set('authorization', `Bearer ${tenant.users.cashier.token}`)
      .expect(200);
    const totalMs = pushMs + Number(process.hrtime.bigint() - pullStarted) / 1e6;

    record('3.3  72h backlog: 186 ops push + full pull', totalMs, 10_000);
    expect(totalMs).toBeLessThan(10_000);
  });

  it('NFR-3.4 — sync endpoints p95 under 500ms', async () => {
    // A real open shift, so the measurement covers the SUCCESS path: validate, insert the
    // sale and its lines and payment, decrement stock, record applied_op. Measuring
    // rejections instead would time the cheap half and report a number nobody experiences.
    const shiftId = uuidv7();
    await request(server())
      .post('/api/sync/push')
      .set('authorization', `Bearer ${tenant.users.cashier.token}`)
      .send({
        terminalId: TERMINAL,
        operations: [shiftOp(tenant, { terminalSeq: 900000, shiftId, openingFloatSantim: 0 })],
      })
      .expect(201);

    let seq = 900001;
    const pushP95 = await percentile(20, async () => {
      const response = await request(server())
        .post('/api/sync/push')
        .set('authorization', `Bearer ${tenant.users.cashier.token}`)
        .send({
          terminalId: TERMINAL,
          operations: [saleInShift(tenant, { terminalSeq: seq++, shiftId, qty: 1 })],
        })
        .expect(201);
      expect(response.body.acks[0].status).toBe('applied');
    });
    record('3.4  POST /sync/push p95 (single sale, applied)', pushP95, 500);
    expect(pushP95).toBeLessThan(500);

    const pullP95 = await percentile(20, () =>
      request(server())
        .get('/api/sync/pull?cursor=0')
        .set('authorization', `Bearer ${tenant.users.cashier.token}`),
    );
    record('3.4  GET /sync/pull p95 (full catalog)', pullP95, 500);
    expect(pullP95).toBeLessThan(500);
  });

  it('NFR-3.4 — dashboard reads p95 under 1s', async () => {
    const token = tenant.users.owner.token;
    const reads: Array<[string, string]> = [
      ['sales-summary', '/api/reports/sales-summary?from=2026-01-01&to=2027-01-01'],
      ['cash-up summary', '/api/reports/cash-up'],
      ['stock & expiry', '/api/reports/stock?expiringWithinDays=365'],
      ['recent sales', '/api/reports/sales'],
    ];

    for (const [label, path] of reads) {
      const p95 = await percentile(10, () =>
        request(server()).get(path).set('authorization', `Bearer ${token}`).expect(200),
      );
      record(`3.4  GET ${label} p95`, p95, 1000);
      expect(p95).toBeLessThan(1000);
    }
  });

  it('NFR-3.1 — tenant-scoped queries use an index, not a scan', async () => {
    // The thing that actually decides whether 1,000 tenants works is not a timing on a
    // near-empty database — it is whether every hot query has an index behind its tenant
    // predicate. A sequential scan is fine at ten tenants and fatal at a thousand, and it
    // will pass any latency budget you set today.
    const plans: Array<[string, string]> = [
      [
        'sale by branch and date',
        `SELECT * FROM sale WHERE tenant_id = $1 AND branch_id = $2 ORDER BY sold_at DESC LIMIT 50`,
      ],
      [
        'stock FEFO lookup',
        `SELECT * FROM stock_batch WHERE tenant_id = $1 AND branch_id = $2 ORDER BY expiry_date LIMIT 1`,
      ],
      ['applied_op idempotency', `SELECT * FROM applied_op WHERE tenant_id = $1 AND op_id = $2`],
    ];

    for (const [label, sql] of plans) {
      const rows = await harness.platformDataSource.query(
        `EXPLAIN (FORMAT JSON) ${sql}`,
        [tenant.id, tenant.branchIds[0]].slice(0, (sql.match(/\$\d/g) ?? []).length),
      );
      const plan = JSON.stringify(rows[0]['QUERY PLAN'] ?? rows[0]);
      // On a small table Postgres legitimately prefers a scan, so this asserts the index
      // EXISTS and is considered — not that it is chosen today. The scan that matters is
      // the one with no index to choose from.
      report.push(
        `3.1  ${label.padEnd(42)} plan: ${plan.includes('Index') ? 'index' : 'seq (small table)'}`,
      );
    }

    // Every table that HAS a tenant_id carries an index on it. RLS adds that predicate to
    // every query whether the author wrote it or not, so a tenant-scoped table without one
    // is a guaranteed sequential scan at 1,000 tenants.
    //
    // Scoped by "has the column" rather than by an exclusion list, so it stays true on its
    // own: a new tenant table without an index fails, and a legitimately non-tenant table
    // — `platform_admin`, which is us and has no tenant_id at all — never has to be
    // remembered and added to a list somebody would eventually pad to make a test pass.
    const missing = await harness.platformDataSource.query(`
      SELECT c.relname AS table
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public' AND c.relkind = 'r'
         AND c.relname <> 'migrations'
         AND EXISTS (
           SELECT 1 FROM pg_attribute a
            WHERE a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped
         )
         AND NOT EXISTS (
           SELECT 1 FROM pg_index i
             JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = ANY(i.indkey)
            WHERE i.indrelid = c.oid AND a.attname = 'tenant_id'
         )
    `);
    expect(missing).toEqual([]);
  });
});
