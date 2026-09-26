import {
  CallHandler,
  ExecutionContext,
  Injectable,
  NestInterceptor,
} from '@nestjs/common';
import { Observable, tap } from 'rxjs';
import type { TenantScope } from '../db/tenant-scope';
import { TelemetryService } from './telemetry.service';

/**
 * One structured line per request (NFR-7).
 *
 * Error rate and latency — two of the four signals `engineering/runbook.md` §2 watches — are
 * both derived from this, so it runs on every route rather than on a chosen few. A signal
 * that only covers the endpoints somebody remembered to instrument answers questions about
 * those endpoints and nothing else.
 *
 * It records the outcome of failures too. The obvious implementation logs on success and
 * lets errors propagate, which loses precisely the requests worth alerting on.
 */
@Injectable()
export class RequestLoggerInterceptor implements NestInterceptor {
  constructor(private readonly telemetry: TelemetryService) {}

  intercept(context: ExecutionContext, next: CallHandler): Observable<unknown> {
    if (context.getType() !== 'http') return next.handle();

    const started = process.hrtime.bigint();
    const request = context.switchToHttp().getRequest();
    // Left on the request so the exception filter can measure from the same origin for the
    // failures that do reach a handler.
    request.telemetryStartedAt = started;
    const response = context.switchToHttp().getResponse();

    const record = (status: number) => {
      const scope: TenantScope | undefined = request.scope;
      this.telemetry.request({
        method: request.method,
        // The route template, not the URL: `/api/reports/cash-up/:shiftId` aggregates, while
        // the path with an id in it makes every request unique and every average meaningless.
        route: request.route?.path ?? request.url?.split('?')[0] ?? 'unknown',
        status,
        durationMs: Number(process.hrtime.bigint() - started) / 1e6,
        tenantId: scope?.tenantId,
        userId: scope?.userId,
        terminalId: request.terminalId,
      });
    };

    // Successes only. Failures are recorded by TelemetryExceptionFilter, because a guard
    // rejection never reaches an interceptor at all — and splitting by outcome keeps each
    // request written exactly once.
    return next.handle().pipe(tap({ next: () => record(response.statusCode) }));
  }
}
