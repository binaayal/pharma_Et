import { Controller, Get, Header, Query } from '@nestjs/common';
import { RequireCapability } from '../../common/auth/capability.decorator';
import { CurrentScope } from '../../common/auth/current-scope.decorator';
import { resolveBranchFilter } from '../../common/auth/branch-scope';
import type { TenantScope } from '../../common/db/tenant-scope';
import { assertNotOwnScoped, parseWindow } from '../reporting/reporting.controller';
import { LedgerService } from './ledger.service';

/**
 * The controlled-substance ledger, read (FR-6 AC-6.2, BR-6.3; prototype screen 17).
 *
 * Owner and branch manager, scoped to the branches they may see — the FR-6 "audit view"
 * actors. There is no write route: every ledger write arrives through `/sync/push`, where
 * the rules are enforced, and even the owner cannot edit an event (AC-6.1).
 */
@Controller('ledger')
export class LedgerController {
  constructor(private readonly ledger: LedgerService) {}

  @Get()
  @RequireCapability('report.branch')
  entries(
    @CurrentScope() scope: TenantScope,
    @Query('from') from?: string,
    @Query('to') to?: string,
    @Query('branchId') branchId?: string,
    @Query('productId') productId?: string,
  ) {
    assertNotOwnScoped(scope, 'the controlled-substance ledger');
    return this.ledger.entries(scope, {
      ...parseWindow(from, to),
      branchIds: resolveBranchFilter(scope, branchId),
      productId,
    });
  }

  @Get('stock')
  @RequireCapability('report.branch')
  stock(@CurrentScope() scope: TenantScope, @Query('branchId') branchId?: string) {
    assertNotOwnScoped(scope, 'controlled stock');
    return this.ledger.stock(scope, resolveBranchFilter(scope, branchId));
  }

  @Get('export')
  @RequireCapability('report.branch')
  @Header('Content-Type', 'text/csv; charset=utf-8')
  @Header('Cache-Control', 'no-store')
  export(
    @CurrentScope() scope: TenantScope,
    @Query('from') from?: string,
    @Query('to') to?: string,
    @Query('branchId') branchId?: string,
  ) {
    assertNotOwnScoped(scope, 'the controlled-substance ledger');
    return this.ledger.exportCsv(scope, {
      ...parseWindow(from, to),
      branchIds: resolveBranchFilter(scope, branchId),
    });
  }
}
