import { CanActivate, ExecutionContext, ForbiddenException, Injectable } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import type { UserRole } from '../../entities';
import { ROLES_KEY } from './roles.decorator';

/**
 * Authorization — what a role may do (FR-2 permission matrix).
 *
 * Deliberately separate from RLS. RLS answers "which tenant's rows exist for this request";
 * it does not and should not express "may a cashier change a price" (docs/04 §8). Conflating
 * the two produces policies nobody can read and permissions nobody can test.
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
