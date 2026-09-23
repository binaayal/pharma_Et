import { Module } from '@nestjs/common';
import { ConfigModule, ConfigService } from '@nestjs/config';
import { APP_GUARD } from '@nestjs/core';
import { TypeOrmModule } from '@nestjs/typeorm';
import { JwtAuthGuard } from './common/auth/jwt-auth.guard';
import { RolesGuard } from './common/auth/roles.guard';
import { DbModule } from './common/db/db.module';
import { PLATFORM_DATA_SOURCE } from './common/db/scoped-db.service';
import { loadConfiguration } from './config/configuration';
import { ALL_ENTITIES } from './entities';
import { AuthModule } from './modules/auth/auth.module';
import { HealthController } from './modules/health/health.controller';
import { InventoryModule } from './modules/inventory/inventory.module';
import { ReportingModule } from './modules/reporting/reporting.module';
import { SyncModule } from './modules/sync/sync.module';

/**
 * Builds the runtime connection string.
 *
 * The application connects as the NON-OWNER role, not as the role in DATABASE_URL. Postgres
 * exempts owners and superusers from row-level security, so connecting as the owner would
 * leave RLS enabled and completely inert — every test would still pass, and tenants would
 * silently share data (ADR-003, ADR-007).
 */
function appConnectionUrl(config: ConfigService): string {
  const url = new URL(config.getOrThrow<string>('DATABASE_URL'));
  url.username = config.getOrThrow<string>('DATABASE_APP_USER');
  url.password = config.getOrThrow<string>('DATABASE_APP_PASSWORD');
  return url.toString();
}

@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true, load: [loadConfiguration], cache: true }),

    // The tenant connection: RLS applies to every query it makes.
    TypeOrmModule.forRootAsync({
      inject: [ConfigService],
      useFactory: (config: ConfigService) => ({
        type: 'postgres' as const,
        url: appConnectionUrl(config),
        entities: ALL_ENTITIES,
        synchronize: false,
        migrationsRun: false,
        logging: config.get('NODE_ENV') === 'development' ? ['error', 'warn'] : ['error'],
      }),
    }),

    // The platform connection: owner role, above every tenant. Reached only through
    // ScopedDbService.runAsPlatform(), which states a reason and logs it (BR-2.2).
    TypeOrmModule.forRootAsync({
      name: PLATFORM_DATA_SOURCE,
      inject: [ConfigService],
      useFactory: (config: ConfigService) => ({
        name: PLATFORM_DATA_SOURCE,
        type: 'postgres' as const,
        url: config.getOrThrow<string>('DATABASE_URL'),
        entities: ALL_ENTITIES,
        synchronize: false,
        migrationsRun: false,
        logging: ['error'] as const,
      }),
    }),

    DbModule,
    AuthModule,
    InventoryModule,
    SyncModule,
    ReportingModule,
  ],
  controllers: [HealthController],
  providers: [
    // Authentication and authorization are global. A route is protected unless it opts out
    // with @Public() — defaulting the other way means a forgotten decorator is a data breach
    // rather than a bug.
    { provide: APP_GUARD, useClass: JwtAuthGuard },
    { provide: APP_GUARD, useClass: RolesGuard },
  ],
})
export class AppModule {}
