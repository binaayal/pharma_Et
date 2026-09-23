import {
  BadRequestException,
  Body,
  Controller,
  Get,
  Param,
  Post,
  Req,
  Res,
  UploadedFile,
  UseGuards,
  UseInterceptors,
} from '@nestjs/common';
import { FileInterceptor } from '@nestjs/platform-express';
import type { Response } from 'express';
import { z } from 'zod';
import { AllowWhenSuspended } from '../../common/auth/allow-when-suspended.decorator';
import { RequireCapability } from '../../common/auth/capability.decorator';
import { CurrentScope } from '../../common/auth/current-scope.decorator';
import { PlatformAdminGuard } from '../../common/auth/platform-admin.guard';
import { Public } from '../../common/auth/public.decorator';
import type { TenantScope } from '../../common/db/tenant-scope';
import { ZodValidationPipe } from '../../common/http/zod-validation.pipe';
import { BillingService } from './billing.service';
import { PlatformAuthService } from './platform-auth.service';

const submitProof = z.object({
  amountSantim: z.coerce.number().int().positive(),
  note: z.string().max(500).optional(),
});

const platformLogin = z.object({
  email: z.string().email(),
  password: z.string().min(8).max(200),
});

const decideProof = z.object({
  accept: z.boolean(),
  reason: z.string().max(500).optional(),
  periodDays: z.number().int().min(1).max(366).optional(),
});

const setState = z.object({
  tenantId: z.string().uuid(),
  state: z.enum(['active', 'suspended']),
  reason: z.string().max(500).optional(),
});

const onboard = z.object({
  name: z.string().min(2).max(200),
  code: z
    .string()
    .min(2)
    .max(32)
    .regex(/^[a-z0-9-]+$/i, 'letters, digits and hyphens only'),
  ownerUsername: z
    .string()
    .min(2)
    .max(64)
    .regex(/^[a-z0-9._-]+$/i),
  ownerDisplayName: z.string().min(1).max(120),
  ownerPin: z.string().min(4).max(64),
});

/** The tenant's own billing surface. */
@Controller('billing')
export class BillingController {
  constructor(private readonly billing: BillingService) {}

  @Get('subscription')
  @RequireCapability('settings.configure')
  subscription(@CurrentScope() scope: TenantScope) {
    return this.billing.mySubscription(scope);
  }

  @Get('payment-proofs')
  @RequireCapability('settings.configure')
  proofs(@CurrentScope() scope: TenantScope) {
    return this.billing.myProofs(scope);
  }

  /**
   * Submit a payment screenshot (Vision §4).
   *
   * **Allowed while suspended (ADR-016)** — it is the one action that ends a suspension, and
   * blocking it would leave a tenant with no route out.
   */
  @Post('payment-proofs')
  @RequireCapability('settings.configure')
  @AllowWhenSuspended()
  @UseInterceptors(FileInterceptor('screenshot', { limits: { fileSize: 8 * 1024 * 1024 } }))
  async submit(
    @CurrentScope() scope: TenantScope,
    @UploadedFile() file: { buffer: Buffer; mimetype: string; size: number } | undefined,
    @Body(new ZodValidationPipe(submitProof)) body: z.infer<typeof submitProof>,
  ) {
    if (!file) throw new BadRequestException('a screenshot file is required');
    return this.billing.submitProof(scope, file, body);
  }
}

/**
 * The platform console (us). Outside tenant scope entirely.
 *
 * Guarded by `PlatformAdminGuard`, which verifies the token's `typ` rather than merely its
 * signature — a tenant token must never reach a route that can suspend a pharmacy.
 */
@Controller('platform')
export class PlatformController {
  constructor(
    private readonly billing: BillingService,
    private readonly auth: PlatformAuthService,
  ) {}

  @Public()
  @Post('login')
  login(@Body(new ZodValidationPipe(platformLogin)) body: z.infer<typeof platformLogin>) {
    return this.auth.login(body.email, body.password);
  }

  @Get('tenants')
  @Public()
  @UseGuards(PlatformAdminGuard)
  tenants() {
    return this.billing.listTenants();
  }

  @Post('tenants')
  @Public()
  @UseGuards(PlatformAdminGuard)
  onboard(
    @Body(new ZodValidationPipe(onboard)) body: z.infer<typeof onboard>,
    @Req() request: { platformAdmin: { id: string } },
  ) {
    return this.billing.createTenant(request.platformAdmin.id, body);
  }

  /** The work queue: everything waiting on a human, oldest first. */
  @Get('payment-proofs')
  @Public()
  @UseGuards(PlatformAdminGuard)
  pending() {
    return this.billing.pendingProofs();
  }

  @Get('payment-proofs/:id/image')
  @Public()
  @UseGuards(PlatformAdminGuard)
  async image(@Param('id') id: string, @Res() res: Response) {
    const { buffer, contentType } = await this.billing.proofImage(id);
    // Never cached: a payment screenshot is somebody's bank app, and it has no business
    // sitting in a proxy or a browser cache after the tab closes.
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('Content-Type', contentType);
    res.send(buffer);
  }

  @Post('payment-proofs/:id/decide')
  @Public()
  @UseGuards(PlatformAdminGuard)
  decide(
    @Param('id') id: string,
    @Body(new ZodValidationPipe(decideProof)) body: z.infer<typeof decideProof>,
    @Req() request: { platformAdmin: { id: string } },
  ) {
    return this.billing.decideProof(request.platformAdmin.id, id, body);
  }

  @Post('subscriptions')
  @Public()
  @UseGuards(PlatformAdminGuard)
  setSubscriptionState(
    @Body(new ZodValidationPipe(setState)) body: z.infer<typeof setState>,
    @Req() request: { platformAdmin: { id: string } },
  ) {
    return this.billing.setSubscriptionState(
      request.platformAdmin.id,
      body.tenantId,
      body.state,
      body.reason,
    );
  }
}
