import { ExecutionContext, createParamDecorator } from '@nestjs/common';
import type { TenantScope } from '../db/tenant-scope';

/**
 * Injects the authenticated request's TenantScope.
 *
 * Handlers take the scope as a parameter rather than reading it from ambient state, so that
 * "which tenant is this running as?" is visible in the signature of anything that touches
 * data — and impossible to forget to pass to ScopedDbService.
 */
export const CurrentScope = createParamDecorator(
  (_data: unknown, ctx: ExecutionContext): TenantScope => {
    const request = ctx.switchToHttp().getRequest();
    if (!request.scope) {
      throw new Error('CurrentScope used on a route without JwtAuthGuard');
    }
    return request.scope as TenantScope;
  },
);
