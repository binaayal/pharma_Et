import request from 'supertest';
import { TestHarness, type SeededTenant } from '../harness';

/**
 * THE ONBOARDING GATE (ADR-022; prototype screens 01, 02, 22).
 *
 * Anyone may ask for an account. Nobody gets one without a person at the platform saying
 * yes. The assertions that matter: an anonymous submission creates a request and **no
 * tenant**; a tenant's own token cannot read or decide the queue; and approval opens an
 * account its owner can actually sign in to, in the same transaction that closes the request.
 */
describe('ADR-022 — sign-up requests', () => {
  let harness: TestHarness;
  let platform: string;
  let tenant: SeededTenant;
  const server = () => harness.app.getHttpServer();

  const ask = (phone = '+251 92 118 4477') =>
    request(server()).post('/api/signup-requests').send({
      pharmacyName: 'Adera Pharmacy',
      ownerName: 'Helen Bekele',
      phone,
      city: 'Addis Ababa',
      branchBand: '1',
    });

  const tenantCount = async () =>
    (await harness.platformDataSource.query(`SELECT count(*)::int AS n FROM tenant`))[0].n;

  beforeAll(async () => {
    harness = await TestHarness.start();
  });

  beforeEach(async () => {
    await harness.reset();
    tenant = await harness.seedTenant('abay', 1500);
    platform = await harness.seedPlatformAdmin();
  });

  afterAll(async () => harness?.stop());

  it('an anonymous request creates a request, and never a tenant', async () => {
    const before = await tenantCount();
    const response = await ask().expect(201);

    expect(response.body.status).toBe('pending');
    expect(await tenantCount()).toBe(before);
  });

  it('one open request per phone, however the number is written', async () => {
    await ask('+251 92 118 4477').expect(201);
    await ask('0921184477').expect(409);
  });

  it('a pharmacy token cannot read the queue or decide it', async () => {
    const { body } = await ask().expect(201);
    const owner = tenant.users.owner.token;

    await request(server())
      .get('/api/platform/signup-requests')
      .set('authorization', `Bearer ${owner}`)
      .expect(401);
    await request(server())
      .post(`/api/platform/signup-requests/${body.id}/decide`)
      .set('authorization', `Bearer ${owner}`)
      .send({ accept: false, reason: 'not a pharmacy' })
      .expect(401);
  });

  it('approval opens an account whose owner can sign in, and closes the request', async () => {
    const { body } = await ask().expect(201);

    const decided = await request(server())
      .post(`/api/platform/signup-requests/${body.id}/decide`)
      .set('authorization', `Bearer ${platform}`)
      .send({ accept: true, code: 'adera', ownerUsername: 'helen', ownerPin: '4821' })
      .expect(201);
    expect(decided.body.status).toBe('approved');

    await request(server())
      .post('/api/auth/login')
      .send({
        tenantCode: 'adera',
        username: 'helen',
        secret: '4821',
        terminalId: '01930000-0000-7000-8000-00000000d0aa',
      })
      .expect(200);

    const queue = await request(server())
      .get('/api/platform/signup-requests?status=pending')
      .set('authorization', `Bearer ${platform}`)
      .expect(200);
    expect(queue.body).toHaveLength(0);

    // Decided once. A second decision on the same request is refused, not re-applied.
    await request(server())
      .post(`/api/platform/signup-requests/${body.id}/decide`)
      .set('authorization', `Bearer ${platform}`)
      .send({ accept: false, reason: 'changed my mind' })
      .expect(400);
  });

  it('a taken pharmacy code refuses the approval and leaves the request open', async () => {
    const { body } = await ask().expect(201);
    await request(server())
      .post(`/api/platform/signup-requests/${body.id}/decide`)
      .set('authorization', `Bearer ${platform}`)
      .send({ accept: true, code: 'abay', ownerUsername: 'helen', ownerPin: '4821' })
      .expect(400);

    const [row] = await harness.platformDataSource.query(
      `SELECT status FROM signup_request WHERE id = $1`,
      [body.id],
    );
    expect(row.status).toBe('pending');
  });
});
