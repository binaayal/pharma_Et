import { CanActivate, ExecutionContext, Injectable } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import type { TenantScope } from '../db/tenant-scope';
import { IS_PUBLIC_KEY } from './public.decorator';
import { TenantStatusService } from './tenant-status';

/**
 * Refuses every request from a deactivated pharmacy (ADR-025).
 *
 * Every request, reads and `/sync/push` included — that is the difference from a suspended
 * subscription (ADR-016), which blocks only management writes. A suspension is a billing
 * matter between us and a customer in good standing; a deactivation is the platform ceasing
 * to serve an account that broke its terms.
 *
 * Refusing a push loses nothing. The terminal keeps every unacknowledged operation in its
 * outbox (`SyncService`: "it NEVER deletes an operation the server did not acknowledge"), so
 * if the account is reactivated the backlog uploads, and if it is not, the pharmacy's
 * records are still on its own devices.
 *
 * Registered straight after `JwtAuthGuard`, so a deactivated tenant is told that — not about
 * a permission or a subscription it would otherwise have been refused for.
 */
@Injectable()
export class TenantStatusGuard implements CanActivate {
  constructor(
    private readonly reflector: Reflector,
    private readonly status: TenantStatusService,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const isPublic = this.reflector.getAllAndOverride<boolean>(IS_PUBLIC_KEY, [
      context.getHandler(),
      context.getClass(),
    ]);
    if (isPublic) return true;

    const scope: TenantScope | undefined = context.switchToHttp().getRequest().scope;
    // No tenant scope is a platform route; it has its own guard.
    if (!scope) return true;

    await this.status.assertActive(scope.tenantId, scope.userId);
    return true;
  }
}
