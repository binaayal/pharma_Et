import { CanActivate, ExecutionContext, ForbiddenException, Injectable } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import type { TenantScope } from '../db/tenant-scope';
import { CAPABILITY_KEY } from './capability.decorator';
import { type Capability, grantFor } from '@pharmaet/contracts';

/**
 * Enforces the FR-2 permission matrix (BR-2.1, AC-2.1).
 *
 * Authorization only. Tenant isolation is RLS's job and happens beneath this, independently
 * (docs/04 §8) — conflating the two produces policies nobody can read and permissions
 * nobody can test.
 *
 * The guard resolves `denied` outright and attaches the grant to the request for handlers
 * that need it. It deliberately does **not** try to resolve `branch` or `own` by itself:
 * the grant knows the role, but only the data knows which branch a record belongs to or
 * whose shift it was. A guard that guessed would be worse than one that abstains, because
 * it would look like enforcement.
 */
@Injectable()
export class CapabilityGuard implements CanActivate {
  constructor(private readonly reflector: Reflector) {}

  canActivate(context: ExecutionContext): boolean {
    const capability = this.reflector.getAllAndOverride<Capability>(CAPABILITY_KEY, [
      context.getHandler(),
      context.getClass(),
    ]);
    if (!capability) return true;

    const request = context.switchToHttp().getRequest();
    const scope: TenantScope | undefined = request.scope;
    if (!scope) throw new ForbiddenException('no tenant scope on this request');

    const grant = grantFor(scope.role, capability);
    if (grant === 'denied') {
      throw new ForbiddenException(`role "${scope.role}" may not ${capability}`);
    }

    request.grant = grant;
    return true;
  }
}
