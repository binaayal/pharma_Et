import { Injectable, Logger, ServiceUnavailableException } from '@nestjs/common';
import { createHash, randomBytes } from 'node:crypto';
import { IsNull, Not } from 'typeorm';
import { uuidv7 } from 'uuidv7';
import { ScopedDbService } from '../../common/db/scoped-db.service';
import type { TenantScope } from '../../common/db/tenant-scope';
import { AppUser, TelegramLink, Tenant } from '../../entities';
import { DailySummaryService } from '../reporting/daily-summary.service';
import { type SummaryLocale, shopDay, summaryText } from './summary-text';
import { TelegramClient } from './telegram.client';

/** How long a linking code works. Long enough to switch apps; short enough to be useless later. */
const CODE_TTL_MS = 15 * 60 * 1000;

const hashOf = (code: string): string => createHash('sha256').update(code).digest('hex');

const REPLY: Record<SummaryLocale, Record<string, string>> = {
  en: {
    linked:
      'Connected to {shop}. You will get the day’s summary here each evening. Send /stop to turn it off.',
    stopped: 'Stopped. You will not get the summary here any more.',
  },
  am: {
    linked: 'ከ{shop} ጋር ተገናኝቷል። የቀኑ ማጠቃለያ በየምሽቱ እዚህ ይደርስዎታል። ለማቆም /stop ይላኩ።',
    stopped: 'ቆሟል። ማጠቃለያው ከእንግዲህ እዚህ አይደርስዎትም።',
  },
};

const HELP =
  'This bot delivers a pharmacy’s end-of-day summary. To connect it, open PharmaEt → More → ' +
  'Daily summary on Telegram, and tap Connect.';
const BAD_CODE =
  'That link has expired or was already used. Open PharmaEt → More → Daily summary on ' +
  'Telegram, and tap Connect again.';

export interface TelegramStatus {
  /** Whether this service has a bot at all. False: nothing here can work yet. */
  available: boolean;
  botUsername: string | null;
  linked: boolean;
  linkedAt: string | null;
  lastSentFor: string | null;
}

/**
 * The end-of-day summary, delivered (FR-17, ADR-039).
 *
 * Three things, and the boundary between them is the point:
 *
 *   - an **owner**, signed in, asks for a link, turns delivery off, or asks for today's
 *     summary now. Tenant-scoped, like any other request.
 *   - **Telegram** tells us somebody pressed Start with a code. That arrives with no
 *     session at all; the code is the only credential, it is single-use, and it expires.
 *   - the **nightly dispatch** walks every linked owner. It is the one place a summary is
 *     computed without that owner asking — so each one is computed inside *that tenant's*
 *     scope, under RLS, exactly as if they had opened the screen. The platform connection
 *     is used to find who is linked, never to read a pharmacy's figures.
 */
@Injectable()
export class TelegramService {
  private readonly logger = new Logger(TelegramService.name);

  constructor(
    private readonly db: ScopedDbService,
    private readonly telegram: TelegramClient,
    private readonly daily: DailySummaryService,
  ) {}

  async status(scope: TenantScope): Promise<TelegramStatus> {
    const link = await this.db.runInScope(scope, (em) =>
      em.getRepository(TelegramLink).findOne({ where: { userId: scope.userId } }),
    );
    return {
      available: this.telegram.configured,
      botUsername: this.telegram.botUsername ?? null,
      linked: Boolean(link?.chatId),
      linkedAt: link?.chatId ? (link.linkedAt?.toISOString() ?? null) : null,
      lastSentFor: link?.chatId ? link.lastSentFor : null,
    };
  }

  /**
   * Issues a one-time link into the bot. Opening it and pressing Start is what proves the
   * chat belongs to the person signed in here: nobody types a chat id, and nobody can
   * point a pharmacy's figures at a chat they do not hold the phone for.
   */
  async startLink(
    scope: TenantScope,
    locale: SummaryLocale,
  ): Promise<{ url: string; expiresAt: string }> {
    this.assertAvailable();
    // 24 random bytes, base64url: 32 characters of the alphabet Telegram allows in a
    // start parameter, and far too many to guess in fifteen minutes.
    const code = randomBytes(24).toString('base64url');
    const expiresAt = new Date(Date.now() + CODE_TTL_MS);

    await this.db.runInScope(scope, async (em) => {
      const repo = em.getRepository(TelegramLink);
      const existing = await repo.findOne({ where: { userId: scope.userId } });
      if (existing) {
        // Asking again replaces the code. An existing chat stays linked until the new one
        // is confirmed, so a half-finished relink does not silently stop delivery.
        await repo.update(
          { id: existing.id },
          { codeHash: hashOf(code), codeExpiresAt: expiresAt, locale, deletedAt: null },
        );
      } else {
        await repo.insert({
          id: uuidv7(),
          tenantId: scope.tenantId,
          userId: scope.userId,
          chatId: null,
          codeHash: hashOf(code),
          codeExpiresAt: expiresAt,
          locale,
          linkedAt: null,
          lastSentFor: null,
          deletedAt: null,
        });
      }
    });

    return {
      url: `https://t.me/${this.telegram.botUsername}?start=${code}`,
      expiresAt: expiresAt.toISOString(),
    };
  }

  async unlink(scope: TenantScope): Promise<{ linked: false }> {
    await this.db.runInScope(scope, (em) =>
      em
        .getRepository(TelegramLink)
        .update(
          { userId: scope.userId },
          { chatId: null, codeHash: null, codeExpiresAt: null, linkedAt: null },
        ),
    );
    return { linked: false };
  }

  /** Sends today's summary to the caller's own chat, now. */
  async sendNow(scope: TenantScope, now = new Date()): Promise<{ sent: boolean }> {
    this.assertAvailable();
    const link = await this.db.runInScope(scope, (em) =>
      em.getRepository(TelegramLink).findOne({ where: { userId: scope.userId } }),
    );
    if (!link?.chatId) return { sent: false };
    const result = await this.sendSummary(scope, link, now);
    return { sent: result === 'sent' };
  }

  /**
   * What somebody typed to the bot. Never throws: Telegram retries a failed delivery for
   * hours, and a message we cannot use is not a reason to be sent it again.
   */
  async handleUpdate(update: unknown): Promise<void> {
    const message = (update as { message?: { chat?: { id?: number }; text?: string } })?.message;
    const chatId = message?.chat?.id;
    const text = message?.text?.trim() ?? '';
    if (chatId === undefined || chatId === null) return;
    const chat = String(chatId);

    try {
      if (text === '/stop') {
        const stopped = await this.db.runAsPlatform('telegram /stop: unlink this chat', (em) =>
          em.getRepository(TelegramLink).update({ chatId: chat }, { chatId: null, linkedAt: null }),
        );
        if ((stopped.affected ?? 0) > 0) await this.telegram.sendMessage(chat, REPLY.en.stopped);
        return;
      }

      const start = /^\/start(?:@\w+)?\s+([A-Za-z0-9_-]{16,64})$/.exec(text);
      if (!start) {
        await this.telegram.sendMessage(chat, HELP);
        return;
      }

      const linked = await this.db.runAsPlatform(
        'telegram /start: redeem a one-time linking code',
        async (em) => {
          const repo = em.getRepository(TelegramLink);
          const link = await repo.findOne({
            where: { codeHash: hashOf(start[1]!), deletedAt: IsNull() },
          });
          if (!link || !link.codeExpiresAt || link.codeExpiresAt.getTime() < Date.now()) {
            return null;
          }
          // Single use: the code is cleared in the transaction that honours it.
          await repo.update(
            { id: link.id },
            { chatId: chat, linkedAt: new Date(), codeHash: null, codeExpiresAt: null },
          );
          const tenant = await em.getRepository(Tenant).findOne({ where: { id: link.tenantId } });
          return { locale: link.locale, shop: tenant?.name ?? '' };
        },
      );

      if (!linked) {
        await this.telegram.sendMessage(chat, BAD_CODE);
        return;
      }
      const reply = (REPLY[linked.locale] ?? REPLY.en).linked.split('{shop}').join(linked.shop);
      await this.telegram.sendMessage(chat, reply);
    } catch (error) {
      this.logger.error(
        `telegram update not handled: ${error instanceof Error ? error.message : 'error'}`,
      );
    }
  }

  /**
   * Sends the day's summary to everyone who asked for it and has not had it yet.
   *
   * Safe to call twice: `last_sent_for` records the day, so a retried or duplicated
   * schedule sends once. One pharmacy failing does not stop the next.
   */
  async dispatch(now = new Date()): Promise<{ sent: number; skipped: number; failed: number }> {
    if (!this.telegram.configured) return { sent: 0, skipped: 0, failed: 0 };
    const { day } = shopDay(now);

    const links = await this.db.runAsPlatform(
      'daily summary dispatch: list who is linked',
      async (em) => {
        const rows = await em.getRepository(TelegramLink).find({
          where: { chatId: Not(IsNull()), deletedAt: IsNull() },
          order: { createdAt: 'ASC' },
        });
        if (rows.length === 0) return [];
        const tenants = await em.getRepository(Tenant).find();
        const users = await em.getRepository(AppUser).find({ where: { deletedAt: IsNull() } });
        const active = new Set(
          tenants.filter((t) => t.status === 'active' && !t.deletedAt).map((t) => t.id),
        );
        const roleOf = new Map(users.map((u) => [u.id, u.role]));
        // A pharmacy the platform has stopped, or a person who has left it or is no longer
        // its owner, gets nothing — a link is not a standing right to the figures.
        return rows.filter((l) => active.has(l.tenantId) && roleOf.get(l.userId) === 'owner');
      },
    );

    let sent = 0;
    let skipped = 0;
    let failed = 0;
    for (const link of links) {
      if (link.lastSentFor === day) {
        skipped++;
        continue;
      }
      try {
        const scope: TenantScope = {
          tenantId: link.tenantId,
          userId: link.userId,
          role: 'owner',
          branchIds: [],
        };
        const outcome = await this.sendSummary(scope, link, now);
        if (outcome === 'sent') sent++;
        else failed++;
      } catch (error) {
        failed++;
        this.logger.error(
          `summary for tenant ${link.tenantId} not sent: ${
            error instanceof Error ? error.message : 'error'
          }`,
        );
      }
    }
    return { sent, skipped, failed };
  }

  /** Computes one tenant's day inside that tenant's scope and sends it to one chat. */
  private async sendSummary(
    scope: TenantScope,
    link: TelegramLink,
    now: Date,
  ): Promise<'sent' | 'failed'> {
    const { from, to, day } = shopDay(now);
    const { summary, shop } = await this.db.runInScope(scope, async (em) => ({
      summary: await this.daily.summarise(em, { from, to, branchIds: null }),
      shop: (await em.getRepository(Tenant).findOne({ where: { id: scope.tenantId } }))?.name ?? '',
    }));

    const result = await this.telegram.sendMessage(
      link.chatId!,
      summaryText(summary, { shop, day, locale: link.locale }),
    );

    if (result.ok) {
      await this.db.runInScope(scope, (em) =>
        em.getRepository(TelegramLink).update({ id: link.id }, { lastSentFor: day }),
      );
      return 'sent';
    }
    if (result.errorCode === 403) {
      // The person blocked the bot or deleted the chat. Stop trying; they can reconnect.
      await this.db.runInScope(scope, (em) =>
        em.getRepository(TelegramLink).update({ id: link.id }, { chatId: null, linkedAt: null }),
      );
    }
    return 'failed';
  }

  private assertAvailable(): void {
    if (!this.telegram.configured) {
      throw new ServiceUnavailableException('Telegram delivery is not set up for this service yet');
    }
  }
}
