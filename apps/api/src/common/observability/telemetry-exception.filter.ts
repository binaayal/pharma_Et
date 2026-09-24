import { ArgumentsHost, Catch, HttpException } from '@nestjs/common';
import { BaseExceptionFilter } from '@nestjs/core';
import type { TenantScope } from '../db/tenant-scope';
import { TelemetryService } from './telemetry.service';

/**
 * Records the requests that failed (NFR-7).
 *
 * The interceptor cannot see these. **Guards run before interceptors**, so a request refused
 * by `JwtAuthGuard` — an expired token, a missing one, a refresh token used as an access
 * token — never reaches one, and an interceptor-only implementation produces a log in which
 * every authentication failure is invisible. Those are the requests a platform team most
 * wants counted.
 *
 * So the split is by outcome rather than by convenience: the interceptor records what
 * succeeded, this records what did not, and nothing is written twice.
 *
 * It changes no response. `super.catch` produces exactly the body Nest would have produced
 * anyway — an observability layer that alters what a client receives has stopped observing.
 */
@Catch()
export class TelemetryExceptionFilter extends BaseExceptionFilter {
  constructor(private readonly telemetry: TelemetryService) {
    super();
  }

  catch(exception: unknown, host: ArgumentsHost): void {
    if (host.getType() === 'http') {
      const request = host.switchToHttp().getRequest();
      const scope: TenantScope | undefined = request.scope;
      const status = exception instanceof HttpException ? exception.getStatus() : 500;

      this.telemetry.request({
        method: request.method,
        route: request.route?.path ?? request.url?.split('?')[0] ?? 'unknown',
        status,
        // Set by the interceptor when it ran. A guard rejection never reached it, so there is
        // no start time to measure from — and reporting a fabricated duration would poison
        // the latency distribution the number exists for.
        durationMs: request.telemetryStartedAt
          ? Number(process.hrtime.bigint() - request.telemetryStartedAt) / 1e6
          : 0,
        tenantId: scope?.tenantId,
        userId: scope?.userId,
        terminalId: request.terminalId,
      });
    }

    super.catch(exception, host);
  }
}
