import {
  BadRequestException,
  Controller,
  ForbiddenException,
  Get,
  Param,
  Query,
} from '@nestjs/common';
import { RequireCapability } from '../../common/auth/capability.decorator';
import { CurrentScope } from '../../common/auth/current-scope.decorator';
import { grantFor } from '@pharmaet/contracts';
import type { TenantScope } from '../../common/db/tenant-scope';
import { ReportingService } from './reporting.service';

@Controller('reports')
export class ReportingController {
  constructor(private readonly reporting: ReportingService) {}

  /** Tenant-wide read: owners only, per the FR-2 permission matrix. */
  @Get('sales')
  @RequireCapability('report.branch')
  sales(@CurrentScope() scope: TenantScope, @Query('limit') limit?: string) {
    assertNotOwnScoped(scope, 'the branch sales list');
    return this.reporting.recentSales(scope, limit ? Number(limit) : 50);
  }

  @Get('oversells')
  @RequireCapability('report.branch')
  oversells(@CurrentScope() scope: TenantScope) {
    assertNotOwnScoped(scope, 'the oversell report');
    return this.reporting.oversells(scope);
  }

  /**
   * The Z-report for one shift (FR-8, AC-8.1).
   *
   * Open to a cashier as well, because the FR-2 matrix grants them "view branch reports —
   * own shift" (grant `own`). The ownership check is below: the guard can say *whether* a
   * cashier may read a cash-up, but only the data knows *whose* shift it was.
   */
  @Get('cash-up/:shiftId')
  @RequireCapability('report.branch')
  async cashUp(@CurrentScope() scope: TenantScope, @Param('shiftId') shiftId: string) {
    const report = await this.reporting.cashUpReport(scope, shiftId);
    if (scope.role === 'cashier' && report.userId !== scope.userId) {
      throw new ForbiddenException('a cashier may only read their own shift');
    }
    return report;
  }

  /** Tenant-wide or branch-scoped cash-up oversight. Not a cashier's view. */
  @Get('cash-up')
  @RequireCapability('report.branch')
  cashUpSummary(
    @CurrentScope() scope: TenantScope,
    @Query('branchId') branchId?: string,
    @Query('limit') limit?: string,
  ) {
    assertNotOwnScoped(scope, 'the branch cash-up summary');
    return this.reporting.cashUpSummary(scope, branchId, limit ? Number(limit) : 30);
  }

  /**
   * Daily sales summary (AC-8.2). Consolidated and per branch in one response.
   *
   * One endpoint serves both matrix rows. **The T/B distinction is expressed by scoping,
   * not by denial**: an owner holds `report.tenant` and sees every branch, a manager holds
   * `report.branch` and sees their own. Splitting them into two endpoints would duplicate
   * the query and let the two copies drift.
   *
   * An explicit request for someone else's branch is refused rather than returned empty —
   * an empty report is a confident wrong answer.
   */
  @Get('sales-summary')
  @RequireCapability('report.branch')
  salesSummary(
    @CurrentScope() scope: TenantScope,
    @Query('from') from?: string,
    @Query('to') to?: string,
    @Query('branchId') branchId?: string,
  ) {
    // `own` has no meaning for an aggregate across a branch: there is nothing to narrow it
    // to. A cashier's report grant covers their own shift, which is the cash-up, not this.
    assertNotOwnScoped(scope, 'the branch sales summary');
    return this.reporting.salesSummaryReport(scope, {
      ...parseWindow(from, to),
      branchId,
    });
  }

  /** Stock levels with expiry alerting (BR-3.4). */
  @Get('stock')
  @RequireCapability('report.branch')
  stock(
    @CurrentScope() scope: TenantScope,
    @Query('branchId') branchId?: string,
    @Query('expiringWithinDays') expiringWithinDays?: string,
  ) {
    assertNotOwnScoped(scope, 'the stock report');
    const days = expiringWithinDays === undefined ? 90 : Number(expiringWithinDays);
    if (!Number.isInteger(days) || days < 0 || days > 3650) {
      throw new BadRequestException('expiringWithinDays must be a whole number of days, 0–3650');
    }
    return this.reporting.stock(scope, { branchId, expiringWithinDays: days });
  }
}

/**
 * Refuses a report whose grant is `own` to an actor with nothing to narrow it to.
 *
 * The matrix gives a cashier "view branch reports — own shift". That is the cash-up, which
 * carries an owner and can be checked. An aggregate across a branch has no per-actor
 * narrowing, so `own` cannot be honoured on it — and honouring it loosely, by returning the
 * whole branch, is precisely the quiet over-grant this matrix exists to prevent.
 */
export function assertNotOwnScoped(scope: TenantScope, what: string): void {
  if (grantFor(scope.role, 'report.branch') === 'own') {
    throw new ForbiddenException(`your role may not read ${what}`);
  }
}

/**
 * Parses the reporting window, defaulting to today.
 *
 * Half-open — `from` inclusive, `to` exclusive — so consecutive days tile exactly and a
 * sale at midnight is counted once rather than twice or never. Dates arrive as plain
 * calendar dates and are interpreted as UTC, matching how they are stored; the Ethiopian
 * calendar is a presentation concern and never reaches this layer (BR-10.2).
 */
export function parseWindow(from?: string, to?: string): { from: Date; to: Date } {
  const parse = (value: string, label: string): Date => {
    const parsed = new Date(/^\d{4}-\d{2}-\d{2}$/.test(value) ? `${value}T00:00:00Z` : value);
    if (Number.isNaN(parsed.getTime())) {
      throw new BadRequestException(`${label} is not a valid date`);
    }
    return parsed;
  };

  const now = new Date();
  const startOfToday = new Date(
    Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()),
  );

  const start = from ? parse(from, 'from') : startOfToday;
  const end = to ? parse(to, 'to') : new Date(start.getTime() + 86_400_000);

  if (end <= start) {
    throw new BadRequestException('`to` must be after `from`');
  }
  // A year at a time. An unbounded range on a table that grows forever is a request that
  // eventually times out and takes the API's latency budget with it (NFR-3.4).
  if (end.getTime() - start.getTime() > 366 * 86_400_000) {
    throw new BadRequestException('the reporting window may not exceed 366 days');
  }
  return { from: start, to: end };
}
