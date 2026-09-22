import { Injectable, UnauthorizedException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { JwtService } from '@nestjs/jwt';
import type { LoginRequest, LoginResponse } from '@pharmaet/contracts';
import * as argon2 from 'argon2';
import { ScopedDbService } from '../../common/db/scoped-db.service';
import { AppUser, Tenant, UserBranch } from '../../entities';
import type { JwtPayload } from '../../common/auth/jwt-payload';

@Injectable()
export class AuthService {
  constructor(
    private readonly db: ScopedDbService,
    private readonly jwt: JwtService,
    private readonly config: ConfigService,
  ) {}

  /**
   * Online login. From here the terminal caches a derived verifier and keeps working through
   * the offline window (BR-2.3) — offline PIN validation happens on the device, against that
   * cache, and never reaches this method.
   */
  async login(request: LoginRequest): Promise<LoginResponse> {
    // Authentication is inherently pre-tenant: we do not yet know which tenant to scope to,
    // so resolving the tenant from its code is an explicit, logged platform-scope read
    // (BR-2.2) rather than an accidental unscoped query.
    const tenant = await this.db.runAsPlatform('resolve tenant for login', (em) =>
      em.getRepository(Tenant).findOne({
        where: { code: request.tenantCode.toLowerCase(), deletedAt: null as never },
      }),
    );

    // Same rejection for an unknown tenant, unknown user, and wrong secret. Distinguishing
    // them tells an attacker which pharmacy codes and usernames are real.
    if (!tenant) throw new UnauthorizedException('invalid credentials');

    const scope = { tenantId: tenant.id, userId: tenant.id, role: 'owner' as const, branchIds: [] };

    const found = await this.db.runInScope(scope, async (em) => {
      const user = await em
        .getRepository(AppUser)
        .createQueryBuilder('u')
        .where('lower(u.username) = lower(:username)', { username: request.username })
        .andWhere('u.deleted_at IS NULL')
        .getOne();
      if (!user) return null;

      const branches = await em.getRepository(UserBranch).find({ where: { userId: user.id } });
      return { user, branchIds: branches.map((b) => b.branchId) };
    });

    if (!found) throw new UnauthorizedException('invalid credentials');

    // A user may hold both a counter PIN and a back-office password, so the secret is
    // checked against each candidate rather than against whichever happens to be set first.
    // Both are verified even when the first matches: bailing early would make the response
    // time leak which credential kind an account has.
    const candidates = [found.user.pinHash, found.user.passwordHash].filter(
      (hash): hash is string => Boolean(hash),
    );
    const results = await Promise.all(
      candidates.map((hash) => argon2.verify(hash, request.secret).catch(() => false)),
    );
    if (!results.some(Boolean)) {
      throw new UnauthorizedException('invalid credentials');
    }

    return this.issueTokens(tenant.id, found.user, found.branchIds, request.terminalId);
  }

  private async issueTokens(
    tenantId: string,
    user: AppUser,
    branchIds: string[],
    terminalId: string,
  ): Promise<LoginResponse> {
    const payload: JwtPayload = {
      sub: user.id,
      tid: tenantId,
      role: user.role,
      branches: branchIds,
      terminal: terminalId,
    };

    const accessTtl = this.config.get<string>('JWT_ACCESS_TTL', '15m');
    const refreshTtl = this.config.get<string>('JWT_REFRESH_TTL', '30d');
    const offlineHours = this.config.get<number>('OFFLINE_AUTH_TTL_HOURS', 168);

    const [accessToken, refreshToken] = await Promise.all([
      this.jwt.signAsync(payload, { expiresIn: accessTtl }),
      this.jwt.signAsync({ ...payload, typ: 'refresh' }, { expiresIn: refreshTtl }),
    ]);

    return {
      accessToken,
      refreshToken,
      expiresAt: new Date(Date.now() + parseTtlMs(accessTtl)).toISOString(),
      scope: {
        userId: user.id,
        tenantId,
        role: user.role,
        branchIds,
        displayName: user.displayName,
      },
      // How long the device may keep authenticating against its cached verifier. Sized past
      // the 72h guaranteed window (NFR-1.1) so a terminal that is offline for the full
      // supported period is not locked out of its own till at the end of it.
      offlineValidUntil: new Date(Date.now() + offlineHours * 3600_000).toISOString(),
    };
  }
}

function parseTtlMs(ttl: string): number {
  const match = /^(\d+)([smhd])$/.exec(ttl);
  if (!match) throw new Error(`unparseable TTL: ${ttl}`);
  const units: Record<string, number> = { s: 1000, m: 60_000, h: 3_600_000, d: 86_400_000 };
  return Number(match[1]) * units[match[2]];
}
