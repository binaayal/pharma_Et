import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * Platform administration and billing (FR-1, docs/04 §5.8, Vision §4).
 *
 * V1 has no payment gateway: a tenant pays ETB 1,000/month, submits a screenshot, and a
 * Platform Admin verifies it. This migration adds the three tables that loop runs on.
 *
 * **`platform_admin` is deliberately outside tenant scope.** It carries no `tenant_id` and
 * no RLS policy, because it is not tenant data — it is us. BR-2.2 requires that a Platform
 * Admin has no default access to tenant clinical or sales data, and keeping the identity in
 * a separate table with a separate login is what makes that a structural fact rather than a
 * promise: there is no token that is both.
 */
export class PlatformAndBilling1759100000000 implements MigrationInterface {
  name = 'PlatformAndBilling1759100000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    const appUser = process.env.DATABASE_APP_USER ?? 'pharmaet_app';

    await queryRunner.query(`
      CREATE TABLE "platform_admin" (
        "id"            uuid PRIMARY KEY,
        "email"         text NOT NULL,
        "display_name"  text NOT NULL,
        "password_hash" text NOT NULL,
        "created_at"    timestamptz NOT NULL DEFAULT now(),
        "deleted_at"    timestamptz
      );
      CREATE UNIQUE INDEX "platform_admin_email_uq"
        ON "platform_admin" (lower("email")) WHERE "deleted_at" IS NULL;
    `);

    await queryRunner.query(`
      CREATE TABLE "subscription" (
        "id"                  uuid PRIMARY KEY,
        "tenant_id"           uuid NOT NULL REFERENCES "tenant"("id"),
        "created_at"          timestamptz NOT NULL DEFAULT now(),
        "updated_at"          timestamptz NOT NULL DEFAULT now(),
        "row_version"         integer NOT NULL DEFAULT 1,

        "state"               text NOT NULL DEFAULT 'pending',
        -- Null while pending: a subscription nobody has paid for has no period to end.
        "current_period_end"  timestamptz,
        "price_santim"        bigint NOT NULL DEFAULT 100000,
        "suspended_reason"    text,

        CONSTRAINT "subscription_state_check"
          CHECK ("state" IN ('pending', 'active', 'suspended')),
        CONSTRAINT "subscription_price_non_negative" CHECK ("price_santim" >= 0),
        -- An active subscription must say until when. Without this an "active" row with a
        -- null period is indistinguishable from one that should have lapsed months ago.
        CONSTRAINT "subscription_active_has_period"
          CHECK ("state" <> 'active' OR "current_period_end" IS NOT NULL)
      );
      -- One subscription per tenant. Two would make "is this tenant paid up?" ambiguous,
      -- and that question gates every management write in the system.
      CREATE UNIQUE INDEX "subscription_tenant_uq" ON "subscription" ("tenant_id");
    `);

    await queryRunner.query(`
      CREATE TABLE "payment_proof" (
        "id"             uuid PRIMARY KEY,
        "tenant_id"      uuid NOT NULL REFERENCES "tenant"("id"),
        "created_at"     timestamptz NOT NULL DEFAULT now(),
        "updated_at"     timestamptz NOT NULL DEFAULT now(),

        -- A reference into object storage, never the image itself (docs/04 §5.8).
        -- Screenshots in a relational column bloat every backup and every restore drill.
        "storage_key"    text NOT NULL,
        "content_type"   text NOT NULL,
        "byte_size"      bigint NOT NULL,
        "submitted_by"   uuid NOT NULL REFERENCES "app_user"("id"),
        "submitted_at"   timestamptz NOT NULL,
        "amount_santim"  bigint NOT NULL,
        "note"           text,

        -- Verification, by a Platform Admin. Null until somebody has actually looked.
        "result"         text NOT NULL DEFAULT 'pending',
        "verified_by"    uuid REFERENCES "platform_admin"("id"),
        "verified_at"    timestamptz,
        "rejection_reason" text,

        CONSTRAINT "payment_proof_result_check"
          CHECK ("result" IN ('pending', 'accepted', 'rejected')),
        CONSTRAINT "payment_proof_amount_positive" CHECK ("amount_santim" > 0),
        CONSTRAINT "payment_proof_size_positive" CHECK ("byte_size" > 0),
        -- A decision must name who made it and when. An accepted payment with no verifier
        -- is exactly the record a dispute turns on.
        CONSTRAINT "payment_proof_decided_by_someone" CHECK (
          "result" = 'pending'
          OR ("verified_by" IS NOT NULL AND "verified_at" IS NOT NULL)
        ),
        -- And a rejection must say why, or the tenant cannot fix it.
        CONSTRAINT "payment_proof_rejection_explained" CHECK (
          "result" <> 'rejected'
          OR ("rejection_reason" IS NOT NULL AND length(btrim("rejection_reason")) > 0)
        )
      );
      CREATE INDEX "payment_proof_tenant_idx" ON "payment_proof" ("tenant_id", "submitted_at" DESC);
      -- The platform admin's work queue: everything waiting on a human, oldest first.
      CREATE INDEX "payment_proof_pending_idx"
        ON "payment_proof" ("submitted_at") WHERE "result" = 'pending';
    `);

    // ---------------------------------------------------------------------- RLS
    // subscription and payment_proof are tenant data: an owner reads their own, and must
    // never see another pharmacy's billing.
    for (const table of ['subscription', 'payment_proof']) {
      await queryRunner.query(`ALTER TABLE "${table}" ENABLE ROW LEVEL SECURITY;`);
      await queryRunner.query(`ALTER TABLE "${table}" FORCE ROW LEVEL SECURITY;`);
      await queryRunner.query(`
        CREATE POLICY "tenant_isolation" ON "${table}"
          USING ("tenant_id" = nullif(current_setting('app.current_tenant', true), '')::uuid)
          WITH CHECK ("tenant_id" = nullif(current_setting('app.current_tenant', true), '')::uuid);
      `);
      // No tenant_id index here: `subscription` already has a unique one and
      // `payment_proof` a composite. A redundant index is not free — it is paid for on
      // every write, forever, to answer a query the existing one already answers.
      await queryRunner.query(`GRANT SELECT, INSERT, UPDATE ON "${table}" TO ${appUser};`);
    }

    // platform_admin gets NO RLS policy and only SELECT for the application role. It is not
    // tenant data, and the tenant-scoped connection has no legitimate reason to write it —
    // an admin is created by migration or by an operator, never through the tenant API,
    // because an endpoint that mints platform identities is an escalation path by design.
    await queryRunner.query(`GRANT SELECT ON "platform_admin" TO ${appUser};`);

    // Every existing tenant gets a subscription row, so "is this tenant paid up?" has an
    // answer for all of them rather than only the ones onboarded after today.
    await queryRunner.query(`
      INSERT INTO "subscription" ("id", "tenant_id", "state", "current_period_end")
      SELECT gen_random_uuid(), t.id, 'active', now() + interval '30 days'
        FROM "tenant" t
       WHERE NOT EXISTS (SELECT 1 FROM "subscription" s WHERE s.tenant_id = t.id);
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`DROP TABLE IF EXISTS "payment_proof" CASCADE;`);
    await queryRunner.query(`DROP TABLE IF EXISTS "subscription" CASCADE;`);
    await queryRunner.query(`DROP TABLE IF EXISTS "platform_admin" CASCADE;`);
  }
}
