import { CanActivate, ExecutionContext, Injectable, UnauthorizedException } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { JwtService } from '@nestjs/jwt';
import type { TenantScope } from '../db/tenant-scope';
import { IS_PUBLIC_KEY } from './public.decorator';
import type { JwtPayload } from './jwt-payload';

/**
 * Verifies the access token and turns its claims into the request's TenantScope.
 *
 * Applied globally: a route is authenticated unless it opts out with @Public(). Defaulting
 * the other way means a new controller is unprotected until somebody remembers, and in a
 * multi-tenant system that omission is a data breach rather than a bug.
 */
@Injectable()
export class JwtAuthGuard implements CanActivate {
  constructor(
    private readonly jwt: JwtService,
    private readonly reflector: Reflector,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const isPublic = this.reflector.getAllAndOverride<boolean>(IS_PUBLIC_KEY, [
      context.getHandler(),
      context.getClass(),
    ]);
    if (isPublic) return true;

    const request = context.switchToHttp().getRequest();
    const header: string | undefined = request.headers?.authorization;
    if (!header?.startsWith('Bearer ')) {
      throw new UnauthorizedException('missing bearer token');
    }

    let payload: JwtPayload;
    try {
      payload = await this.jwt.verifyAsync<JwtPayload>(header.slice(7));
    } catch {
      throw new UnauthorizedException('invalid or expired token');
    }

    // Only an access token may authenticate an API call.
    //
    // Without this, the refresh token is a second, equivalent credential with a **thirty-day**
    // life, and the fifteen-minute access TTL protects nothing at all: anyone holding the
    // refresh token has a month of full access at the user's role. Both are stored on the
    // device together, so a compromise that yields one yields the other.
    //
    // A signature check cannot catch this. It answers "did we issue this?" — and we did. The
    // question that matters is "did we issue it *for this purpose*", which only a claim can
    // answer. Tokens minted before this claim existed carry no `typ` and are accepted, so
    // adding it does not sign every terminal out.
    if (payload.typ !== undefined && payload.typ !== 'access') {
      throw new UnauthorizedException('this is not an access token');
    }

    // A token with no tenant is a platform-admin token (see PlatformJwtPayload). It is
    // structurally incapable of naming a pharmacy, so it is refused here rather than allowed
    // to travel on as an undefined scope.
    //
    // This is not belt-and-braces. Without it the request reaches `SET LOCAL
    // app.current_tenant` holding `undefined` and fails there — which happens to deny the
    // data, but denies it by crashing, as a 500. A boundary enforced by a downstream
    // exception is a boundary that the next raw query added to a controller quietly removes,
    // because that query would interpolate `undefined` instead of throwing. BR-2.2 says a
    // platform administrator has no default access to tenant data; this is where that is
    // actually said.
    if (!payload.tid) {
      throw new UnauthorizedException('this endpoint requires a tenant session');
    }

    const scope: TenantScope = {
      tenantId: payload.tid,
      userId: payload.sub,
      role: payload.role,
      branchIds: payload.branches ?? [],
    };
    request.scope = scope;
    request.terminalId = payload.terminal;
    return true;
  }
}
