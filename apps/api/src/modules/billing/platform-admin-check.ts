import { Injectable, Logger, OnApplicationBootstrap } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import * as argon2 from 'argon2';
import { ScopedDbService } from '../../common/db/scoped-db.service';
import { DEV_PLATFORM_PASSWORD } from '../../config/dev-credentials';
import { PlatformAdmin } from '../../entities';

/**
 * At boot, in staging and production: does any live Platform Admin still answer to the
 * development seed's password?
 *
 * That password is in a public repository, and staging was seeded with it. The account can
 * suspend, deactivate and onboard every pharmacy. Production refuses to start; staging says
 * so loudly on every boot until `entrypoint create-admin` retires it.
 */
@Injectable()
export class PlatformAdminCheck implements OnApplicationBootstrap {
  private readonly logger = new Logger('security');

  constructor(
    private readonly db: ScopedDbService,
    private readonly config: ConfigService,
  ) {}

  async onApplicationBootstrap(): Promise<void> {
    const env = this.config.get<string>('NODE_ENV');
    if (env !== 'production' && env !== 'staging') return;

    const admins = await this.db.runAsPlatform('boot check: seeded platform credentials', (em) =>
      em
        .getRepository(PlatformAdmin)
        .createQueryBuilder('a')
        .where('a.deleted_at IS NULL')
        .getMany(),
    );
    const exposed: string[] = [];
    for (const admin of admins) {
      if (await argon2.verify(admin.passwordHash, DEV_PLATFORM_PASSWORD).catch(() => false)) {
        exposed.push(admin.email);
      }
    }
    if (!exposed.length) return;

    const message =
      `platform admin(s) ${exposed.join(', ')} still use the PUBLIC development password. ` +
      `Run: entrypoint create-admin with RETIRE_DEV_ADMIN=yes (docs/engineering/security.md).`;
    if (env === 'production') throw new Error(`refusing to start: ${message}`);
    this.logger.error(`SECURITY: ${message}`);
  }
}
