import { loginResponse, pullResponse, pushResponse } from '@pharmaet/contracts';
import request from 'supertest';
import { TestHarness, TEST_PIN, TEST_TERMINAL, type SeededTenant } from '../harness';
import { saleOp } from '../helpers/build-ops';

/**
 * G2 — CONTRACT CONFORMANCE, provider half (docs/05-qa §6).
 *
 * §6 says the sync envelope is "the one contract whose drift is catastrophic — divergent
 * client/server versions silently drop or duplicate real transactions", and asks for contract
 * tests that run **both halves** against the schema: "server responses **and** client requests
 * are validated".
 *
 * Only the request half existed. `ZodValidationPipe` parses every incoming body against the
 * contract at runtime; responses were merely *typed* as `Promise<LoginResponse>` and friends
 * — and TypeScript types are erased. A handler that returns the wrong shape at runtime
 * compiles, passes every other suite, and ships.
 *
 * That is not hypothetical here. This project has already shipped exactly that defect: raw
 * queries bypass the entity transformers, so money came back from Postgres as a **string**
 * where the contract says integer santim. Nothing at the API boundary objected. The Dart
 * client would have thrown on a device, in a pharmacy, at a counter.
 *
 * So these tests parse **real responses** with the **real schemas** — the same objects the
 * Dart types are generated from (ADR-010), so conformance here is conformance for the
 * client.
 *
 * Deliberately NOT asserted: that a response carries no undeclared fields. ADR-009 permits
 * additive change within a minor version, so a strict parse would fail the very evolution the
 * versioning policy allows. The drift that hurts is a field that is missing or wrong-typed,
 * and `.parse()` catches both.
 */
describe('G2 — the server answers in the shape the contract promises', () => {
  let harness: TestHarness;
  let tenant: SeededTenant;
  const server = () => harness.app.getHttpServer();

  beforeAll(async () => {
    harness = await TestHarness.start();
    await harness.reset();
    tenant = await harness.seedTenant('conf');
  });

  afterAll(async () => harness?.stop());

  it('login conforms to loginResponse', async () => {
    const response = await request(server())
      .post('/api/auth/login')
      .send({
        tenantCode: tenant.code,
        username: 'cashier',
        secret: TEST_PIN,
        terminalId: TEST_TERMINAL,
      })
      .expect(200);

    // Throws with the offending path if anything is missing or the wrong type.
    expect(() => loginResponse.parse(response.body)).not.toThrow();
  });

  it('pull conforms to pullResponse, with every reference type present', async () => {
    const response = await request(server())
      .get('/api/sync/pull?cursor=0')
      .set('authorization', `Bearer ${tenant.users.owner.token}`)
      .expect(200);

    const parsed = pullResponse.parse(response.body);

    // A conforming but empty response would satisfy the schema while exercising none of the
    // nested types, so the suite would pass without ever having looked at a product, a user
    // or a batch. Each collection must actually carry rows.
    expect(parsed.products.length).toBeGreaterThan(0);
    expect(parsed.branches.length).toBeGreaterThan(0);
    expect(parsed.users.length).toBeGreaterThan(0);
    expect(parsed.stockBatches.length).toBeGreaterThan(0);
  });

  it('push conforms to pushResponse across every ack status', async () => {
    const shared = { qty: 1, batchId: null };

    // applied
    const first = await request(server())
      .post('/api/sync/push')
      .set('authorization', `Bearer ${tenant.users.cashier.token}`)
      .send({
        terminalId: TEST_TERMINAL,
        operations: [saleOp(tenant, { terminalSeq: 5001, ...shared })],
      })
      .expect(201);
    expect(pushResponse.parse(first.body).acks[0].status).toBe('applied');

    // duplicate — the same op replayed, which is the shape a dropped connection produces
    const replayOp = saleOp(tenant, { terminalSeq: 5002, ...shared });
    await request(server())
      .post('/api/sync/push')
      .set('authorization', `Bearer ${tenant.users.cashier.token}`)
      .send({ terminalId: TEST_TERMINAL, operations: [replayOp] })
      .expect(201);
    const replay = await request(server())
      .post('/api/sync/push')
      .set('authorization', `Bearer ${tenant.users.cashier.token}`)
      .send({ terminalId: TEST_TERMINAL, operations: [replayOp] })
      .expect(201);
    expect(pushResponse.parse(replay.body).acks[0].status).toBe('duplicate');

    // rejected — an operation stamped with another tenant. The rejected ack carries a
    // `reason` the others do not, so it is a genuinely different shape to validate.
    const rejected = await request(server())
      .post('/api/sync/push')
      .set('authorization', `Bearer ${tenant.users.cashier.token}`)
      .send({
        terminalId: TEST_TERMINAL,
        operations: [
          {
            ...saleOp(tenant, { terminalSeq: 5003, ...shared }),
            tenantId: '01930000-0000-7000-8000-00000000dead',
          },
        ],
      })
      .expect(201);
    const parsed = pushResponse.parse(rejected.body);
    expect(parsed.acks[0].status).toBe('rejected');
    expect(parsed.acks[0].reason).toBeTruthy();
  });

  it('money crosses the wire as an integer, never a string', async () => {
    // The regression this suite exists for, asserted directly as well as through the schema —
    // because `santim` parsing a string would be a one-line schema change away from silently
    // allowing it, and the failure message should name the real problem.
    //
    // Raw queries bypass the entity transformers, and `pg` returns bigint as a string. A
    // price of "1500" formats as 1500 in a log and in most of a dashboard, and then divides
    // by 100 into nonsense at the one place it matters.
    const response = await request(server())
      .get('/api/sync/pull?cursor=0')
      .set('authorization', `Bearer ${tenant.users.owner.token}`)
      .expect(200);

    for (const product of response.body.products) {
      expect(typeof product.currentPriceSantim).toBe('number');
      expect(Number.isInteger(product.currentPriceSantim)).toBe(true);
    }
    for (const batch of response.body.stockBatches) {
      expect(typeof batch.qtyOnHand).toBe('number');
      expect(Number.isInteger(batch.qtyOnHand)).toBe(true);
    }
  });

  it('the contract version it reports is the one it was built from', async () => {
    // A server that serves a version it did not generate from is the drift §6 is about, and
    // it would be invisible: every field would still be right, and the client would negotiate
    // against a number that means nothing.
    const { CONTRACT_VERSION } = await import('@pharmaet/contracts');
    const pull = await request(server())
      .get('/api/sync/pull?cursor=0')
      .set('authorization', `Bearer ${tenant.users.owner.token}`)
      .expect(200);

    expect(pull.body.contractVersion).toBe(CONTRACT_VERSION);
  });
});
