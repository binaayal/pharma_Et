import { JwtService } from '@nestjs/jwt';
import request from 'supertest';
import { uuidv7 } from 'uuidv7';
import { TestHarness } from '../harness';

/**
 * NFR-3.1 — 1,000 TENANTS, AT ONCE (docs/05-qa §9).
 *
 * The earlier suites proved every tenant predicate is index-backed and measured RLS under a
 * handful of tenants. This one puts the number the requirement names into the database and
 * then makes every one of them sync in the same instant: a push of a sale and a delta pull,
 * from 1,000 pharmacies, through the whole stack — JWT, tenant scope, RLS, the sync path.
 *
 * Correctness is asserted alongside the timing, because it is what 1,000 tenants actually
 * threatens: every sale applied exactly once, every pull returning only its own tenant's
 * rows. A fast answer that leaks a row between pharmacies is the worst outcome this system
 * can produce, and load is when a missed scope would show.
 *
 * Measured on the production-like container stack, as P1's NFR-3 figures were (docs/06 §2);
 * the network hop to a hosted region is staging's to add.
 */
const TENANTS = Number(process.env.NFR31_TENANTS ?? 1000);
/** The saturation burst: this many requests always in flight. Reported, not budgeted. */
const IN_FLIGHT = Number(process.env.NFR31_IN_FLIGHT ?? 100);
/**
 * The budgeted load. A busy pharmacy makes about one sale a minute, and each sale syncs at
 * once — a push, then a pull. A peak minute at 1,000 pharmacies is therefore ~1,000 of each
 * spread over 60 s; this compresses it into 30 s for 2× headroom (~67 requests/s). Idle
 * terminals add far less: with nothing queued they pull every two minutes.
 */
const PEAK_WINDOW_MS = Number(process.env.NFR31_WINDOW_MS ?? 30_000);

interface Seeded {
  tenantId: string;
  branchId: string;
  userId: string;
  productId: string;
  batchId: string;
  token: string;
}

describe('NFR-3.1 — 1,000 tenants', () => {
  let harness: TestHarness;
  const seeded: Seeded[] = [];
  const report: string[] = [];
  const server = () => harness.app.getHttpServer();

  const p = (samples: number[], q: number) => {
    const sorted = [...samples].sort((a, b) => a - b);
    return sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * q) - 1)];
  };

  /** Runs every task, IN_FLIGHT at a time, timing each. */
  async function burst(tasks: Array<() => Promise<void>>): Promise<number[]> {
    const timings: number[] = [];
    let next = 0;
    const worker = async () => {
      while (next < tasks.length) {
        const task = tasks[next++];
        const started = process.hrtime.bigint();
        await task();
        timings.push(Number(process.hrtime.bigint() - started) / 1e6);
      }
    };
    await Promise.all(Array.from({ length: IN_FLIGHT }, worker));
    return timings;
  }

  beforeAll(async () => {
    harness = await TestHarness.start();
    await harness.reset();
    const db = harness.platformDataSource;
    const jwt = harness.app.get(JwtService);

    // One statement per table, not 1,000 round trips: the seeding is not what is measured.
    const rows = Array.from({ length: TENANTS }, (_, i) => ({
      tenantId: uuidv7(),
      branchId: uuidv7(),
      userId: uuidv7(),
      productId: uuidv7(),
      batchId: uuidv7(),
      code: `load-${i}`,
    }));
    const col = (k: keyof (typeof rows)[number]) => rows.map((r) => r[k]);

    await db.query(
      `INSERT INTO tenant (id, name, code, status)
       SELECT id, 'Load pharmacy ' || code, code, 'active' FROM unnest($1::uuid[], $2::text[]) AS t(id, code)`,
      [col('tenantId'), col('code')],
    );
    await db.query(
      `INSERT INTO tenant_change_seq (tenant_id, value) SELECT unnest($1::uuid[]), 10`,
      [col('tenantId')],
    );
    await db.query(
      `INSERT INTO branch (id, tenant_id, name, change_seq)
       SELECT b, t, 'Main', 1 FROM unnest($1::uuid[], $2::uuid[]) AS x(b, t)`,
      [col('branchId'), col('tenantId')],
    );
    await db.query(
      `INSERT INTO app_user (id, tenant_id, username, display_name, role, pin_hash, change_seq)
       SELECT u, t, 'cashier', 'Load cashier', 'cashier', 'unused-for-this-test', 2
         FROM unnest($1::uuid[], $2::uuid[]) AS x(u, t)`,
      [col('userId'), col('tenantId')],
    );
    await db.query(
      `INSERT INTO user_branch (id, tenant_id, user_id, branch_id, change_seq)
       SELECT gen_random_uuid(), t, u, b, 3 FROM unnest($1::uuid[], $2::uuid[], $3::uuid[]) AS x(t, u, b)`,
      [col('tenantId'), col('userId'), col('branchId')],
    );
    await db.query(
      `INSERT INTO product (id, tenant_id, name, unit, is_controlled, current_price_santim, change_seq)
       SELECT p, t, 'Paracetamol 500mg', 'tablet', false, 150, 4 FROM unnest($1::uuid[], $2::uuid[]) AS x(p, t)`,
      [col('productId'), col('tenantId')],
    );
    await db.query(
      `INSERT INTO stock_batch (id, tenant_id, branch_id, product_id, lot_no, expiry_date, qty_on_hand, change_seq)
       SELECT s, t, b, p, 'LOT-1', '2028-01-31', 1000, 5
         FROM unnest($1::uuid[], $2::uuid[], $3::uuid[], $4::uuid[]) AS x(s, t, b, p)`,
      [col('batchId'), col('tenantId'), col('branchId'), col('productId')],
    );

    for (const r of rows) {
      const token = await jwt.signAsync({
        sub: r.userId,
        tid: r.tenantId,
        role: 'cashier',
        branches: [r.branchId],
        terminal: r.branchId,
        typ: 'access',
      });
      seeded.push({ ...r, token });
    }
  }, 600_000);

  afterAll(async () => {
    console.log(
      `\n  NFR-3.1 — ${TENANTS} tenants, ${IN_FLIGHT} in flight\n${report.map((r) => `    ${r}`).join('\n')}\n`,
    );
    await harness?.stop();
  });

  const terminal = '01930000-0000-7000-8000-0000000000f9';
  let terminalSeq = 0;
  const pushSale = (s: Seeded) =>
    request(server())
      .post('/api/sync/push')
      .set('authorization', `Bearer ${s.token}`)
      .send({
        terminalId: terminal,
        operations: [
          {
            opId: uuidv7(),
            terminalId: terminal,
            terminalSeq: ++terminalSeq,
            entityId: uuidv7(),
            opType: 'create',
            baseVersion: null,
            tenantId: s.tenantId,
            branchId: s.branchId,
            actorId: s.userId,
            clientTs: '2026-09-26T08:00:00.000Z',
            entityType: 'sale',
            payload: {
              shiftId: null,
              cashierId: s.userId,
              soldAt: '2026-09-26T08:00:00.000Z',
              totalSantim: 300,
              lines: [
                {
                  id: uuidv7(),
                  productId: s.productId,
                  batchId: s.batchId,
                  qty: 2,
                  unitPriceSantim: 150,
                  lineTotalSantim: 300,
                },
              ],
              payments: [{ id: uuidv7(), method: 'cash', amountSantim: 300 }],
            },
          },
        ],
      });

  const pull = (s: Seeded) =>
    request(server()).get('/api/sync/pull?cursor=0').set('authorization', `Bearer ${s.token}`);

  const ownRowsOnly = (
    s: Seeded,
    body: { products?: Array<{ id: string }>; stockBatches?: Array<{ id: string }> },
  ) =>
    (body.products ?? []).length === 1 &&
    body.products![0].id === s.productId &&
    (body.stockBatches ?? []).every((b) => b.id === s.batchId);

  it('a peak minute, 2× compressed: every pharmacy syncs a sale, p95 within budget (NFR-3.4)', async () => {
    const pushes: number[] = [];
    const pulls: number[] = [];
    const statuses: string[] = [];
    const leaks: string[] = [];
    const time = async <T>(into: number[], call: () => Promise<T>): Promise<T> => {
      const started = process.hrtime.bigint();
      const result = await call();
      into.push(Number(process.hrtime.bigint() - started) / 1e6);
      return result;
    };

    await Promise.all(
      seeded.map(
        (s, i) =>
          new Promise<void>((done, fail) => {
            setTimeout(
              async () => {
                try {
                  const pushed = await time(pushes, () => pushSale(s));
                  statuses.push(pushed.body.acks?.[0]?.status ?? `http ${pushed.status}`);
                  const pulled = await time(pulls, () => pull(s));
                  if (pulled.status !== 200 || !ownRowsOnly(s, pulled.body)) leaks.push(s.tenantId);
                  done();
                } catch (e) {
                  fail(e);
                }
              },
              (i * PEAK_WINDOW_MS) / seeded.length,
            );
          }),
      ),
    );

    report.push(
      `peak   push p50 ${p(pushes, 0.5).toFixed(0)} · p95 ${p(pushes, 0.95).toFixed(0)} · p99 ${p(pushes, 0.99).toFixed(0)} ms`,
    );
    report.push(
      `peak   pull p50 ${p(pulls, 0.5).toFixed(0)} · p95 ${p(pulls, 0.95).toFixed(0)} · p99 ${p(pulls, 0.99).toFixed(0)} ms`,
    );
    expect(statuses.filter((x) => x === 'applied')).toHaveLength(TENANTS);
    expect(leaks).toEqual([]);
    expect(p(pushes, 0.95)).toBeLessThan(500);
    expect(p(pulls, 0.95)).toBeLessThan(500);
  }, 600_000);

  it('saturation: 100 always in flight — correctness holds; latency is reported as capacity', async () => {
    const acks: string[] = [];
    const timings = await burst(
      seeded.map((s) => async () => {
        const response = await pushSale(s);
        acks.push(response.body.acks?.[0]?.status ?? `http ${response.status}`);
      }),
    );

    report.push(
      `burst  push p50 ${p(timings, 0.5).toFixed(0)} ms · p95 ${p(timings, 0.95).toFixed(0)} ms · p99 ${p(timings, 0.99).toFixed(0)} ms`,
    );
    expect(acks.filter((a) => a === 'applied')).toHaveLength(TENANTS);

    const [counts] = await harness.platformDataSource.query(
      `SELECT count(*)::int AS sales, count(DISTINCT tenant_id)::int AS tenants FROM sale`,
    );
    // Every tenant's sale from this burst and from the peak minute: exactly two each.
    expect(counts).toEqual({ sales: 2 * TENANTS, tenants: TENANTS });
  }, 600_000);

  it('saturation pull: every tenant at once still sees only its own rows', async () => {
    const leaks: string[] = [];
    const timings = await burst(
      seeded.map((s) => async () => {
        const response = await request(server())
          .get('/api/sync/pull?cursor=0')
          .set('authorization', `Bearer ${s.token}`);
        const products: Array<{ id: string }> = response.body.products ?? [];
        const batches: Array<{ id: string }> = response.body.stockBatches ?? [];
        if (
          response.status !== 200 ||
          products.length !== 1 ||
          products[0].id !== s.productId ||
          batches.some((b) => b.id !== s.batchId)
        ) {
          leaks.push(s.tenantId);
        }
      }),
    );

    report.push(
      `burst  pull p50 ${p(timings, 0.5).toFixed(0)} ms · p95 ${p(timings, 0.95).toFixed(0)} ms · p99 ${p(timings, 0.99).toFixed(0)} ms`,
    );
    expect(leaks).toEqual([]);
  }, 600_000);
});
