import { Injectable, UnauthorizedException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { JwtService } from '@nestjs/jwt';
import * as argon2 from 'argon2';
import { ScopedDbService } from '../../common/db/scoped-db.service';
import { PlatformAdmin } from '../../entities';

export interface PlatformJwtPayload {
  sub: string;
  /**
   * The discriminator that makes a platform token unmistakable.
   *
   * A tenant token carries `tid`; this carries `typ: 'platform'` and no tenant at all. Two
   * shapes that cannot be confused for one another is what keeps "a Platform Admin has no
   * default access to tenant data" (BR-2.2) structural rather than careful — there is no
   * token that is both, so there is no path that mistakes one for the other.
   */
  typ: 'platform';
  email: string;
}

@Injectable()
export class PlatformAuthService {
  constructor(
    private readonly db: ScopedDbService,
    private readonly jwt: JwtService,
    private readonly config: ConfigService,
  ) {}

  async login(email: string, password: string) {
    const admin = await this.db.runAsPlatform('resolve platform admin for login', (em) =>
      em
        .getRepository(PlatformAdmin)
        .createQueryBuilder('a')
        .where('lower(a.email) = lower(:email)', { email })
        .andWhere('a.deleted_at IS NULL')
        .getOne(),
    );

    // Same rejection either way: distinguishing "no such admin" from "wrong password"
    // enumerates our own staff for anyone who asks.
    if (!admin || !(await argon2.verify(admin.passwordHash, password).catch(() => false))) {
      throw new UnauthorizedException('invalid credentials');
    }

    const payload: PlatformJwtPayload = { sub: admin.id, typ: 'platform', email: admin.email };
    return {
      accessToken: await this.jwt.signAsync(payload, {
        // Deliberately shorter than a tenant session. This token can suspend a pharmacy;
        // it should not sit in a browser overnight.
        expiresIn: this.config.get<string>('PLATFORM_TOKEN_TTL', '2h'),
      }),
      admin: { id: admin.id, email: admin.email, displayName: admin.displayName },
    };
  }
}
