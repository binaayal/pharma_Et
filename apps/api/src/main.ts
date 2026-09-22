import 'reflect-metadata';
import { Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { NestFactory } from '@nestjs/core';
import * as dotenv from 'dotenv';
import { AppModule } from './app.module';

dotenv.config();

async function bootstrap(): Promise<void> {
  const app = await NestFactory.create(AppModule, { bufferLogs: false });
  const config = app.get(ConfigService);

  app.setGlobalPrefix('api');
  // No global class-validator pipe: request validation is done by ZodValidationPipe against
  // the shared contract schemas (ADR-010), so there is exactly one definition of a valid
  // request and both sides of the wire are generated from it.
  app.enableCors({
    origin: config.get<string[]>('corsOrigins') ?? ['http://localhost:5173'],
    credentials: true,
  });
  app.enableShutdownHooks();

  const port = config.get<number>('PORT', 3000);
  await app.listen(port);
  new Logger('bootstrap').log(`API listening on http://localhost:${port}/api`);
}

void bootstrap();
