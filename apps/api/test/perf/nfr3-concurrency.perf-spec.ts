import request from 'supertest';
import { uuidv7 } from 'uuidv7';
import { TestHarness, type SeededTenant } from '../harness';
import { saleOp } from '../helpers/build-ops';

/**
 * NFR-3 UNDER CONCURRENCY, and the cost of RLS (docs/05-qa §9).
 *
 * §9 asks for the p95 budgets to be met by a **load test at target concurrency** and for
 * **RLS overhead** to be measured. The existing perf suite does neither: it issues one
 * request at a time, which measures latency with nothing to contend against. A p95 taken
 * with no contention says nothing about the failure this system can actually have.
 *
 * **What "target concurrency" means here is set by ADR-002, not invented.** FR-9 is the
 * single-writer tier — one terminal per branch, no concurrent writers within a branch — and
 * multi-writer is explicitly V2. So the concurrency that exists in V1 is:
 *
 *   1. **Many tenants at once.** 1,000 pharmacies is NFR-3.1. They share a connection pool
 *      and nothing else, because the change sequence is per tenant.
 *   2. **Branches within one tenant at once.** A three-branch pharmacy has three terminals,
 *      and every sync write they make takes the same `tenant_change_seq` row lock. That is
 *      deliberate — it is what guarantees no two rows in a tenant share a sequence number —
 *      but it is a serialisation point nobody has measured, and it is the one place in this
 *      design where added branches cost latency rather than nothing.
 *
 * Correctness under contention is asserted alongside the timing, because it is the thing
 * that actually matters: a duplicated or skipped change sequence means a delta pull that
 * repeats rows or silently loses them, and a skipped price change is a terminal selling at
 * yesterday's price for days.
 */
describe('NFR-3 — under concurrency, and the cost of RLS', () => {
  let harness: TestHarness;
  const server = () => harness.app.getHttpServer();
  const report: string[] = [];

  beforeAll(async () => {
    harness = await TestHarness.start();
    await harness.reset();
  });

  afterAll(async () => {
    console.log(`\n  NFR-3 concurrency\n${report.map((r) => `    ${r}`).join('\n')}\n`);
    await harness?.stop();
  });

  const record = (label: string, value: string) =>
    report.push(`${label.padEnd(50)} ${value}`);

  /** p95 of a set of already-collected durations. */
  const p95 = (samples: number[]): number => {
    const sorted = [...samples].sort((a, b) => a - b);
    return sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * 0.95) - 1)];
  };

  /** Fires every task at once and times each individually. */
  async function inParallel<T>(tasks: Array<() => Promise<T>>): Promise<number[]> {
    const timings = await Promise.all(
      tasks.map(async (task) => {
        const started = process.hrtime.bigint();
        await task();
        return Number(process.hrtime.bigint() - started) / 1e6;
      }),
    );
    return timings;
  }

  it('holds the sync budget with many pharmacies pushing at the same moment', async () => {
    // Eight tenants is not 1,000, and this does not claim to be a 1,000-tenant load test —
    // that needs a load generator and hosted infrastructure (docs/06 §11). What it does
    // prove is the shape: independent tenants contend only for the connection pool, so
    // latency should stay near the single-request figure rather than degrading with count.
    const tenants: SeededTenant[] = [];
    for (let i = 0; i < 8; i++) {
      tenants.push(await harness.seedTenant(`conc${i}`));
    }

    const timings = await inParallel(
      tenants.map((tenant, index) => async () => {
        const response = await request(server())
          .post('/api/sync/push')
          .set('authorization', `Bearer ${tenant.users.cashier.token}`)
          .send({
            terminalId: '01930000-0000-7000-8000-0000000000e1',
            operations: [saleOp(tenant, { terminalSeq: 1000 + index, batchId: null })],
          });
        expect(response.status).toBe(201);
        expect(response.body.acks[0].status).toBe('applied');
      }),
    );

    const worst = p95(timings);
    record('8 tenants pushing concurrently, p95', `${worst.toFixed(0)}ms / 500ms`);
    expect(worst).toBeLessThan(500);
  });

  it('serialises branches of one pharmacy without losing or repeating a sequence', async () => {
    const tenant = await harness.seedTenant('multi');

    // **Two** concurrent writers, not twelve, and that is the point rather than a shortcut.
    // ADR-002 puts V1 on the single-writer tier: one terminal per branch. Twelve terminals
    // hammering one branch is a V2 scenario, and a test that invented it would be measuring
    // a product we deliberately did not build.
    //
    // What IS real is a two-branch pharmacy: each branch a single writer, both hitting the
    // same `tenant_change_seq` row on every write. That row is the only thing they share.
    const perBranch = 6;

    // Branch 2 needs stock of its own, so its sales actually decrement a batch and therefore
    // actually allocate a sequence. Without it this branch would contend for nothing.
    const branchTwoBatch = uuidv7();
    await harness.platformDataSource.query(
      `INSERT INTO stock_batch (id, tenant_id, branch_id, product_id, lot_no, expiry_date, qty_on_hand, change_seq)
       VALUES ($1, $2, $3, $4, 'LOT-B2', '2028-01-31', 100, 0)`,
      [branchTwoBatch, tenant.id, tenant.branchIds[1], tenant.productId],
    );

    /** One branch's terminal: sequential, because a terminal is a single writer. */
    const branchStream = (branchIndex: number, batchId: string) => async () => {
      const timings: number[] = [];
      const terminalId = `01930000-0000-7000-8000-00000000e${branchIndex}01`;
      for (let i = 0; i < perBranch; i++) {
        const started = process.hrtime.bigint();
        const response = await request(server())
          .post('/api/sync/push')
          .set('authorization', `Bearer ${tenant.users.owner.token}`)
          .send({
            terminalId,
            operations: [
              saleOp(tenant, {
                terminalSeq: 2000 + branchIndex * 100 + i,
                batchId,
                branchId: tenant.branchIds[branchIndex],
                terminalId,
              }),
            ],
          });
        expect(response.status).toBe(201);
        expect(response.body.acks[0].status).toBe('applied');
        timings.push(Number(process.hrtime.bigint() - started) / 1e6);
      }
      return timings;
    };

    const [branchOne, branchTwo] = await Promise.all([
      branchStream(0, tenant.batchIds[0])(),
      branchStream(1, branchTwoBatch)(),
    ]);
    const worst = p95([...branchOne, ...branchTwo]);
    record(
      `2 branches x ${perBranch} pushes, concurrent, p95`,
      `${worst.toFixed(0)}ms / 500ms`,
    );

    // The timing is the lesser half. THIS is the assertion that matters, and it is the
    // invariant ChangeSeqService claims in its own doc comment: no two rows in a tenant
    // share a sequence value. A repeat would make a delta pull send the same row twice; a
    // gap at a page boundary would make it skip one, and a skipped price change is a
    // terminal selling yesterday's price for days.
    //
    // Asserted on `stock_batch` because that is what a sale actually re-sequences. A sale
    // row carries change_seq 0 on purpose — pull serves reference data only, and under
    // single-writer a terminal authored its own sales and never needs them back.
    const rows = await harness.platformDataSource.query(
      `SELECT change_seq FROM stock_batch WHERE tenant_id = $1 AND change_seq > 0
        ORDER BY change_seq`,
      [tenant.id],
    );
    const seqs = rows.map((r: { change_seq: string }) => Number(r.change_seq));

    expect(seqs.length).toBeGreaterThan(0);
    expect(new Set(seqs).size).toBe(seqs.length);

    // And no allocation was lost: the counter is at least as high as the highest it handed
    // out. Lower would mean two writers read the same value and one overwrote the other.
    const [{ value }] = await harness.platformDataSource.query(
      `SELECT value FROM tenant_change_seq WHERE tenant_id = $1`,
      [tenant.id],
    );
    expect(Number(value)).toBeGreaterThanOrEqual(seqs[seqs.length - 1]);

    expect(worst).toBeLessThan(500);
  });

  it('measures what row-level security costs on the read path', async () => {
    const tenant = await harness.seedTenant('rlscost');

    // The same query, twice: once on the application's connection, where RLS adds its
    // tenant predicate to every table; once on the owner connection, which Postgres exempts
    // from RLS entirely. The difference is the tax ADR-003 chose to pay.
    //
    // docs/05 §9 asks for this to be **measured**, not to clear a threshold — so the number
    // is recorded and the assertion is only a sanity bound. A tight gate on a figure this
    // noisy would fail on a busy runner and teach people to re-run it.
    const runs = 40;
    const sql = `SELECT count(*) FROM sale WHERE tenant_id = $1`;

    const time = async (run: () => Promise<unknown>): Promise<number> => {
      for (let i = 0; i < 5; i++) await run(); // warm the plan cache
      const samples: number[] = [];
      for (let i = 0; i < runs; i++) {
        const started = process.hrtime.bigint();
        await run();
        samples.push(Number(process.hrtime.bigint() - started) / 1e6);
      }
      return p95(samples);
    };

    const withRls = await time(() =>
      harness.appDataSource.transaction(async (em) => {
        await em.query(`SET LOCAL app.current_tenant = '${tenant.id}'`);
        return em.query(sql, [tenant.id]);
      }),
    );
    const withoutRls = await time(() => harness.platformDataSource.query(sql, [tenant.id]));

    const overhead = withRls - withoutRls;
    record(
      'RLS overhead on a scoped count, p95',
      `${withRls.toFixed(2)}ms vs ${withoutRls.toFixed(2)}ms  (+${overhead.toFixed(2)}ms)`,
    );

    // Sanity only: RLS appends an indexed predicate that the query already carries, so it
    // should be small. If this ever fails it means the policy stopped being index-backed,
    // which at 1,000 tenants is the difference between a lookup and a table scan.
    expect(withRls).toBeLessThan(50);
  });
});
