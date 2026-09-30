import {
  CanActivate,
  ExecutionContext,
  ForbiddenException,
  Injectable,
  UnauthorizedException,
} from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import { CONTRACT_VERSION_HEADER } from '@pharmaet/contracts';
import type { PlatformJwtPayload } from '../../modules/billing/platform-auth.service';

export const PLATFORM_ADMIN_ROUTE = 'platformAdminRoute';

/**
 * The platform console's session cookie (docs/engineering/security.md).
 *
 * HttpOnly, so no script on the page — injected or otherwise — can read the credential that
 * can suspend or deactivate a pharmacy. SameSite=Strict and scoped to `/api/platform`, so
 * no other site can make the browser send it and no other route ever sees it.
 */
export const PLATFORM_COOKIE = 'pe_platform';

/**
 * The header every console request carries (the contract version, ADR-009). A cross-site
 * form or image cannot set a custom header, and a cross-site script cannot pass preflight.
 */
export const CSRF_HEADER = CONTRACT_VERSION_HEADER;

export function readCookie(header: string | undefined, name: string): string | undefined {
  if (!header) return undefined;
  for (const part of header.split(';')) {
    const eq = part.indexOf('=');
    if (eq > 0 && part.slice(0, eq).trim() === name) {
      return decodeURIComponent(part.slice(eq + 1).trim());
    }
  }
  return undefined;
}

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
    const cookie = readCookie(request.headers?.cookie, PLATFORM_COOKIE);

    // A bearer token (scripts, the test suites) or the console's cookie.
    const token = header?.startsWith('Bearer ') ? header.slice(7) : cookie;
    if (!token) throw new UnauthorizedException('missing bearer token');

    // A cookie is sent by the browser on its own, which is what makes cross-site request
    // forgery possible at all. SameSite=Strict already stops it; requiring a header that
    // only our own script sets is the second lock. A bearer token needs neither — nothing
    // attaches it automatically.
    const unsafe = !['GET', 'HEAD', 'OPTIONS'].includes(request.method);
    if (token === cookie && unsafe && !request.headers?.[CSRF_HEADER]) {
      throw new ForbiddenException('missing request header');
    }

    let payload: PlatformJwtPayload;
    try {
      payload = await this.jwt.verifyAsync<PlatformJwtPayload>(token);
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
