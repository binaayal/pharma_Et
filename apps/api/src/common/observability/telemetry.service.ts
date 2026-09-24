import { Injectable, Logger } from '@nestjs/common';

/**
 * Structured signals for the platform team (NFR-7).
 *
 * `engineering/runbook.md` §2 names four things to watch — sync failure rate, oversell counts,
 * error rate and latency — and said plainly that none of them was wired. This is the half of
 * that which does not need a hosting account: the application emits the signals, and pointing
 * a collector at stdout later is configuration rather than code.
 *
 * **One JSON object per line, on stdout.** Every platform this deploys to collects stdout, so
 * there is no agent to install and nothing to keep running. In development that would be
 * miserable to read, so the formatting flips — a developer tailing a terminal is a user too.
 *
 * **What never appears here:** a PIN, a password, a token, or a username. Tenant and user ids
 * are our own UUIDs and identify a row rather than a person; a username is what somebody
 * types, and a log is the easiest place in a system to leak one. A guardian test asserts it.
 */
@Injectable()
export class TelemetryService {
  private readonly logger = new Logger('telemetry');
  /**
   * Structured everywhere except a developer's own machine.
   *
   * Written as "not development" rather than "production or staging" deliberately: under the
   * other spelling the test suite exercised the human-readable branch, so every assertion
   * about what ships was made against a format that never ships. A guardian test proving no
   * PIN appears in prose says nothing about the JSON a collector will hold for a year.
   */
  private readonly structured = (process.env.NODE_ENV ?? 'development') !== 'development';

  /**
   * One line per request: the error rate and the latency distribution both come from here.
   *
   * The route template rather than the URL — `/api/reports/cash-up/:shiftId`, not the id — so
   * requests aggregate instead of every path being unique.
   */
  request(event: {
    method: string;
    route: string;
    status: number;
    durationMs: number;
    tenantId?: string;
    userId?: string;
    terminalId?: string;
  }): void {
    this.emit('http_request', event);
  }

  /**
   * A push, and what became of it.
   *
   * `rejected` is the number that matters and the one a status code hides: a push returns 201
   * with per-operation acks, so a batch can be entirely refused while the transport looks
   * perfectly healthy (ADR-005). Alerting on HTTP status alone would never see it.
   */
  syncPush(event: {
    tenantId: string;
    terminalId: string;
    received: number;
    applied: number;
    duplicate: number;
    rejected: number;
  }): void {
    this.emit('sync_push', event);
  }

  /**
   * Stock sold below zero (BR-3.2, NFR-7).
   *
   * Expected to be non-zero — this system records oversell rather than preventing it — so the
   * signal is the *rate*. A spike in one branch is a stock problem; a spike across tenants
   * after a deploy is a sync problem, and the runbook's §4.5 turns on telling those apart.
   */
  oversell(event: {
    tenantId: string;
    branchId: string;
    productId: string;
    resultingQty: number;
  }): void {
    this.emit('oversell', event);
  }

  private emit(signal: string, fields: Record<string, unknown>): void {
    const defined = Object.fromEntries(
      Object.entries(fields).filter(([, value]) => value !== undefined && value !== null),
    );

    if (this.structured) {
      // Written straight to stdout rather than through the Nest logger: the logger prepends
      // a timestamp and a coloured context, which would make each line invalid JSON and
      // defeat the entire point.
      process.stdout.write(
        `${JSON.stringify({ signal, ts: new Date().toISOString(), ...defined })}\n`,
      );
      return;
    }

    this.logger.log(
      `${signal} ${Object.entries(defined)
        .map(([k, v]) => `${k}=${v}`)
        .join(' ')}`,
    );
  }
}
