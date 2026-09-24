import { Injectable, UnauthorizedException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { JwtService } from '@nestjs/jwt';
import type { LoginRequest, LoginResponse, RefreshRequest } from '@pharmaet/contracts';
import * as argon2 from 'argon2';
import { ScopedDbService } from '../../common/db/scoped-db.service';
import { AppUser, Tenant, UserBranch } from '../../entities';
import type { JwtPayload } from '../../common/auth/jwt-payload';
import { LoginThrottleService } from './login-throttle.service';

@Injectable()
export class AuthService {
  constructor(
    private readonly db: ScopedDbService,
    private readonly jwt: JwtService,
    private readonly config: ConfigService,
    private readonly throttle: LoginThrottleService,
  ) {}

  /**
   * Online login. From here the terminal caches a derived verifier and keeps working through
   * the offline window (BR-2.3) — offline PIN validation happens on the device, against that
   * cache, and never reaches this method.
   */
  async login(request: LoginRequest, sourceIp = 'unknown'): Promise<LoginResponse> {
    // Checked BEFORE any lookup, and identically whatever was typed. Throttling only
    // existing accounts would make "throttled" mean "this user is real" — an enumeration
    // oracle that undoes the uniform error message below (NFR-4.2, ADR-017).
    await this.throttle.assertNotThrottled(request.tenantCode, request.username, sourceIp);

    try {
      const response = await this.attemptLogin(request);
      await this.throttle.record(request.tenantCode, request.username, sourceIp, true);
      return response;
    } catch (error) {
      await this.throttle.record(request.tenantCode, request.username, sourceIp, false);
      throw error;
    }
  }

  private async attemptLogin(request: LoginRequest): Promise<LoginResponse> {
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

  /**
   * Exchanges a refresh token for a new session (docs/04 §9, ADR-019).
   *
   * Two properties make this safe, and both are the point rather than defence in depth.
   *
   * **It accepts only a refresh token.** The `typ` claim is checked explicitly. Without that
   * check an access token would extend itself indefinitely, which turns a fifteen-minute
   * credential into a permanent one — the mirror image of the defect where a refresh token
   * authenticated API calls.
   *
   * **It re-reads the user.** The new session's role and branches come from the database,
   * not from the old token's claims. A cashier dismissed this morning cannot refresh their
   * way through the afternoon, and a role changed at lunchtime takes effect now rather than
   * whenever the offline window happens to end. Copying the claims forward would let a token
   * outlive the authority it describes, which is exactly the staleness BR-2.3 bounds.
   */
  async refresh(request: RefreshRequest): Promise<LoginResponse> {
    let payload: JwtPayload;
    try {
      payload = await this.jwt.verifyAsync<JwtPayload>(request.refreshToken);
    } catch {
      // Covers expired as well as forged. Both mean the same thing to the terminal: sign in.
      throw new UnauthorizedException('invalid or expired refresh token');
    }

    if (payload.typ !== 'refresh' || !payload.tid) {
      throw new UnauthorizedException('not a refresh token');
    }

    const scope = {
      tenantId: payload.tid,
      userId: payload.sub,
      role: 'owner' as const,
      branchIds: [],
    };

    const found = await this.db.runInScope(scope, async (em) => {
      // An explicit `IS NULL` predicate, matching the login path. A `findOne` with
      // `deletedAt: null` did not exclude the soft-deleted row here, and the failure mode is
      // the worst kind: it looks correct, and it silently lets a dismissed user refresh.
      const user = await em
        .getRepository(AppUser)
        .createQueryBuilder('u')
        .where('u.id = :id', { id: payload.sub })
        .andWhere('u.deleted_at IS NULL')
        .getOne();
      if (!user) return null;
      const branches = await em.getRepository(UserBranch).find({ where: { userId: user.id } });
      return { user, branchIds: branches.map((b) => b.branchId) };
    });

    // Deactivated between login and refresh. The token is still cryptographically perfect,
    // and that is precisely why the check is a database read rather than a signature check.
    if (!found) throw new UnauthorizedException('invalid or expired refresh token');

    return this.issueTokens(
      payload.tid,
      found.user,
      found.branchIds,
      request.terminalId,
    );
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

    // Both are stamped with their purpose. The refresh token was already marked; the access
    // token was not, which left "no marking" meaning "access" by omission rather than by
    // decision — and a guard cannot enforce a rule that nothing states.
    const [accessToken, refreshToken] = await Promise.all([
      this.jwt.signAsync({ ...payload, typ: 'access' }, { expiresIn: accessTtl }),
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
