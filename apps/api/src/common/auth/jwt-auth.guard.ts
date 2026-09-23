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
