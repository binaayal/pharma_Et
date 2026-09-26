import request from 'supertest';
import { TestHarness, TEST_PIN, TEST_TERMINAL, type SeededTenant } from '../harness';

/**
 * G1 — TELEMETRY LEAKS NOTHING (NFR-7, NFR-4.2).
 *
 * NFR-7 asks for structured logging and sync telemetry "surfaced to the platform team". The
 * moment that exists, logs stop being a developer's scratch output and become a place data
 * is kept, shipped and retained — often for longer than the records themselves, and usually
 * somewhere with fewer controls than the database.
 *
 * So the question is not whether the signals are useful. It is what they carry. A PIN in a log
 * is a PIN in every copy of that log, and no amount of RLS reaches it.
 *
 * The test captures what the process actually writes rather than inspecting the service's
 * inputs, because the leak that matters is the one that reaches the sink.
 */
describe('G1 — what the platform team is shown never includes a credential', () => {
  let harness: TestHarness;
  let tenant: SeededTenant;
  let written: string[];
  let restore: () => void;

  const server = () => harness.app.getHttpServer();

  beforeAll(async () => {
    harness = await TestHarness.start();
    await harness.reset();
    tenant = await harness.seedTenant('tele');
  });

  afterAll(async () => harness?.stop());

  beforeEach(() => {
    // Both sinks: structured mode writes to stdout directly, and development mode goes
    // through the Nest logger, which writes to stdout too. Capturing the file descriptor
    // catches whichever the build is using.
    written = [];
    const original = process.stdout.write.bind(process.stdout);
    process.stdout.write = ((chunk: string | Uint8Array, ...rest: unknown[]) => {
      written.push(chunk.toString());
      return (original as (...args: unknown[]) => boolean)(chunk, ...rest);
    }) as typeof process.stdout.write;
    restore = () => {
      process.stdout.write = original;
    };
  });

  afterEach(() => restore());

  const logged = () => written.join('');

  it('never writes a PIN, however the login turns out', async () => {
    await request(server())
      .post('/api/auth/login')
      .send({
        tenantCode: tenant.code,
        username: 'cashier',
        secret: TEST_PIN,
        terminalId: TEST_TERMINAL,
      })
      .expect(200);

    // A successful login is the dangerous one: a failure is often logged deliberately, and a
    // success is where a request-body logger gets added without anyone thinking about it.
    expect(logged()).not.toContain(TEST_PIN);
  });

  it('never writes a rejected PIN either', async () => {
    await request(server())
      .post('/api/auth/login')
      .send({
        tenantCode: tenant.code,
        username: 'cashier',
        secret: '4321',
        terminalId: TEST_TERMINAL,
      })
      .expect(401);

    // The throttle logs deliberately here (ADR-017), which is exactly why it is worth
    // asserting what that logging contains.
    expect(logged()).not.toContain('4321');
  });

  it('never writes a bearer token', async () => {
    await request(server())
      .get('/api/products')
      .set('authorization', `Bearer ${tenant.users.owner.token}`)
      .expect(200);

    // A token in a log is a live credential sitting in a retained file. It is also the single
    // easiest thing to leak, because `authorization` is just another header to a logger that
    // prints them all.
    const log = logged();
    expect(log).not.toContain(tenant.users.owner.token);
    expect(log).not.toContain('Bearer ');
  });

  it('records enough to act on: the route, the status and whose it was', async () => {
    await request(server())
      .get('/api/products')
      .set('authorization', `Bearer ${tenant.users.owner.token}`)
      .expect(200);

    // The other half of the same coin. A log stripped until it is safe and useless is not a
    // win — the runbook's §2 signals need the route to aggregate on and the tenant to act on.
    const log = logged();
    expect(log).toContain('/api/products');
    expect(log).toContain(tenant.id);
  });

  it('reports a failure as a failure, not as silence', async () => {
    await request(server()).get('/api/products').expect(401);

    // The obvious interceptor logs on success and lets errors propagate, which loses exactly
    // the requests worth alerting on. Error rate is one of the four signals §2 names.
    expect(logged()).toContain('401');
  });

  it('counts a push by outcome, including the rejections a 201 hides', async () => {
    const response = await request(server())
      .post('/api/sync/push')
      .set('authorization', `Bearer ${tenant.users.cashier.token}`)
      .send({
        terminalId: TEST_TERMINAL,
        operations: [
          {
            opId: '01930000-0000-7000-8000-0000000000c1',
            terminalId: TEST_TERMINAL,
            terminalSeq: 1,
            entityId: '01930000-0000-7000-8000-0000000000c2',
            entityType: 'sale',
            opType: 'create',
            baseVersion: null,
            // Another tenant's id: rejected per operation, inside a 201.
            tenantId: '01930000-0000-7000-8000-00000000dead',
            branchId: tenant.branchIds[0],
            actorId: tenant.users.cashier.id,
            clientTs: new Date().toISOString(),
            payload: {
              shiftId: null,
              cashierId: tenant.users.cashier.id,
              soldAt: new Date().toISOString(),
              totalSantim: 1500,
              lines: [
                {
                  id: '01930000-0000-7000-8000-0000000000c3',
                  productId: tenant.productId,
                  batchId: null,
                  qty: 1,
                  unitPriceSantim: 1500,
                  lineTotalSantim: 1500,
                },
              ],
              payments: [
                {
                  id: '01930000-0000-7000-8000-0000000000c4',
                  method: 'cash',
                  amountSantim: 1500,
                },
              ],
            },
          },
        ],
      })
      .expect(201);

    expect(response.body.acks[0].status).toBe('rejected');

    // The signal that makes this worth having. The transport returned 201 and the batch was
    // entirely refused; alerting on HTTP status would report a healthy server (ADR-005).
    const log = logged();
    expect(log).toContain('sync_push');
    expect(log).toMatch(/rejected[=":\s]+1/);
  });
});
