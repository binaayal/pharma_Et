import { Controller, Get, Query } from '@nestjs/common';
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
}
