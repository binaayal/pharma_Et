import { CanActivate, ExecutionContext, ForbiddenException, Injectable } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import type { UserRole } from '../../entities';
import { ROLES_KEY } from './roles.decorator';

/**
 * A coarse role check, kept for routes the FR-2 matrix does not cover.
 *
 * **Prefer `@RequireCapability`.** A role list has to be re-derived at every handler and
 * drifts from the SRS one endpoint at a time; a capability is looked up in the one table
 * the matrix tests exercise cell by cell. This guard remains for the platform-admin surface
 * (FR-1 billing, payment verification), whose identity sits outside tenant scope entirely
 * and so has no row in the matrix.
 *
 * Both are separate from RLS. RLS answers "which tenant's rows exist for this request"; it
 * does not and should not express "may a cashier change a price" (docs/04 §8). Conflating
 * them produces policies nobody can read and permissions nobody can test.
 */
@Injectable()
export class RolesGuard implements CanActivate {
  constructor(private readonly reflector: Reflector) {}

  canActivate(context: ExecutionContext): boolean {
    const required = this.reflector.getAllAndOverride<UserRole[]>(ROLES_KEY, [
      context.getHandler(),
      context.getClass(),
    ]);
    if (!required?.length) return true;

    const request = context.switchToHttp().getRequest();
    const role: UserRole | undefined = request.scope?.role;
    if (!role || !required.includes(role)) {
      throw new ForbiddenException(`requires one of: ${required.join(', ')}`);
    }
    return true;
  }
}
