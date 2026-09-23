import {
  CanActivate,
  ExecutionContext,
  HttpException,
  HttpStatus,
  Injectable,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { ScopedDbService } from '../db/scoped-db.service';
import type { TenantScope } from '../db/tenant-scope';
import { Subscription } from '../../entities';
import { ALLOW_WHEN_SUSPENDED } from './allow-when-suspended.decorator';
import { IS_PUBLIC_KEY } from './public.decorator';

/**
 * Enforces BR-1.3 as interpreted by ADR-016: a suspended tenant loses **management
 * writes**, and nothing else.
 *
 * What it deliberately does not block, and why:
 *
 *   - **`/sync/push`.** Those operations are records of things that already happened —
 *     money taken, receipts printed, stock gone from the shelf. Refusing them leaves them in
 *     an outbox that retries forever until the device is replaced, at which point a
 *     pharmacy's real trading records are destroyed over a billing dispute. Vision §6 puts
 *     "never lose a regulated record" second only to "the daily loop never breaks".
 *   - **`/sync/pull` and reports.** A terminal on stale prices overcharges customers who are
 *     no party to our billing relationship.
 *   - **Submitting a payment proof.** Blocking the one action that ends the suspension would
 *     be self-defeating.
 *
 * Read-only therefore means: the pharmacy cannot expand its use of the platform, but it
 * never loses a record and never overcharges a customer.
 *
 * `402 Payment Required`, not `403`: the client must be able to tell "you may not" from
 * "this is a billing matter", because only the second should send an owner to a payment
 * screen.
 */
@Injectable()
export class SubscriptionGuard implements CanActivate {
  constructor(
    private readonly reflector: Reflector,
    private readonly db: ScopedDbService,
  ) {}

  /** Verbs that change something. GET and HEAD are never blocked. */
  private static readonly WRITE_METHODS = new Set(['POST', 'PUT', 'PATCH', 'DELETE']);

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const isPublic = this.reflector.getAllAndOverride<boolean>(IS_PUBLIC_KEY, [
      context.getHandler(),
      context.getClass(),
    ]);
    if (isPublic) return true;

    const request = context.switchToHttp().getRequest();
    const scope: TenantScope | undefined = request.scope;
    // No tenant scope means a platform-admin route; billing state is not its concern.
    if (!scope) return true;

    if (!SubscriptionGuard.WRITE_METHODS.has(request.method)) return true;

    const exempt = this.reflector.getAllAndOverride<boolean>(ALLOW_WHEN_SUSPENDED, [
      context.getHandler(),
      context.getClass(),
    ]);
    if (exempt) return true;

    const subscription = await this.db.runInScope(scope, (em) =>
      em.getRepository(Subscription).findOne({ where: { tenantId: scope.tenantId } }),
    );

    // A tenant with no subscription row predates billing or was created outside the
    // onboarding flow. Failing open here is deliberate: refusing writes to a pharmacy
    // because of a bookkeeping gap on our side would be our error charged to them.
    if (!subscription) return true;

    if (subscription.state === 'active' || subscription.state === 'pending') return true;

    throw new HttpException(
      {
        statusCode: HttpStatus.PAYMENT_REQUIRED,
        error: 'Subscription suspended',
        message:
          subscription.suspendedReason ??
          'This pharmacy’s subscription is suspended. Sales already recorded on your ' +
            'terminals will still sync and your reports are still available; changes to ' +
            'branches, staff, products and prices resume once payment is verified.',
        subscriptionState: subscription.state,
      },
      HttpStatus.PAYMENT_REQUIRED,
    );
  }
}
