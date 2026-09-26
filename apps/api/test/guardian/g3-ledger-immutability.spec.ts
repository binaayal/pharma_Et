import request from 'supertest';
import { uuidv7 } from 'uuidv7';
import { TestHarness, type SeededTenant } from '../harness';

/**
 * G3 — LEDGER IMMUTABILITY (docs/05-qa §4, ADR-004, ADR-015).
 *
 * The invariant: **no code path updates or physically deletes an event.** A correction is a
 * new, compensating event; a delete is a tombstone event. The current state of anything in
 * this log is a fold over its history, never a row somebody edited.
 *
 * Phase 2 builds the store and the general audit log; the controlled-substance event types
 * wait for A-1 (ADR-015). This suite therefore asserts the **mechanism**, which is what
 * `05-qa` §8 means by a provisional compliance test — everything here will still be true
 * when the regulated subset lands on top of it, and none of it asserts a regulatory fact.
 *
 * The tests run against the **platform (owner) connection** wherever they can, not the
 * application role. Proving that the app cannot mutate the log is the easy half; the half
 * that matters is that nobody can — including whoever is logged in at 2am during an incident
 * with the best of intentions.
 */
describe('G3 — ledger immutability', () => {
  let harness: TestHarness;
  let tenant: SeededTenant;
  const server = () => harness.app.getHttpServer();

  const owner = () => tenant.users.owner.token;

  beforeAll(async () => {
    harness = await TestHarness.start();
  });

  beforeEach(async () => {
    await harness.reset();
    tenant = await harness.seedTenant('abay', 1500);
  });

  afterAll(async () => harness?.stop());

  /** Produces a real audit event by doing something that should be audited. */
  const changePrice = (priceSantim: number) =>
    request(server())
      .post(`/api/products/${tenant.productId}/price`)
      .set('authorization', `Bearer ${owner()}`)
      .send({ priceSantim })
      .expect(201);

  const events = () =>
    harness.platformDataSource.query(`SELECT * FROM event WHERE tenant_id = $1 ORDER BY seq`, [
      tenant.id,
    ]);

  it('records the event as part of the transaction that caused it', async () => {
    await changePrice(1800);

    const rows = await events();
    expect(rows).toHaveLength(1);
    expect(rows[0].event_type).toBe('audit.price_changed');
    expect(rows[0].payload.previousPriceSantim).toBe(1500);
    expect(rows[0].payload.priceSantim).toBe(1800);
    expect(rows[0].actor_id).toBe(tenant.users.owner.id);
  });

  it('refuses an UPDATE, even on the owner connection', async () => {
    // The application role holds no UPDATE grant, so proving *it* cannot is proving very
    // little. The trigger is what stops the owner — the role that runs migrations and the
    // one a well-meaning fix gets run as.
    await changePrice(1800);

    await expect(
      harness.platformDataSource.query(
        `UPDATE event SET payload = '{"priceSantim": 1}'::jsonb WHERE tenant_id = $1`,
        [tenant.id],
      ),
    ).rejects.toThrow(/append-only/i);

    const rows = await events();
    expect(rows[0].payload.priceSantim).toBe(1800);
  });

  it('refuses a DELETE, even on the owner connection', async () => {
    await changePrice(1800);

    await expect(
      harness.platformDataSource.query(`DELETE FROM event WHERE tenant_id = $1`, [tenant.id]),
    ).rejects.toThrow(/append-only/i);

    expect(await events()).toHaveLength(1);
  });

  it('refuses a TRUNCATE — the one command that empties a table in a line', async () => {
    // TRUNCATE bypasses row-level triggers entirely, so it needs its own statement-level
    // guard. Without one, the fastest way to destroy an audit trail is the only way nothing
    // stops.
    await changePrice(1800);

    await expect(harness.platformDataSource.query(`TRUNCATE event`)).rejects.toThrow(
      /append-only/i,
    );

    expect(await events()).toHaveLength(1);
  });

  it('grants the application role INSERT and SELECT, and nothing else', async () => {
    // Defence in depth beneath the trigger: the app could not mutate the log even if the
    // trigger were dropped by a future migration that nobody read carefully.
    const grants = await harness.platformDataSource.query(
      `SELECT privilege_type FROM information_schema.role_table_grants
        WHERE table_name = 'event' AND grantee = current_setting('app.test_app_user', true)
           OR (table_name = 'event' AND grantee = 'pharmaet_app')
        ORDER BY privilege_type`,
    );
    const held = new Set(grants.map((g: { privilege_type: string }) => g.privilege_type));
    expect(held.has('INSERT')).toBe(true);
    expect(held.has('SELECT')).toBe(true);
    expect(held.has('UPDATE')).toBe(false);
    expect(held.has('DELETE')).toBe(false);
    expect(held.has('TRUNCATE')).toBe(false);
  });

  it('corrects by appending, because that is the only way to correct', async () => {
    // A price set wrongly and then set right is two events, both true, in order. The
    // "current" price is the fold; the mistake is still in the record, which is the entire
    // difference between a log and a value.
    await changePrice(9999);
    await changePrice(1500);

    const rows = await events();
    expect(rows).toHaveLength(2);
    expect(rows.map((r: { seq: string }) => Number(r.seq))).toEqual([1, 2]);
    expect(rows[0].payload.priceSantim).toBe(9999);
    expect(rows[1].payload.priceSantim).toBe(1500);
    expect(rows[1].payload.previousPriceSantim).toBe(9999);
  });

  it('numbers a stream from 1 with no gaps', async () => {
    // A gap cannot be distinguished from a deletion, and "nothing was removed" is the only
    // claim this log really makes.
    for (let i = 0; i < 5; i++) await changePrice(1500 + i * 10);

    const verify = await request(server())
      .get(`/api/audit/verify?streamId=${tenant.productId}`)
      .set('authorization', `Bearer ${owner()}`)
      .expect(200);

    expect(verify.body.intact).toBe(true);
    expect(verify.body.found).toBe(5);
    expect(verify.body.missing).toEqual([]);
  });

  it('cannot place two events at the same position in a stream', async () => {
    await changePrice(1800);

    await expect(
      harness.platformDataSource.query(
        `INSERT INTO event (id, tenant_id, stream, stream_id, seq, event_type, actor_id, occurred_at, recorded_at)
         VALUES ($1, $2, 'audit', $3, 1, 'audit.price_changed', $4, now(), now())`,
        [uuidv7(), tenant.id, tenant.productId, tenant.users.owner.id],
      ),
    ).rejects.toThrow(/unique|duplicate/i);
  });

  it('rejects an unknown stream rather than accepting a typo', async () => {
    // `stream` is what separates the audit trail from the future controlled ledger. A typo
    // creating a third, invisible stream would hide events from both.
    await expect(
      harness.platformDataSource.query(
        `INSERT INTO event (id, tenant_id, stream, stream_id, seq, event_type, actor_id, occurred_at, recorded_at)
         VALUES ($1, $2, 'audti', $3, 1, 'audit.price_changed', $4, now(), now())`,
        [uuidv7(), tenant.id, tenant.productId, tenant.users.owner.id],
      ),
    ).rejects.toThrow();
  });

  it("keeps one tenant's audit trail invisible to another (G1 holds here too)", async () => {
    const other = await harness.seedTenant('tana');
    await changePrice(1800);

    const theirs = await request(server())
      .get('/api/audit')
      .set('authorization', `Bearer ${other.users.owner.token}`)
      .expect(200);
    expect(theirs.body).toHaveLength(0);
  });

  it('is not readable by a role the matrix does not grant it to', async () => {
    await changePrice(1800);
    for (const token of [tenant.users.manager.token, tenant.users.cashier.token]) {
      await request(server()).get('/api/audit').set('authorization', `Bearer ${token}`).expect(403);
    }
  });

  it('writes nothing controlled while the regulated half is switched off (ADR-024)', async () => {
    // The fact that settles "is compliance live?". A-1 is unverified, so the switch is off,
    // and with it off the controlled_stock stream stays empty whatever a terminal sends.
    // The controlled half itself — rules, ledger, projection — is g5-controlled-ledger's.
    expect(process.env.CONTROLLED_DISPENSING).not.toBe('on');
    const controlled = await harness.platformDataSource.query(
      `SELECT count(*)::int AS n FROM event WHERE stream = 'controlled_stock' OR event_type LIKE 'controlled.%'`,
    );
    expect(controlled[0].n).toBe(0);

    // And the general audit log never borrows a controlled type.
    const { AUDIT_EVENT_TYPES } = await import('../../src/modules/audit/audit.service');
    expect(AUDIT_EVENT_TYPES.some((t) => t.startsWith('controlled.'))).toBe(false);
  });

  it('never records a credential, even a hashed one', async () => {
    // Reading an audit log must not be a way to compromise the accounts it mentions.
    await request(server())
      .post('/api/users')
      .set('authorization', `Bearer ${owner()}`)
      .send({
        username: `audit${Date.now()}`,
        displayName: 'Audited',
        role: 'cashier',
        pin: '4321',
        branchIds: [tenant.branchIds[0]],
      })
      .expect(201);

    const rows = await events();
    const serialised = JSON.stringify(rows);
    expect(serialised).not.toContain('4321');
    expect(serialised.toLowerCase()).not.toContain('pin_hash');
    expect(serialised).not.toMatch(/\$argon2/);
  });
});
