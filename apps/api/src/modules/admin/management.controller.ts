import { Body, Controller, Delete, Get, Param, Patch, Post } from '@nestjs/common';
import { z } from 'zod';
import { CurrentGrant } from '../../common/auth/current-grant.decorator';
import { CurrentScope } from '../../common/auth/current-scope.decorator';
import { RequireCapability } from '../../common/auth/capability.decorator';
import type { Grant } from '@pharmaet/contracts';
import type { TenantScope } from '../../common/db/tenant-scope';
import { ZodValidationPipe } from '../../common/http/zod-validation.pipe';
import { ManagementService } from './management.service';

const branchInput = z.object({
  name: z.string().min(1).max(120),
  address: z.string().max(400).optional(),
});

const branchPatch = z.object({
  name: z.string().min(1).max(120).optional(),
  address: z.string().max(400).optional(),
});

const userInput = z.object({
  username: z
    .string()
    .min(2)
    .max(64)
    .regex(/^[a-z0-9._-]+$/i, 'letters, digits, . _ - only'),
  displayName: z.string().min(1).max(120),
  role: z.enum(['owner', 'branch_manager', 'cashier']),
  // Counter login: short by design, and rate-limited rather than made long (NFR-4.2).
  pin: z.string().min(4).max(64),
  branchIds: z.array(z.string().uuid()).default([]),
});

const productInput = z.object({
  name: z.string().min(1).max(200),
  unit: z.string().min(1).max(40),
  priceSantim: z.number().int().nonnegative(),
  isControlled: z.boolean().optional(),
});

const priceInput = z.object({ priceSantim: z.number().int().nonnegative() });

/**
 * Tenant administration (FR-1, FR-2, FR-3).
 *
 * Every route declares a capability from the FR-2 matrix rather than a role list. A role
 * list has to be re-derived at each handler and drifts from the SRS one endpoint at a time;
 * a capability is looked up in the one table the matrix tests exercise.
 */
@Controller()
export class ManagementController {
  constructor(private readonly management: ManagementService) {}

  /* ----------------------------------------------------------------- branches */

  @Get('branches')
  @RequireCapability('report.branch')
  listBranches(@CurrentScope() scope: TenantScope) {
    return this.management.listBranches(scope);
  }

  @Post('branches')
  @RequireCapability('branch.manage')
  createBranch(
    @CurrentScope() scope: TenantScope,
    @Body(new ZodValidationPipe(branchInput)) body: z.infer<typeof branchInput>,
  ) {
    return this.management.createBranch(scope, body);
  }

  @Patch('branches/:id')
  @RequireCapability('branch.manage')
  updateBranch(
    @CurrentScope() scope: TenantScope,
    @Param('id') id: string,
    @Body(new ZodValidationPipe(branchPatch)) body: z.infer<typeof branchPatch>,
  ) {
    return this.management.updateBranch(scope, id, body);
  }

  /* -------------------------------------------------------------------- staff */

  @Get('users')
  @RequireCapability('staff.manage')
  listUsers(@CurrentScope() scope: TenantScope, @CurrentGrant() grant: Grant) {
    return this.management.listUsers(scope, grant);
  }

  @Post('users')
  @RequireCapability('staff.manage')
  createUser(
    @CurrentScope() scope: TenantScope,
    @CurrentGrant() grant: Grant,
    @Body(new ZodValidationPipe(userInput)) body: z.infer<typeof userInput>,
  ) {
    return this.management.createUser(scope, grant, body);
  }

  @Delete('users/:id')
  @RequireCapability('staff.manage')
  deactivateUser(
    @CurrentScope() scope: TenantScope,
    @CurrentGrant() grant: Grant,
    @Param('id') id: string,
  ) {
    return this.management.deactivateUser(scope, grant, id);
  }

  /* ------------------------------------------------------------------ catalog */

  @Get('products')
  @RequireCapability('sale.create')
  listProducts(@CurrentScope() scope: TenantScope) {
    return this.management.listProducts(scope);
  }

  @Post('products')
  @RequireCapability('catalog.manage')
  createProduct(
    @CurrentScope() scope: TenantScope,
    @Body(new ZodValidationPipe(productInput)) body: z.infer<typeof productInput>,
  ) {
    return this.management.createProduct(scope, body);
  }

  /** AC-2.1's subject: a cashier attempting this is denied at the API layer. */
  @Post('products/:id/price')
  @RequireCapability('catalog.manage')
  setPrice(
    @CurrentScope() scope: TenantScope,
    @Param('id') id: string,
    @Body(new ZodValidationPipe(priceInput)) body: z.infer<typeof priceInput>,
  ) {
    return this.management.setPrice(scope, id, body.priceSantim);
  }
}
