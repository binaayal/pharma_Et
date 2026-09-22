import request from 'supertest';
import { TestHarness, type SeededTenant } from '../harness';
import { TERMINAL, receiptOp, saleOp } from '../helpers/build-ops';

/**
 * G7 — OFFLINE RESILIENCE, server half (docs/05-qa §4, §17; NFR-1.3).
 *
 * The full invariant spans both sides: a locally committed sale survives app kill and device
 * reboot, and later syncs exactly once. The device half is proven in the Flutter suite,
 * where a real SQLite file survives a simulated restart; what the server must hold up is the
 * other end — a terminal that reappears after a long silence must be able to hand over
 * everything it accumulated, in one go, without loss.
 */
describe('G7 — offline resilience (server half)', () => {
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

  const push = (operations: unknown[]) =>
    request(server())
      .post('/api/sync/push')
      .set('authorization', `Bearer ${tenant.users.cashier.token}`)
      .send({ terminalId: TERMINAL, operations });

  it('accepts a full offline period of accumulated work in one reconnect', async () => {
    // Three days of a quiet counter: a morning receipt and a day's sales, every day, all
    // queued on the device because the network was down (NFR-1.1, 72h guaranteed window).
    const operations: unknown[] = [];
    let seq = 1;
    for (let day = 0; day < 3; day++) {
      operations.push(
        receiptOp(tenant, {
          terminalSeq: seq++,
          qty: 40,
          lotNo: `LOT-DAY-${day}`,
          expiryDate: '2027-12-31',
        }),
      );
      for (let sale = 0; sale < 20; sale++) {
        operations.push(saleOp(tenant, { terminalSeq: seq++, qty: 1, batchId: null }));
      }
    }

    const response = await push(operations).expect(201);

    expect(response.body.acks).toHaveLength(63);
    expect(response.body.acks.every((a: { status: string }) => a.status === 'applied')).toBe(true);

    const sales = await harness.platformDataSource.query(
      `SELECT count(*)::int AS n FROM sale WHERE tenant_id = $1`,
      [tenant.id],
    );
    expect(sales[0].n).toBe(60);
  });

  it('loses nothing when the connection drops mid-push and the terminal retries', async () => {
    // The device cannot distinguish "the server never got it" from "the ack never came
    // back", so on reconnect it re-sends everything unacknowledged. Both halves must land
    // exactly once between them.
    const all = Array.from({ length: 30 }, (_, i) =>
      saleOp(tenant, { terminalSeq: i + 1, batchId: null }),
    );

    // First attempt reaches the server; the response is lost in the network.
    await push(all.slice(0, 18)).expect(201);
    // The terminal retries from its last confirmed position — which it does not have, so it
    // re-sends the whole outbox.
    const retry = await push(all).expect(201);

    const statuses = retry.body.acks.map((a: { status: string }) => a.status);
    expect(statuses.slice(0, 18).every((s: string) => s === 'duplicate')).toBe(true);
    expect(statuses.slice(18).every((s: string) => s === 'applied')).toBe(true);

    const rows = await harness.platformDataSource.query(
      `SELECT count(*)::int AS n FROM sale WHERE tenant_id = $1`,
      [tenant.id],
    );
    expect(rows[0].n).toBe(30);
  });

  it('gives a reconnecting terminal the reference data it missed, in one pull', async () => {
    const response = await request(server())
      .get('/api/sync/pull?cursor=0')
      .set('authorization', `Bearer ${tenant.users.cashier.token}`)
      .expect(200);

    expect(response.body.products.length).toBeGreaterThan(0);
    expect(response.body.branches.length).toBeGreaterThan(0);
    expect(response.body.users.length).toBeGreaterThan(0);
    // Data currency, so the app can tell the user how stale its world is (BR-9.4).
    expect(response.body.serverTime).toBeTruthy();
    expect(response.body.hasMore).toBe(false);
  });

  it('keeps serving a terminal still speaking the previous contract version (ADR-009)', async () => {
    // An offline terminal reconnects days later on whatever contract it shipped with. The
    // server must accept every version in its support window, because refusing one means a
    // pharmacy's queued transactions have nowhere to go.
    const { SUPPORTED_CONTRACT_VERSIONS } = await import('@pharmaet/contracts');
    for (const version of SUPPORTED_CONTRACT_VERSIONS) {
      await request(server())
        .get('/api/sync/pull?cursor=0')
        .set('authorization', `Bearer ${tenant.users.cashier.token}`)
        .set('x-contract-version', version)
        .expect(200);
    }
  });

  it('refuses an unknown contract version loudly instead of misparsing it', async () => {
    await request(server())
      .get('/api/sync/pull?cursor=0')
      .set('authorization', `Bearer ${tenant.users.cashier.token}`)
      .set('x-contract-version', '99.0.0')
      .expect(400);
  });
});
