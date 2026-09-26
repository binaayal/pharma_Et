import { Global, Module } from '@nestjs/common';
import { APP_FILTER, APP_INTERCEPTOR } from '@nestjs/core';
import { RequestLoggerInterceptor } from './request-logger.interceptor';
import { TelemetryExceptionFilter } from './telemetry-exception.filter';
import { TelemetryService } from './telemetry.service';

/**
 * NFR-7's signals, available everywhere.
 *
 * `@Global()` is used sparingly in this codebase and earns it here: telemetry is genuinely
 * cross-cutting — inventory emits an oversell, sync emits a push outcome, the interceptor
 * emits every request — and the alternative is importing this module into every feature
 * module that ever needs to say something. A module you must remember to import is a signal
 * somebody will forget to emit.
 *
 * The service holds no state and reaches nothing, so it carries none of the coupling that
 * usually makes a global module regrettable.
 */
@Global()
@Module({
  providers: [
    TelemetryService,
    { provide: APP_INTERCEPTOR, useClass: RequestLoggerInterceptor },
    // Guards run before interceptors, so a rejected token never reaches one. Without this
    // filter the log would contain every request except the refusals.
    { provide: APP_FILTER, useClass: TelemetryExceptionFilter },
  ],
  exports: [TelemetryService],
})
export class ObservabilityModule {}
