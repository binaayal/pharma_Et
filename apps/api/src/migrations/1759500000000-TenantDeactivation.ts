import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * Forced deactivation of a pharmacy by the platform (ADR-025).
 *
 * A third tenant status, beside `active` and `closed`, with who did it, when and why. The
 * reason is required by constraint, not by convention: the owner is shown it, and a
 * deactivation the owner cannot explain to themselves is a dispute before it is a support
 * call.
 *
 * `deactivated_by` references `platform_admin`: only the platform can deactivate a tenant,
 * and the schema says so. Nothing is deleted or rewritten — the tenant's rows, events and
 * ledger stay exactly as they were, so reactivation restores the account whole.
 *
 * Expand-only (docs/06 §6.2): the columns are nullable and the widened check still accepts
 * every existing row, so the previous release keeps running against this schema.
 */
export class TenantDeactivation1759500000000 implements MigrationInterface {
  name = 'TenantDeactivation1759500000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      ALTER TABLE "tenant"
        ADD COLUMN "deactivated_at"     timestamptz,
        ADD COLUMN "deactivated_reason" text,
        ADD COLUMN "deactivated_by"     uuid REFERENCES "platform_admin"("id");

      ALTER TABLE "tenant" DROP CONSTRAINT "tenant_status_check";
      ALTER TABLE "tenant" ADD CONSTRAINT "tenant_status_check"
        CHECK ("status" IN ('active', 'closed', 'deactivated'));

      -- A deactivation has a time, a reason and an actor; an account that is not
      -- deactivated has none of them. Reactivating clears all three together.
      ALTER TABLE "tenant" ADD CONSTRAINT "tenant_deactivation_check" CHECK (
        ("status" = 'deactivated') = ("deactivated_at" IS NOT NULL)
        AND ("deactivated_at" IS NULL) = ("deactivated_reason" IS NULL)
        AND ("deactivated_at" IS NULL) = ("deactivated_by" IS NULL)
      );
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      ALTER TABLE "tenant" DROP CONSTRAINT IF EXISTS "tenant_deactivation_check";
      UPDATE "tenant" SET "status" = 'active' WHERE "status" = 'deactivated';
      ALTER TABLE "tenant" DROP CONSTRAINT "tenant_status_check";
      ALTER TABLE "tenant" ADD CONSTRAINT "tenant_status_check"
        CHECK ("status" IN ('active', 'closed'));
      ALTER TABLE "tenant"
        DROP COLUMN IF EXISTS "deactivated_by",
        DROP COLUMN IF EXISTS "deactivated_reason",
        DROP COLUMN IF EXISTS "deactivated_at";
    `);
  }
}
