import request from 'supertest';
import { ConfigService } from '@nestjs/config';
import { TestHarness, type SeededTenant } from '../harness';
import { TERMINAL, saleOp } from '../helpers/build-ops';
import { shopDay, summaryText } from '../../src/modules/notifications/summary-text';
import { TelegramClient } from '../../src/modules/notifications/telegram.client';
import { TelegramService } from '../../src/modules/notifications/telegram.service';

// Before the application is built: configuration is read once, at start.
process.env.TELEGRAM_BOT_TOKEN = '1234567890:test-token-not-a-real-one-AAAAAAAA';
process.env.TELEGRAM_BOT_USERNAME = 'pharmaet_test_bot';
process.env.SUMMARY_DISPATCH_SECRET = 'dispatch-secret-for-tests-only-000';

/**
 * G1 — THE DAILY SUMMARY ON TELEGRAM (FR-17, ADR-039).
 *
 * This is the first thing in the system that sends a pharmacy's figures somewhere without
 * that pharmacy asking at that moment, and it is reached by two callers who are not signed
 * in at all. So what is held here is mostly about who:
 *
 *   - **a summary goes only to a chat its owner linked themselves**, by a code that works
 *     once, for fifteen minutes, and that nobody else can mint;
 *   - **one pharmacy's summary never reaches another's chat**, and holds none of its rows;
 *   - **the two unauthenticated doors are shut without their secret**, and say nothing;
 *   - **a day is sent once**, however often the schedule fires;
 *   - the figures are the ones the phone shows (BR-17.1).
 */
describe('G1 — daily summary on Telegram', () => {
  let harness: TestHarness;
  let a: SeededTenant;
  let b: SeededTenant;
  let client: TelegramClient;
  let service: TelegramService;
  /** Everything "sent to Telegram", in order. */
  let sent: Array<{ chat: string; text: string }>;
  /** What Telegram answers the next sendMessage with. */
  let answer: { ok: boolean; errorCode?: number };

  const server = () => harness.app.getHttpServer();
  // 20:30 in Addis Ababa on the day the fixtures' sales are dated.
  const closing = new Date('2026-09-22T17:30:00Z');

  beforeAll(async () => {
    harness = await TestHarness.start();
    client = harness.app.get(TelegramClient);
    service = harness.app.get(TelegramService);
  });

  beforeEach(async () => {
    await harness.reset();
    a = await harness.seedTenant('abay');
    b = await harness.seedTenant('blue');
    sent = [];
    answer = { ok: true };
    client.transport = async (method, body) => {
      if (method !== 'sendMessage') return { ok: true };
      sent.push({ chat: String(body.chat_id), text: String(body.text) });
      return answer;
    };
  });

  afterAll(async () => harness?.stop());

  const as = (tenant: SeededTenant, who: 'owner' | 'manager' | 'cashier' = 'owner') => ({
    get: (path: string) =>
      request(server()).get(path).set('authorization', `Bearer ${tenant.users[who].token}`),
    post: (path: string, body: object = {}) =>
      request(server())
        .post(path)
        .set('authorization', `Bearer ${tenant.users[who].token}`)
        .send(body),
    delete: (path: string) =>
      request(server()).delete(path).set('authorization', `Bearer ${tenant.users[who].token}`),
  });

  const hook = (text: string, chat: number, secret: string | null = client.webhookSecret!) => {
    const call = request(server()).post('/api/telegram/webhook');
    if (secret !== null) call.set('x-telegram-bot-api-secret-token', secret);
    return call.send({ update_id: 1, message: { chat: { id: chat }, text } });
  };

  /** Asks for a link as [tenant]'s owner and returns the one-time code in it. */
  const codeFor = async (tenant: SeededTenant, locale = 'en'): Promise<string> => {
    const response = await as(tenant).post('/api/notifications/telegram/link', { locale });
    expect(response.status).toBe(201);
    return new URL(response.body.url).searchParams.get('start')!;
  };

  const link = async (tenant: SeededTenant, chat: number, locale = 'en') => {
    await hook(`/start ${await codeFor(tenant, locale)}`, chat).expect(200);
    sent = [];
  };

  const query = (sql: string, params: unknown[] = []) =>
    harness.platformDataSource.query(sql, params);

  describe('linking a chat', () => {
    it('gives the owner a link into the bot, carrying a code and nothing else', async () => {
      const response = await as(a).post('/api/notifications/telegram/link').expect(201);
      const url = new URL(response.body.url);

      expect(url.origin + url.pathname).toBe('https://t.me/pharmaet_test_bot');
      expect(url.searchParams.get('start')).toMatch(/^[A-Za-z0-9_-]{32}$/);
      expect(new Date(response.body.expiresAt).getTime()).toBeGreaterThan(Date.now());
      // No tenant id, no user id, no token: the code is opaque.
      expect(response.body.url).not.toContain(a.id);
      expect(JSON.stringify(response.body)).not.toContain(process.env.TELEGRAM_BOT_TOKEN!);
    });

    it('stores the code only as a hash', async () => {
      const code = await codeFor(a);
      const [row] = await query(`SELECT code_hash, chat_id FROM telegram_link`);
      expect(row.code_hash).toMatch(/^[0-9a-f]{64}$/);
      expect(row.code_hash).not.toContain(code);
      expect(row.chat_id).toBeNull();
    });

    it('is the owner’s to set up: a manager and a cashier are refused', async () => {
      for (const who of ['manager', 'cashier'] as const) {
        await as(a, who).post('/api/notifications/telegram/link').expect(403);
        await as(a, who).get('/api/notifications/telegram').expect(403);
        await as(a, who).post('/api/notifications/telegram/test').expect(403);
      }
      expect(await query(`SELECT 1 FROM telegram_link`)).toHaveLength(0);
    });

    it('pressing Start with the code links that chat, and says which pharmacy', async () => {
      await hook(`/start ${await codeFor(a)}`, 111).expect(200);

      expect(sent).toHaveLength(1);
      expect(sent[0]).toMatchObject({ chat: '111' });
      expect(sent[0]!.text).toContain('abay Pharmacy');
      const status = (await as(a).get('/api/notifications/telegram').expect(200)).body;
      expect(status).toMatchObject({ available: true, linked: true });
    });

    it('answers in the language the owner was using', async () => {
      await hook(`/start ${await codeFor(a, 'am')}`, 111).expect(200);
      expect(sent[0]!.text).toContain('ተገናኝቷል');
    });

    it('a code works once', async () => {
      const code = await codeFor(a);
      await hook(`/start ${code}`, 111).expect(200);
      await hook(`/start ${code}`, 999).expect(200);

      const [row] = await query(`SELECT chat_id FROM telegram_link`);
      // The second chat got an apology, not the pharmacy.
      expect(String(row.chat_id)).toBe('111');
      expect(sent[1]!.chat).toBe('999');
      expect(sent[1]!.text).toContain('expired or was already used');
    });

    it('a code stops working after fifteen minutes', async () => {
      const code = await codeFor(a);
      await query(`UPDATE telegram_link SET code_expires_at = now() - interval '1 second'`);
      await hook(`/start ${code}`, 111).expect(200);

      expect((await query(`SELECT chat_id FROM telegram_link`))[0].chat_id).toBeNull();
      expect(sent[0]!.text).toContain('expired or was already used');
    });

    it('a guessed code links nothing', async () => {
      await codeFor(a);
      await hook(`/start ${'A'.repeat(32)}`, 666).expect(200);
      expect((await query(`SELECT chat_id FROM telegram_link`))[0].chat_id).toBeNull();
    });

    it('asking again replaces the code and keeps the chat until the new one is used', async () => {
      await link(a, 111);
      const first = await codeFor(a);
      const second = await codeFor(a);

      expect(await query(`SELECT 1 FROM telegram_link`)).toHaveLength(1);
      expect(String((await query(`SELECT chat_id FROM telegram_link`))[0].chat_id)).toBe('111');
      await hook(`/start ${first}`, 222).expect(200);
      expect(String((await query(`SELECT chat_id FROM telegram_link`))[0].chat_id)).toBe('111');
      await hook(`/start ${second}`, 222).expect(200);
      expect(String((await query(`SELECT chat_id FROM telegram_link`))[0].chat_id)).toBe('222');
    });

    it('anything else typed to the bot gets directions, and links nothing', async () => {
      await hook('hello', 111).expect(200);
      await hook('/start', 111).expect(200);
      expect(sent.every((m) => m.text.includes('Daily summary on Telegram'))).toBe(true);
      expect(await query(`SELECT 1 FROM telegram_link`)).toHaveLength(0);
    });

    it('survives an update with nothing in it', async () => {
      await request(server())
        .post('/api/telegram/webhook')
        .set('x-telegram-bot-api-secret-token', client.webhookSecret!)
        .send({ update_id: 2 })
        .expect(200);
      expect(sent).toHaveLength(0);
    });
  });

  describe('turning it off', () => {
    it('from the app', async () => {
      await link(a, 111);
      await as(a).delete('/api/notifications/telegram/link').expect(200);

      expect((await as(a).get('/api/notifications/telegram')).body.linked).toBe(false);
      expect(await service.dispatch(closing)).toMatchObject({ sent: 0 });
      expect(sent).toHaveLength(0);
    });

    it('from Telegram, with /stop', async () => {
      await link(a, 111);
      await hook('/stop', 111).expect(200);

      expect(sent[0]!.text).toContain('Stopped');
      expect((await as(a).get('/api/notifications/telegram')).body.linked).toBe(false);
    });

    it('/stop from one chat does not unlink another pharmacy', async () => {
      await link(a, 111);
      await link(b, 222);
      await hook('/stop', 111).expect(200);
      expect((await as(b).get('/api/notifications/telegram')).body.linked).toBe(true);
    });

    it('stops by itself when the person has blocked the bot', async () => {
      await link(a, 111);
      answer = { ok: false, errorCode: 403 };
      expect(await service.dispatch(closing)).toMatchObject({ sent: 0, failed: 1 });
      expect((await as(a).get('/api/notifications/telegram')).body.linked).toBe(false);
    });
  });

  describe('the two doors with no session', () => {
    it('the webhook is not there without Telegram’s secret', async () => {
      const code = await codeFor(a);
      await hook(`/start ${code}`, 111, null).expect(404);
      await hook(`/start ${code}`, 111, 'wrong').expect(404);
      await hook(`/start ${code}`, 111, `${client.webhookSecret}x`).expect(404);

      expect((await query(`SELECT chat_id FROM telegram_link`))[0].chat_id).toBeNull();
      expect(sent).toHaveLength(0);
    });

    it('the dispatch is not there without its secret', async () => {
      await link(a, 111);
      await request(server()).post('/api/internal/summary-dispatch').expect(404);
      await request(server())
        .post('/api/internal/summary-dispatch')
        .set('x-dispatch-secret', 'wrong')
        .expect(404);
      // A signed-in owner is not the schedule either.
      await as(a).post('/api/internal/summary-dispatch').expect(404);
      expect(sent).toHaveLength(0);
    });

    it('with its secret, the dispatch sends and reports what it did', async () => {
      await link(a, 111);
      const response = await request(server())
        .post('/api/internal/summary-dispatch')
        .set('x-dispatch-secret', process.env.SUMMARY_DISPATCH_SECRET!)
        .expect(200);

      expect(response.body).toEqual({ sent: 1, skipped: 0, failed: 0 });
      expect(sent).toHaveLength(1);
      // Counts only: the response goes to a CI log.
      expect(JSON.stringify(response.body)).not.toContain('abay');
    });

    it('neither secret is the bot token, and no endpoint returns the token', async () => {
      expect(client.webhookSecret).not.toContain(process.env.TELEGRAM_BOT_TOKEN!);
      const status = await as(a).get('/api/notifications/telegram').expect(200);
      expect(JSON.stringify(status.body)).not.toContain('test-token');
    });
  });

  describe('the nightly dispatch', () => {
    const push = (tenant: SeededTenant, operations: unknown[]) =>
      request(server())
        .post('/api/sync/push')
        .set('authorization', `Bearer ${tenant.users.cashier.token}`)
        .send({ terminalId: TERMINAL, operations })
        .expect(201);

    it('sends each pharmacy its own day, to its own chat, and nobody else’s', async () => {
      await link(a, 111);
      await link(b, 222);
      // Abay sells three at 15.00; Blue sells nothing.
      await push(a, [saleOp(a, { terminalSeq: 1, qty: 3 })]);

      expect(await service.dispatch(closing)).toEqual({ sent: 2, skipped: 0, failed: 0 });

      const toA = sent.find((m) => m.chat === '111')!.text;
      const toB = sent.find((m) => m.chat === '222')!.text;
      expect(toA).toContain('abay Pharmacy — 2026-09-22');
      expect(toA).toContain('Sales: 1 · ETB 45');
      expect(toB).toContain('blue Pharmacy — 2026-09-22');
      expect(toB).toContain('Sales: 0 · ETB 0');
      // Nothing of Abay's in what Blue was sent, by name or by figure.
      expect(toB).not.toContain('abay');
      expect(toB).not.toContain('45');
      expect(toA).not.toContain('blue');
    });

    it('says exactly what the report says for the same day (BR-17.1)', async () => {
      await link(a, 111);
      await push(a, [saleOp(a, { terminalSeq: 1, qty: 3 })]);
      await service.dispatch(closing);

      const { from, to, day } = shopDay(closing);
      const report = (
        await as(a)
          .get('/api/reports/daily-summary')
          .query({ from: from.toISOString(), to: to.toISOString() })
          .expect(200)
      ).body;
      expect(sent[0]!.text).toBe(summaryText(report, { shop: 'abay Pharmacy', day, locale: 'en' }));
    });

    it('sends a day once, however often the schedule fires', async () => {
      await link(a, 111);
      expect(await service.dispatch(closing)).toMatchObject({ sent: 1 });
      expect(await service.dispatch(closing)).toEqual({ sent: 0, skipped: 1, failed: 0 });
      expect(await service.dispatch(new Date(closing.getTime() + 3_600_000))).toMatchObject({
        skipped: 1,
      });
      expect(sent).toHaveLength(1);

      // And the next evening is a new day.
      expect(await service.dispatch(new Date(closing.getTime() + 86_400_000))).toMatchObject({
        sent: 1,
      });
    });

    it('a failed send is tried again, not marked as done', async () => {
      await link(a, 111);
      answer = { ok: false, errorCode: 500 };
      expect(await service.dispatch(closing)).toMatchObject({ sent: 0, failed: 1 });
      answer = { ok: true };
      expect(await service.dispatch(closing)).toMatchObject({ sent: 1 });
    });

    it('one pharmacy failing does not stop the next', async () => {
      await link(a, 111);
      await link(b, 222);
      client.transport = async (_method, body) => {
        if (String(body.chat_id) === '111') return { ok: false, errorCode: 500 };
        sent.push({ chat: String(body.chat_id), text: String(body.text) });
        return { ok: true };
      };
      expect(await service.dispatch(closing)).toEqual({ sent: 1, skipped: 0, failed: 1 });
      expect(sent.map((m) => m.chat)).toEqual(['222']);
    });

    it('sends nothing to a pharmacy the platform has stopped', async () => {
      await link(a, 111);
      // 'closed' and 'deactivated' are both "not active"; closed needs no operator on record.
      await query(`UPDATE tenant SET status = 'closed' WHERE id = $1`, [a.id]);
      expect(await service.dispatch(closing)).toEqual({ sent: 0, skipped: 0, failed: 0 });
      expect(sent).toHaveLength(0);
    });

    it('sends nothing to someone who is no longer the owner, or has left', async () => {
      await link(a, 111);
      await link(b, 222);
      await query(`UPDATE app_user SET role = 'cashier' WHERE id = $1`, [a.users.owner.id]);
      await query(`UPDATE app_user SET deleted_at = now() WHERE id = $1`, [b.users.owner.id]);
      expect(await service.dispatch(closing)).toEqual({ sent: 0, skipped: 0, failed: 0 });
    });

    it('in Amharic for an owner who linked in Amharic', async () => {
      await link(a, 111, 'am');
      await service.dispatch(closing);
      expect(sent[0]!.text).toContain('ሽያጭ፦');
      expect(sent[0]!.text).not.toContain('Sales:');
    });
  });

  describe('"send it now"', () => {
    it('sends today’s summary to the caller’s own chat', async () => {
      await link(a, 111);
      const response = await as(a).post('/api/notifications/telegram/test').expect(200);
      expect(response.body).toEqual({ sent: true });
      expect(sent[0]).toMatchObject({ chat: '111' });
      expect(sent[0]!.text).toContain('abay Pharmacy');
    });

    it('says so, and sends nothing, when no chat is linked', async () => {
      const response = await as(a).post('/api/notifications/telegram/test').expect(200);
      expect(response.body).toEqual({ sent: false });
      expect(sent).toHaveLength(0);
    });

    it('never reaches another pharmacy’s chat', async () => {
      await link(b, 222);
      await as(a).post('/api/notifications/telegram/test').expect(200);
      expect(sent).toHaveLength(0);
    });
  });

  describe('one pharmacy’s link is invisible to another (G1)', () => {
    it('status is the caller’s own', async () => {
      await link(a, 111);
      expect((await as(b).get('/api/notifications/telegram')).body.linked).toBe(false);
    });

    it('the application role cannot read another tenant’s link, by any query', async () => {
      await link(a, 111);
      const asTenant = async (tenantId: string) => {
        const runner = harness.platformDataSource.createQueryRunner();
        await runner.connect();
        await runner.startTransaction();
        try {
          await runner.query(`SET LOCAL ROLE ${process.env.DATABASE_APP_USER ?? 'pharmaet_app'}`);
          await runner.query(`SELECT set_config('app.current_tenant', $1, true)`, [tenantId]);
          return await runner.query(`SELECT chat_id FROM telegram_link`);
        } finally {
          await runner.rollbackTransaction();
          await runner.release();
        }
      };
      expect(await asTenant(a.id)).toHaveLength(1);
      expect(await asTenant(b.id)).toHaveLength(0);
    });
  });

  describe('with no bot configured', () => {
    const off = () => new TelegramClient({ get: () => undefined } as unknown as ConfigService);

    it('reports itself unavailable, sends nothing, and has no webhook secret', async () => {
      const client = off();
      expect(client.configured).toBe(false);
      expect(client.webhookSecret).toBeUndefined();
      expect(await client.sendMessage('1', 'x')).toMatchObject({ ok: false });
    });
  });

  describe('the message', () => {
    it('never nets a shortage against an overage (BR-17.2)', () => {
      const text = summaryText(
        {
          from: '',
          to: '',
          sales: {
            saleCount: 2,
            grossSantim: 123450,
            cashSantim: 100000,
            otherTenderSantim: 3450,
            creditSantim: 20000,
            itemsSold: 5,
          },
          cash: {
            countedShifts: 2,
            countedSantim: 0,
            shortageSantim: 500,
            overageSantim: 300,
            openShifts: 1,
          },
          shifts: [],
          credit: { repaidSantim: 0, owedSantim: 0, customersOwing: 0 },
          stock: { lowCount: 0, low: [], expiringBatches: 0, oversoldBatches: 0 },
          attention: { priceChanges: 0, stockWriteOffs: 0, expiredDispenses: 0 },
          lastSyncedAt: null,
        },
        { shop: 'S', day: '2026-09-22', locale: 'en' },
      );
      expect(text).toContain('Sales: 2 · ETB 1,234.50');
      expect(text).toContain('Cash 1,000.00 · Telebirr & other 34.50 · On credit 200.00');
      expect(text).toContain('Cash is short by 5.00.');
      expect(text).toContain('Cash is over by 3.00.');
      expect(text).not.toContain('2.00');
      expect(text).toContain('Tills still open and not counted: 1.');
    });

    it('takes the shop’s day in Addis Ababa, not the server’s', () => {
      // 23:30 UTC on the 21st is already 02:30 on the 22nd in Addis.
      expect(shopDay(new Date('2026-09-21T23:30:00Z'))).toEqual({
        from: new Date('2026-09-21T21:00:00Z'),
        to: new Date('2026-09-22T21:00:00Z'),
        day: '2026-09-22',
      });
    });
  });
});
