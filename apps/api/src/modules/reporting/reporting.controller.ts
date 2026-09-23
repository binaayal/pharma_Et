import { Controller, ForbiddenException, Get, Param, Query } from '@nestjs/common';
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
}
