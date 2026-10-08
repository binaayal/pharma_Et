import { Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { createHash } from 'node:crypto';

/** What Telegram answered, reduced to what the caller acts on. */
export interface TelegramResult {
  ok: boolean;
  /** Telegram's own error code: 403 means the person blocked the bot or deleted the chat. */
  errorCode?: number;
  description?: string;
}

export type TelegramTransport = (
  method: string,
  body: Record<string, unknown>,
) => Promise<TelegramResult>;

/**
 * The Telegram Bot API, as far as this system uses it (ADR-039): send a message, and tell
 * Telegram where to deliver what people type to the bot.
 *
 * **Dormant unless configured.** With no `TELEGRAM_BOT_TOKEN` nothing is sent and nothing is
 * called; the feature reports itself unavailable and the rest of the system is unaffected.
 * A bot is an account somebody has to create, and that somebody is the owner of this
 * service, not its code.
 *
 * The token is a credential. It is read from configuration, used in a URL to Telegram and
 * nowhere else: never logged, never returned by an endpoint.
 */
@Injectable()
export class TelegramClient {
  private readonly logger = new Logger(TelegramClient.name);

  constructor(private readonly config: ConfigService) {}

  /** For tests: stands in for the network. */
  transport: TelegramTransport | null = null;

  private get token(): string | undefined {
    return this.config.get<string>('TELEGRAM_BOT_TOKEN') || undefined;
  }

  /** The bot's @name, without the @ — what a `t.me` link is built from. */
  get botUsername(): string | undefined {
    return this.config.get<string>('TELEGRAM_BOT_USERNAME')?.replace(/^@/, '') || undefined;
  }

  get configured(): boolean {
    return Boolean(this.token && this.botUsername);
  }

  /**
   * The secret Telegram echoes back on every webhook call, so the endpoint can tell
   * Telegram from anyone else who found the URL. Derived from the token rather than
   * configured separately: one fewer secret to set, and rotating the token rotates it.
   */
  get webhookSecret(): string | undefined {
    const token = this.token;
    return token ? createHash('sha256').update(`${token}:webhook`).digest('hex') : undefined;
  }

  async sendMessage(chatId: string, text: string): Promise<TelegramResult> {
    return this.call('sendMessage', {
      chat_id: chatId,
      text,
      // Plain text on purpose: a product name containing `_` or `*` must not be read as
      // formatting, and must certainly not be able to break the message.
      disable_web_page_preview: true,
    });
  }

  async setWebhook(url: string): Promise<TelegramResult> {
    return this.call('setWebhook', {
      url,
      secret_token: this.webhookSecret,
      allowed_updates: ['message'],
    });
  }

  private async call(method: string, body: Record<string, unknown>): Promise<TelegramResult> {
    const token = this.token;
    if (!token) return { ok: false, description: 'telegram is not configured' };
    if (this.transport) return this.transport(method, body);

    try {
      const response = await fetch(`https://api.telegram.org/bot${token}/${method}`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(15_000),
      });
      const json = (await response.json().catch(() => ({}))) as {
        ok?: boolean;
        error_code?: number;
        description?: string;
      };
      return { ok: json.ok === true, errorCode: json.error_code, description: json.description };
    } catch (error) {
      // The message, never the URL: the URL has the token in it.
      const name = error instanceof Error ? error.name : 'error';
      this.logger.warn(`telegram ${method} failed: ${name}`);
      return { ok: false, description: name };
    }
  }
}
