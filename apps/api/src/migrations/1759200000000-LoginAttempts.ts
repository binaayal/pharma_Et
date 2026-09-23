import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * Login attempt log, for throttling (NFR-4.2, ADR-017).
 *
 * **No `tenant_id`, deliberately.** An attempt may name a tenant that does not exist — that
 * is the entire point of recording it, because refusing to count attempts against unknown
 * tenants would turn the rate limiter into an account-enumeration oracle: "throttled" would
 * mean "this pharmacy is real".
 *
 * It is therefore on the CI list of known non-tenant tables, so the next person to add one
 * has to say so on purpose rather than discovering it in a red build.
 */
export class LoginAttempts1759200000000 implements MigrationInterface {
  name = 'LoginAttempts1759200000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    const appUser = process.env.DATABASE_APP_USER ?? 'pharmaet_app';

    await queryRunner.query(`
      CREATE TABLE "login_attempt" (
        "id"           uuid PRIMARY KEY,
        -- As supplied and lowercased, not a foreign key: the whole value of this row is
        -- that it may name nothing at all.
        "tenant_code"  text NOT NULL,
        "username"     text NOT NULL,
        "source_ip"    text NOT NULL,
        "succeeded"    boolean NOT NULL,
        "attempted_at" timestamptz NOT NULL DEFAULT now()
      );

      -- The two lookups the limiter makes, on every login, before anything else happens.
      -- Both are time-bounded, so the index leads with the identity and ends with the clock.
      CREATE INDEX "login_attempt_identity_idx"
        ON "login_attempt" ("tenant_code", "username", "attempted_at" DESC);
      CREATE INDEX "login_attempt_source_idx"
        ON "login_attempt" ("source_ip", "attempted_at" DESC);
    `);

    // Written on the tenant connection during login, when no tenant scope is set — so it
    // carries no RLS policy and could not honour one. It holds no tenant data: a username,
    // a code that may be fictional, and an address.
    await queryRunner.query(`GRANT SELECT, INSERT, DELETE ON "login_attempt" TO ${appUser};`);
    // DELETE, uniquely in this schema, because these rows are operational telemetry with a
    // retention need rather than business records. Nothing else here is ever deleted.
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`DROP TABLE IF EXISTS "login_attempt" CASCADE;`);
  }
}
