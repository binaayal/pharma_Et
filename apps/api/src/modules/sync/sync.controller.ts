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
import { CurrentScope } from '../../common/auth/current-scope.decorator';
import type { TenantScope } from '../../common/db/tenant-scope';
import { ZodValidationPipe } from '../../common/http/zod-validation.pipe';
import { SyncService } from './sync.service';

@Controller('sync')
export class SyncController {
  constructor(private readonly sync: SyncService) {}

  @Post('push')
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
