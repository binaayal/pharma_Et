import {
  BadRequestException,
  Controller,
  ForbiddenException,
  Get,
  Param,
  Query,
} from '@nestjs/common';
import { CurrentScope } from '../../common/auth/current-scope.decorator';
import { Roles } from '../../common/auth/roles.decorator';
import type { TenantScope } from '../../common/db/tenant-scope';
import { ReportingService } from './reporting.service';

@Controller('reports')
export class ReportingController {
  constructor(private readonly reporting: ReportingService) {}

  /** Tenant-wide read: owners only, per the FR-2 permission matrix. */
  @Get('sales')
  @Roles('owner', 'branch_manager')
  sales(@CurrentScope() scope: TenantScope, @Query('limit') limit?: string) {
    return this.reporting.recentSales(scope, limit ? Number(limit) : 50);
  }

  @Get('oversells')
  @Roles('owner', 'branch_manager')
  oversells(@CurrentScope() scope: TenantScope) {
    return this.reporting.oversells(scope);
  }

  /**
   * The Z-report for one shift (FR-8, AC-8.1).
   *
   * Open to a cashier as well, because the FR-2 matrix grants them "view branch reports —
   * own shift". The ownership check is below: the role guard can say *whether* a cashier may
   * read a cash-up, but only the data knows *whose* shift it is.
   */
  @Get('cash-up/:shiftId')
  @Roles('owner', 'branch_manager', 'cashier')
  async cashUp(@CurrentScope() scope: TenantScope, @Param('shiftId') shiftId: string) {
    const report = await this.reporting.cashUpReport(scope, shiftId);
    if (scope.role === 'cashier' && report.userId !== scope.userId) {
      throw new ForbiddenException('a cashier may only read their own shift');
    }
    return report;
  }

  /** Tenant-wide or branch-scoped cash-up oversight. Not a cashier's view. */
  @Get('cash-up')
  @Roles('owner', 'branch_manager')
  cashUpSummary(
    @CurrentScope() scope: TenantScope,
    @Query('branchId') branchId?: string,
    @Query('limit') limit?: string,
  ) {
    return this.reporting.cashUpSummary(scope, branchId, limit ? Number(limit) : 30);
  }

  /**
   * Daily sales summary (AC-8.2). Consolidated and per branch in one response.
   *
   * A branch manager is silently narrowed to their own branches by the scope resolver, and
   * an explicit request for someone else's branch is refused rather than returned empty —
   * an empty report is a confident wrong answer.
   */
  @Get('sales-summary')
  @Roles('owner', 'branch_manager')
  salesSummary(
    @CurrentScope() scope: TenantScope,
    @Query('from') from?: string,
    @Query('to') to?: string,
    @Query('branchId') branchId?: string,
  ) {
    return this.reporting.salesSummaryReport(scope, {
      ...parseWindow(from, to),
      branchId,
    });
  }

  /** Stock levels with expiry alerting (BR-3.4). */
  @Get('stock')
  @Roles('owner', 'branch_manager')
  stock(
    @CurrentScope() scope: TenantScope,
    @Query('branchId') branchId?: string,
    @Query('expiringWithinDays') expiringWithinDays?: string,
  ) {
    const days = expiringWithinDays === undefined ? 90 : Number(expiringWithinDays);
    if (!Number.isInteger(days) || days < 0 || days > 3650) {
      throw new BadRequestException('expiringWithinDays must be a whole number of days, 0–3650');
    }
    return this.reporting.stock(scope, { branchId, expiringWithinDays: days });
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
function parseWindow(from?: string, to?: string): { from: Date; to: Date } {
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
