import 'reflect-metadata';
import * as argon2 from 'argon2';
import * as dotenv from 'dotenv';
import { DataSource } from 'typeorm';
import { uuidv7 } from 'uuidv7';

dotenv.config();

/**
 * Creates a Platform Admin, or rotates one's password — the operator's way in, in every
 * environment the seed must not touch (docs/engineering/security.md).
 *
 *   PLATFORM_ADMIN_EMAIL=you@example.com PLATFORM_ADMIN_PASSWORD='…' \
 *   PLATFORM_ADMIN_NAME='Your Name' RETIRE_DEV_ADMIN=yes  entrypoint create-admin
 *
 * Not an endpoint, on purpose: an API that mints platform identities is an escalation path
 * however carefully it is guarded (ADR-022's reasoning). Whoever runs this already holds the
 * database owner's credentials.
 *
 * RETIRE_DEV_ADMIN=yes soft-deletes the seed's `admin@pharmaet.local`, whose password is in
 * this public repository. Staging was seeded with it.
 */
async function main(): Promise<void> {
  const email = process.env.PLATFORM_ADMIN_EMAIL?.trim().toLowerCase();
  const password = process.env.PLATFORM_ADMIN_PASSWORD ?? '';
  const name = process.env.PLATFORM_ADMIN_NAME?.trim() || 'Platform Admin';

  if (!email || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
    throw new Error('PLATFORM_ADMIN_EMAIL must be an email address');
  }
  // Long rather than complex (NIST SP 800-63B): this account can deactivate every pharmacy.
  if (password.length < 14) {
    throw new Error('PLATFORM_ADMIN_PASSWORD must be at least 14 characters');
  }
  if (password === 'platform-dev-password') {
    throw new Error('that is the development seed password, which is public');
  }

  const dataSource = new DataSource({ type: 'postgres', url: process.env.DATABASE_URL });
  await dataSource.initialize();
  try {
    const hash = await argon2.hash(password, { type: argon2.argon2id });
    const existing = await dataSource.query(
      `SELECT id FROM platform_admin WHERE lower(email) = $1`,
      [email],
    );
    if (existing.length) {
      await dataSource.query(
        `UPDATE platform_admin SET password_hash = $2, display_name = $3, deleted_at = NULL
          WHERE id = $1`,
        [existing[0].id, hash, name],
      );
      console.log(`rotated the password for ${email}`);
    } else {
      await dataSource.query(
        `INSERT INTO platform_admin (id, email, display_name, password_hash)
         VALUES ($1, $2, $3, $4)`,
        [uuidv7(), email, name, hash],
      );
      console.log(`created platform admin ${email}`);
    }

    if (process.env.RETIRE_DEV_ADMIN === 'yes' && email !== 'admin@pharmaet.local') {
      await dataSource.query(
        `UPDATE platform_admin SET deleted_at = now()
          WHERE lower(email) = 'admin@pharmaet.local' AND deleted_at IS NULL`,
      );
      console.log('retired the development admin (admin@pharmaet.local)');
    }
  } finally {
    await dataSource.destroy();
  }
}

void main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
