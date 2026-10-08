import {
  Body,
  Controller,
  Delete,
  Get,
  Headers,
  HttpCode,
  NotFoundException,
  Post,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { timingSafeEqual } from 'node:crypto';
import { RequireCapability } from '../../common/auth/capability.decorator';
import { CurrentScope } from '../../common/auth/current-scope.decorator';
import { Public } from '../../common/auth/public.decorator';
import type { TenantScope } from '../../common/db/tenant-scope';
import { TelegramClient } from './telegram.client';
import { TelegramService } from './telegram.service';

/** Constant-time comparison, so the secret cannot be found one character at a time. */
function sameSecret(given: string | undefined, expected: string | undefined): boolean {
  if (!given || !expected) return false;
  const a = Buffer.from(given);
  const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

/**
 * The owner's side: where their end-of-day summary is delivered (FR-17, ADR-039).
 *
 * Gated on `settings.configure`, which the FR-2 matrix grants to the owner alone — the
 * same gate as the audit trail. The summary is the whole business in a paragraph; where it
 * is sent is not a branch manager's or a cashier's to decide.
 */
@Controller('notifications/telegram')
export class NotificationsController {
  constructor(private readonly service: TelegramService) {}

  @Get()
  @RequireCapability('settings.configure')
  status(@CurrentScope() scope: TenantScope) {
    return this.service.status(scope);
  }

  @Post('link')
  @RequireCapability('settings.configure')
  link(@CurrentScope() scope: TenantScope, @Body() body: { locale?: string }) {
    return this.service.startLink(scope, body?.locale === 'am' ? 'am' : 'en');
  }

  @Delete('link')
  @RequireCapability('settings.configure')
  unlink(@CurrentScope() scope: TenantScope) {
    return this.service.unlink(scope);
  }

  @Post('test')
  @HttpCode(200)
  @RequireCapability('settings.configure')
  test(@CurrentScope() scope: TenantScope) {
    return this.service.sendNow(scope);
  }
}

/**
 * The two callers that are not a signed-in person. Each is authenticated by a secret in a
 * header, compared in constant time, and each answers 404 without it — an endpoint that
 * says "wrong secret" confirms that it exists.
 */
@Controller()
export class NotificationsHooksController {
  constructor(
    private readonly service: TelegramService,
    private readonly telegram: TelegramClient,
    private readonly config: ConfigService,
  ) {}

  /** Telegram, telling us what somebody typed to the bot. */
  @Public()
  @Post('telegram/webhook')
  @HttpCode(200)
  async webhook(
    @Headers('x-telegram-bot-api-secret-token') secret: string | undefined,
    @Body() update: unknown,
  ) {
    if (!sameSecret(secret, this.telegram.webhookSecret)) throw new NotFoundException();
    await this.service.handleUpdate(update);
    return { ok: true };
  }

  /**
   * The evening schedule (a GitHub Actions cron — ADR-039 §3), telling us it is closing
   * time. The request itself is what wakes a sleeping free-tier instance.
   */
  @Public()
  @Post('internal/summary-dispatch')
  @HttpCode(200)
  async dispatch(@Headers('x-dispatch-secret') secret: string | undefined) {
    if (!sameSecret(secret, this.config.get<string>('SUMMARY_DISPATCH_SECRET') || undefined)) {
      throw new NotFoundException();
    }
    return this.service.dispatch();
  }
}
