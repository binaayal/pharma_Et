import request from 'supertest';
import { uuidv7 } from 'uuidv7';
import { TestHarness, type SeededTenant } from '../harness';
import { TERMINAL, cashUpOp, saleInShift, shiftOp } from '../helpers/build-ops';

/**
 * AC-10.2 — every stored timestamp is UTC ISO-8601, whatever the display locale.
 *
 * FR-10 renders dates in the Ethiopian calendar and Amharic. BR-10.2 is emphatic that this
 * is presentation only: storage stays UTC, and no calendar logic reaches the domain or the
 * database.
 *
 * The failure this guards against is subtle and permanent. A localised date written into the
 * database is not merely inconvenient — it is **unrecoverable**, because nothing in the row
 * records which calendar it was written in. A controlled-substance ledger entry dated in the
 * Ethiopian calendar and read back as Gregorian is off by seven or eight years, and the
 * retention clock (NFR-5.1) is computed from exactly that field.
 */
describe('AC-10.2 — stored timestamps are UTC, always', () => {
  let harness: TestHarness;
  let tenant: SeededTenant;
  const server = () => harness.app.getHttpServer();

  beforeAll(async () => {
    harness = await TestHarness.start();
    await harness.reset();
    tenant = await harness.seedTenant('abay', 1500);

    const shiftId = uuidv7();
    await request(server())
      .post('/api/sync/push')
      .set('authorization', `Bearer ${tenant.users.cashier.token}`)
      .send({
        terminalId: TERMINAL,
        operations: [
          shiftOp(tenant, { terminalSeq: 1, shiftId, openingFloatSantim: 10000 }),
          saleInShift(tenant, { terminalSeq: 2, shiftId, qty: 1, unitPriceSantim: 1500 }),
          cashUpOp(tenant, {
            terminalSeq: 3,
            shiftId,
            expectedSantim: 11500,
            countedSantim: 11500,
          }),
        ],
      })
      .expect(201);
  });

  afterAll(async () => harness?.stop());

  it('stores every timestamp column as timestamptz', async () => {
    // `timestamp without time zone` would accept a local wall-clock reading and silently
    // lose the offset — the value would look identical and mean something else.
    const rows = await harness.platformDataSource.query(`
      SELECT c.table_name, c.column_name, c.data_type
        FROM information_schema.columns c
       WHERE c.table_schema = 'public'
         AND (c.column_name LIKE '%_at' OR c.column_name IN ('opened_at', 'closed_at'))
         AND c.data_type LIKE 'timestamp%'
    `);
    expect(rows.length).toBeGreaterThan(10);
    for (const row of rows) {
      expect(row.data_type).toBe('timestamp with time zone');
    }
  });

  it('round-trips an instant unchanged through push and read-back', async () => {
    const rows = await harness.platformDataSource.query(
      `SELECT sold_at AT TIME ZONE 'UTC' AS utc, sold_at FROM sale WHERE tenant_id = $1`,
      [tenant.id],
    );
    expect(rows).toHaveLength(1);
    // The client sent 2026-09-22T08:00:02Z; it must come back as that instant, not shifted
    // into any zone the server or the reader happens to sit in.
    expect(new Date(rows[0].sold_at).toISOString()).toMatch(/^2026-09-22T08:00:0\d\.000Z$/);
  });

  it('serves timestamps over the API as UTC ISO-8601 with a Z', async () => {
    // An offset-carrying string like +03:00 is still correct, but it invites a client to
    // render the date in a zone the reports do not group by — which makes a shift appear
    // to be missing from its own day.
    const report = await request(server())
      .get('/api/reports/cash-up')
      .set('authorization', `Bearer ${tenant.users.owner.token}`)
      .expect(200);

    const shift = report.body[0];
    for (const field of ['openedAt', 'countedAt'] as const) {
      expect(shift[field]).toMatch(/Z$/);
      expect(new Date(shift[field]).toISOString()).toBe(shift[field]);
    }
  });

  it('keeps expiry dates as plain ISO calendar dates, not localised strings', async () => {
    const stock = await request(server())
      .get('/api/reports/stock?expiringWithinDays=3650')
      .set('authorization', `Bearer ${tenant.users.owner.token}`)
      .expect(200);

    for (const row of stock.body.rows) {
      // Gregorian ISO. An Ethiopian-calendar date here would be off by seven or eight
      // years with nothing in the row to say so.
      expect(row.expiryDate).toMatch(/^\d{4}-\d{2}-\d{2}$/);
      expect(Number(row.expiryDate.slice(0, 4))).toBeGreaterThan(2000);
    }
  });

  it('has no calendar or locale column anywhere in the domain schema', async () => {
    // BR-10.2: conversion is presentation-only. A calendar column in the domain is how it
    // stops being presentation-only — the first query that filters on it has committed the
    // schema to a calendar forever.
    const rows = await harness.platformDataSource.query(`
      SELECT table_name, column_name
        FROM information_schema.columns
       WHERE table_schema = 'public'
         AND (column_name ILIKE '%ethiopian%'
              OR column_name ILIKE '%calendar%'
              OR column_name ILIKE '%locale%')
    `);
    expect(rows).toEqual([]);
  });
});
