import { ExecutionContext, createParamDecorator } from '@nestjs/common';
import type { Grant } from '@pharmaet/contracts';

/**
 * Injects the grant the CapabilityGuard resolved for this request.
 *
 * Handlers take it as a parameter rather than reading ambient state, so that "does this
 * endpoint reach the whole tenant or one branch?" is visible in its signature — which is
 * the question that gets forgotten, and the forgetting is what lets a branch manager act
 * tenant-wide.
 */
export const CurrentGrant = createParamDecorator((_data: unknown, ctx: ExecutionContext): Grant => {
  const request = ctx.switchToHttp().getRequest();
  if (!request.grant) {
    throw new Error('CurrentGrant used on a route without @RequireCapability');
  }
  return request.grant as Grant;
});
