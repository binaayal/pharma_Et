import 'reflect-metadata';
import { Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { NestFactory } from '@nestjs/core';
import * as dotenv from 'dotenv';
import type { NestExpressApplication } from '@nestjs/platform-express';
import { AppModule } from './app.module';
import { serveDashboard } from './serve-dashboard';

/**
 * Maximum accepted request body.
 *
 * Derived from the sync contract, not guessed: a push may carry up to 500 operations
 * (`pushRequest` in @pharmaet/contracts), and a realistic worst case — 500 sales of four
 * lines each — measures about 770 KB. Express defaults to **100 KB**, which silently
 * rejects any batch past roughly 60 operations with a 413.
 *
 * That default is not a tuning detail here. A terminal returning from a 72-hour outage —
 * the window NFR-1.1 guarantees — pushes exactly such a batch, would receive a 413, would
 * keep every operation in its outbox because nothing was acknowledged, and would fail the
 * same way on every retry forever. The product's central promise would break precisely in
 * the situation it was built for.
 *
 * 2 MB leaves room for the contract's ceiling plus growth, and is still small enough to
 * refuse anything that is not a legitimate batch.
 */
const MAX_BODY_SIZE = '2mb';

dotenv.config();

async function bootstrap(): Promise<void> {
  const app = await NestFactory.create<NestExpressApplication>(AppModule, { bufferLogs: false });

  // Must replace Nest's parser rather than adding another: `app.use(express.json())` after
  // creation registers behind Nest's own body parser, which has already rejected the
  // request at 100 KB by the time the second one is reached.
  app.useBodyParser('json', { limit: MAX_BODY_SIZE });
  app.useBodyParser('urlencoded', { limit: MAX_BODY_SIZE, extended: true });
  const config = app.get(ConfigService);

  app.setGlobalPrefix('api');
  // No global class-validator pipe: request validation is done by ZodValidationPipe against
  // the shared contract schemas (ADR-010), so there is exactly one definition of a valid
  // request and both sides of the wire are generated from it.
  app.enableCors({
    origin: config.get<string[]>('corsOrigins') ?? ['http://localhost:5173'],
    credentials: true,
  });
  // Registered after Nest's router, so API routes always win; unmatched requests fall
  // through to the static handler and then to the SPA fallback (docs/03 §7).
  serveDashboard(app);

  app.enableShutdownHooks();

  const port = config.get<number>('PORT', 3000);
  await app.listen(port);
  new Logger('bootstrap').log(`API listening on http://localhost:${port}/api`);
}

void bootstrap();
