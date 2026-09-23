import { BadRequestException, Body, Controller, Get, Headers, Post, Query } from '@nestjs/common';
import {
  CONTRACT_VERSION_HEADER,
  SUPPORTED_CONTRACT_VERSIONS,
  type PullResponse,
  type PushRequest,
  type PushResponse,
  pullQuery,
  pushRequest,
} from '@pharmaet/contracts';
import { AllowWhenSuspended } from '../../common/auth/allow-when-suspended.decorator';
import { CurrentScope } from '../../common/auth/current-scope.decorator';
import type { TenantScope } from '../../common/db/tenant-scope';
import { ZodValidationPipe } from '../../common/http/zod-validation.pipe';
import { SyncService } from './sync.service';

@Controller('sync')
export class SyncController {
  constructor(private readonly sync: SyncService) {}

  /**
   * **Allowed while the subscription is suspended (ADR-016).**
   *
   * These operations are records of things that already happened — money taken, receipts
   * printed, stock gone from the shelf. Refusing them leaves them in an outbox that retries
   * forever until the device is replaced, at which point a pharmacy's real trading records
   * are destroyed over a billing dispute. Vision §6 puts "never lose a regulated record"
   * second only to "the daily loop never breaks", and a system that deletes a customer's
   * books when they are late paying honours neither.
   *
   * Suspension's lever is the loss of the console and of management writes, never the
   * destruction of data we do not own.
   */
  @Post('push')
  @AllowWhenSuspended()
  push(
    @CurrentScope() scope: TenantScope,
    @Body(new ZodValidationPipe(pushRequest)) body: PushRequest,
    @Headers(CONTRACT_VERSION_HEADER) contractVersion?: string,
  ): Promise<PushResponse> {
    this.assertSupportedContract(contractVersion);
    return this.sync.push(scope, body);
  }

  @Get('pull')
  pull(
    @CurrentScope() scope: TenantScope,
    @Query(new ZodValidationPipe(pullQuery)) query: unknown,
    @Headers(CONTRACT_VERSION_HEADER) contractVersion?: string,
  ): Promise<PullResponse> {
    this.assertSupportedContract(contractVersion);
    return this.sync.pull(scope, query as never);
  }

  /**
   * A terminal may have been offline for days and still speak an older contract, so the
   * server accepts every version in its support window, not just the current one (ADR-009).
   * An unsupported version is refused loudly here rather than misparsed downstream — half-
   * understanding an envelope is how transactions get silently mangled.
   */
  private assertSupportedContract(version?: string): void {
    if (!version) return; // absent means "current"; tolerated for the dashboard and tests
    if (!(SUPPORTED_CONTRACT_VERSIONS as readonly string[]).includes(version)) {
      throw new BadRequestException(
        `unsupported contract version ${version}; this server serves ${SUPPORTED_CONTRACT_VERSIONS.join(', ')}`,
      );
    }
  }
}
