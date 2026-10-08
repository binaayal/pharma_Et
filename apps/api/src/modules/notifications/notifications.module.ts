import { Logger, Module, type OnApplicationBootstrap } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { CashUpModule } from '../cashup/cashup.module';
import { DailySummaryService } from '../reporting/daily-summary.service';
import { SalesSummaryService } from '../reporting/sales-summary.service';
import { NotificationsController, NotificationsHooksController } from './notifications.controller';
import { TelegramClient } from './telegram.client';
import { TelegramService } from './telegram.service';

/**
 * Delivery of the end-of-day summary (FR-17, ADR-039).
 *
 * On start, if a bot is configured and the service knows its own public address, it tells
 * Telegram where to send what people type to the bot. Idempotent, and never fatal: a
 * server that cannot reach Telegram must still sell medicine.
 */
@Module({
  imports: [CashUpModule],
  controllers: [NotificationsController, NotificationsHooksController],
  providers: [TelegramClient, TelegramService, DailySummaryService, SalesSummaryService],
})
export class NotificationsModule implements OnApplicationBootstrap {
  private readonly logger = new Logger(NotificationsModule.name);

  constructor(
    private readonly telegram: TelegramClient,
    private readonly config: ConfigService,
  ) {}

  async onApplicationBootstrap(): Promise<void> {
    if (this.config.get('NODE_ENV') === 'test' || !this.telegram.configured) return;
    // Render sets RENDER_EXTERNAL_URL on every web service; PUBLIC_BASE_URL overrides it
    // for any other host.
    const base =
      this.config.get<string>('PUBLIC_BASE_URL') || this.config.get<string>('RENDER_EXTERNAL_URL');
    if (!base) {
      this.logger.warn('telegram is configured but the public URL is unknown: webhook not set');
      return;
    }
    const result = await this.telegram.setWebhook(
      `${base.replace(/\/$/, '')}/api/telegram/webhook`,
    );
    if (result.ok) this.logger.log('telegram webhook registered');
    else this.logger.warn(`telegram webhook not registered: ${result.description ?? 'unknown'}`);
  }
}
