import {
  BadRequestException,
  Body,
  Controller,
  Get,
  HttpCode,
  Ip,
  Param,
  ParseUUIDPipe,
  Post,
  Query,
  Req,
  Res,
  UploadedFile,
  UseGuards,
  UseInterceptors,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { FileInterceptor } from '@nestjs/platform-express';
import type { Response } from 'express';
import { z } from 'zod';
import { AllowWhenSuspended } from '../../common/auth/allow-when-suspended.decorator';
import { RequireCapability } from '../../common/auth/capability.decorator';
import { CurrentScope } from '../../common/auth/current-scope.decorator';
import { PLATFORM_COOKIE, PlatformAdminGuard } from '../../common/auth/platform-admin.guard';
import { Public } from '../../common/auth/public.decorator';
import type { TenantScope } from '../../common/db/tenant-scope';
import { ZodValidationPipe } from '../../common/http/zod-validation.pipe';
import { BillingService } from './billing.service';
import { PlatformAuthService } from './platform-auth.service';
import { SignupService } from './signup.service';

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
  /** Delete the screenshot once decided (ADR-028). The console sends true by default. */
  deleteImage: z.boolean().optional(),
  reason: z.string().max(500).optional(),
  periodDays: z.number().int().min(1).max(366).optional(),
});

/**
 * A name, as a person types one. No links and no markup: the only reason a pharmacy name
 * contains `http://` or `<` is that a bot is using our queue to deliver something to the
 * operator who reads it.
 */
const plainName = (min: number, max: number) =>
  z
    .string()
    .trim()
    .min(min)
    .max(max)
    .refine((v) => !/(https?:\/\/|www\.|<|>)/i.test(v), 'letters, numbers and punctuation only');

const signupRequest = z.object({
  pharmacyName: plainName(2, 200),
  ownerName: plainName(2, 120),
  phone: z
    .string()
    .trim()
    .min(9)
    .max(20)
    .regex(/^\+?[\d\s()-]+$/, 'digits only'),
  city: plainName(2, 80),
  branchBand: z.enum(['1', '2-3', '4+']),
  /**
   * Honeypot. The app never sends it and a person never sees it; a bot filling every field
   * it can find does. A filled one is answered exactly like a success and stored nowhere, so
   * the bot learns nothing about what gave it away.
   */
  website: z.string().max(500).optional(),
});

const decideSignup = z.discriminatedUnion('accept', [
  z.object({
    accept: z.literal(true),
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
    ownerPin: z.string().regex(/^\d{4,8}$/, 'a PIN is 4 to 8 digits'),
  }),
  z.object({ accept: z.literal(false), reason: z.string().trim().min(3).max(500) }),
]);

const setState = z.object({
  tenantId: z.string().uuid(),
  state: z.enum(['active', 'suspended']),
  reason: z.string().max(500).optional(),
});

const deactivate = z.object({
  reason: z.string().trim().min(10).max(500),
});

const reactivate = z.object({
  note: z.string().trim().max(500).optional(),
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
  // One file, a few small fields. Multer's defaults are unlimited file and field counts,
  // which is a free way to make the server buffer as much as a client cares to send.
  @UseInterceptors(
    FileInterceptor('screenshot', {
      limits: { fileSize: 8 * 1024 * 1024, files: 1, fields: 5, fieldSize: 2048, parts: 6 },
    }),
  )
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
/**
 * "Request an account" (ADR-022). Anonymous by necessity — the person asking has no account
 * yet — so it can only ever create a request that a human then reviews.
 */
@Controller('signup-requests')
export class SignupController {
  constructor(private readonly signups: SignupService) {}

  @Public()
  @Post()
  submit(@Body(new ZodValidationPipe(signupRequest)) body: z.infer<typeof signupRequest>) {
    const { website, ...request } = body;
    if (website?.trim()) return this.signups.decoy();
    return this.signups.submit(request);
  }
}

@Controller('platform')
export class PlatformController {
  constructor(
    private readonly billing: BillingService,
    private readonly auth: PlatformAuthService,
    private readonly signups: SignupService,
    private readonly config: ConfigService,
  ) {}

  @Get('signup-requests')
  @Public()
  @UseGuards(PlatformAdminGuard)
  signupRequests(@Query('status') status?: string) {
    const known = ['pending', 'approved', 'rejected'] as const;
    return this.signups.list(known.find((k) => k === status));
  }

  @Post('signup-requests/:id/decide')
  @Public()
  @UseGuards(PlatformAdminGuard)
  decideSignup(
    @Param('id', new ParseUUIDPipe()) id: string,
    @Body(new ZodValidationPipe(decideSignup)) body: z.infer<typeof decideSignup>,
    @Req() request: { platformAdmin: { id: string } },
  ) {
    return this.signups.decide(request.platformAdmin.id, id, body);
  }

  @Get('tenants/:id')
  @Public()
  @UseGuards(PlatformAdminGuard)
  tenant(@Param('id', new ParseUUIDPipe()) id: string) {
    return this.billing.tenantDetail(id);
  }

  /**
   * Signs a Platform Admin in, and sets the console's HttpOnly session cookie.
   *
   * The token is also in the body, for scripts and the test suites that send it as a bearer.
   * The console ignores it and relies on the cookie, so no script on the page ever holds
   * the credential that can deactivate a pharmacy.
   */
  @Public()
  @Post('login')
  async login(
    @Body(new ZodValidationPipe(platformLogin)) body: z.infer<typeof platformLogin>,
    @Ip() sourceIp: string,
    @Res({ passthrough: true }) res: Response,
  ) {
    const result = await this.auth.login(body.email, body.password, sourceIp);
    res.cookie(PLATFORM_COOKIE, result.accessToken, {
      httpOnly: true,
      sameSite: 'strict',
      secure: this.secureCookies,
      path: '/api/platform',
      maxAge: this.auth.sessionSeconds * 1000,
    });
    return result;
  }

  /** Clears the console's cookie. Public, so an expired session can still sign out cleanly. */
  @Public()
  @Post('logout')
  @HttpCode(204)
  logout(@Res({ passthrough: true }) res: Response): void {
    res.clearCookie(PLATFORM_COOKIE, {
      httpOnly: true,
      sameSite: 'strict',
      secure: this.secureCookies,
      path: '/api/platform',
    });
  }

  /** Who is signed in — how the console learns it has a session it cannot read. */
  @Get('me')
  @Public()
  @UseGuards(PlatformAdminGuard)
  me(@Req() request: { platformAdmin: { id: string; email: string } }) {
    return request.platformAdmin;
  }

  private get secureCookies(): boolean {
    const env = this.config.get<string>('NODE_ENV');
    return env === 'production' || env === 'staging';
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

  /** ADR-025: stop serving a pharmacy that broke its terms. Every request it makes is refused. */
  @Post('tenants/:id/deactivate')
  @Public()
  @UseGuards(PlatformAdminGuard)
  deactivate(
    @Param('id', new ParseUUIDPipe()) id: string,
    @Body(new ZodValidationPipe(deactivate)) body: z.infer<typeof deactivate>,
    @Req() request: { platformAdmin: { id: string } },
  ) {
    return this.billing.deactivateTenant(request.platformAdmin.id, id, body.reason);
  }

  @Post('tenants/:id/reactivate')
  @Public()
  @UseGuards(PlatformAdminGuard)
  reactivate(
    @Param('id', new ParseUUIDPipe()) id: string,
    @Body(new ZodValidationPipe(reactivate)) body: z.infer<typeof reactivate>,
    @Req() request: { platformAdmin: { id: string } },
  ) {
    return this.billing.reactivateTenant(request.platformAdmin.id, id, body.note);
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
  async image(@Param('id', new ParseUUIDPipe()) id: string, @Res() res: Response) {
    const { buffer, contentType } = await this.billing.proofImage(id);
    // Never cached: a payment screenshot is somebody's bank app, and it has no business
    // sitting in a proxy or a browser cache after the tab closes.
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('Content-Type', contentType);
    res.send(buffer);
  }

  /** Frees the space of every decided screenshot still stored (ADR-028). */
  @Get('payment-proofs/decided-images')
  @Public()
  @UseGuards(PlatformAdminGuard)
  decidedImages() {
    return this.billing.decidedProofsWithImages();
  }

  @Post('payment-proofs/purge-decided-images')
  @Public()
  @UseGuards(PlatformAdminGuard)
  purgeDecidedImages(@Req() request: { platformAdmin: { id: string } }) {
    return this.billing.purgeDecidedImages(request.platformAdmin.id);
  }

  @Post('payment-proofs/:id/decide')
  @Public()
  @UseGuards(PlatformAdminGuard)
  decide(
    @Param('id', new ParseUUIDPipe()) id: string,
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
