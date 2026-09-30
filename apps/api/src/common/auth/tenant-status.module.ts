import { Global, Module } from '@nestjs/common';
import { TenantStatusService } from './tenant-status';

/**
 * Global, so the guard, sign-in and the platform console share ONE cache — the console's
 * `forget` must reach the same instance the guard reads, or a deactivation would wait out
 * the cache on the very server that performed it.
 */
@Global()
@Module({
  providers: [TenantStatusService],
  exports: [TenantStatusService],
})
export class TenantStatusModule {}
