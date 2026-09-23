import { CanActivate, ExecutionContext, Injectable, UnauthorizedException } from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import type { PlatformJwtPayload } from '../../modules/billing/platform-auth.service';

export const PLATFORM_ADMIN_ROUTE = 'platformAdminRoute';

/**
 * Authenticates a Platform Admin (docs/04 §5.1, BR-2.2).
 *
 * Applied per controller rather than globally, because a platform route is the exception in
 * this codebase and should look like one.
 *
 * It verifies `typ: 'platform'` explicitly. A tenant token would otherwise satisfy an
 * ordinary "is this a valid JWT?" check and reach routes that can suspend a pharmacy or read
 * across tenants — the single most valuable confusion an attacker could hope for, and the
 * easiest one to introduce by accident.
 */
@Injectable()
export class PlatformAdminGuard implements CanActivate {
  constructor(private readonly jwt: JwtService) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const request = context.switchToHttp().getRequest();
    const header: string | undefined = request.headers?.authorization;
    if (!header?.startsWith('Bearer ')) {
      throw new UnauthorizedException('missing bearer token');
    }

    let payload: PlatformJwtPayload;
    try {
      payload = await this.jwt.verifyAsync<PlatformJwtPayload>(header.slice(7));
    } catch {
      throw new UnauthorizedException('invalid or expired token');
    }

    if (payload.typ !== 'platform') {
      throw new UnauthorizedException('this endpoint requires a platform administrator');
    }

    request.platformAdmin = { id: payload.sub, email: payload.email };
    // No tenant scope is attached, on purpose: a platform route that wanted tenant-scoped
    // data would have to ask for it explicitly, through runAsPlatform, which logs.
    return true;
  }
}
