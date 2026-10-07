import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * The customer credit ledger — ዕዳ (FR-16, ADR-034).
 *
 * A large share of a pharmacy's real sales are on credit: to regulars, to clinics, to
 * organisations buying for their staff. Until now the system could only record money that
 * had already been paid, so the debt lived in a paper book beside the phone.
 *
 * Additive, and safe under the previous release:
 *
 *   - `customer` and `credit_payment` are new tables the previous release never touches.
 *   - `sale.customer_id` is nullable and null on every sale ever recorded.
 *   - `payment_method_check` is **widened** to allow `credit`. Everything the previous
 *     release writes (`cash`, `other_recorded`) still satisfies it.
 *
 * `customer.balance_santim` is a running figure maintained in the same transaction as the
 * sale or repayment that moves it. It is not the source of truth — the payments and
 * repayments are, and `CreditService.verify` recomputes it from them. It exists so the pull
 * can hand every terminal a balance without summing a customer's whole history each time.
 */
export class CreditLedger1759900000000 implements MigrationInterface {
  name = 'CreditLedger1759900000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    const appUser = process.env.DATABASE_APP_USER ?? 'pharmaet_app';

    const synced = `
      "id"          uuid PRIMARY KEY,
      "tenant_id"   uuid NOT NULL REFERENCES "tenant"("id"),
      "created_at"  timestamptz NOT NULL DEFAULT now(),
      "updated_at"  timestamptz NOT NULL DEFAULT now(),
      "deleted_at"  timestamptz,
      "row_version" integer NOT NULL DEFAULT 1,
      "change_seq"  bigint NOT NULL DEFAULT 0
    `;

    await queryRunner.query(`
      CREATE TABLE "customer" (
        ${synced},
        "name"              text NOT NULL,
        "phone"             text,
        "note"              text,
        -- Positive: the customer owes the pharmacy. Negative: they have paid ahead. Signed
        -- on purpose — someone handing over 500 against a debt of 480 is ordinary, and
        -- refusing or silently capping it would make the book wrong.
        "balance_santim"    bigint NOT NULL DEFAULT 0,
        "created_branch_id" uuid REFERENCES "branch"("id"),
        "created_by"        uuid REFERENCES "app_user"("id"),
        "terminal_id"       uuid,
        CONSTRAINT "customer_name_present" CHECK (length(btrim("name")) > 0)
      );
      CREATE INDEX "customer_tenant_seq_idx" ON "customer" ("tenant_id", "change_seq");
    `);

    await queryRunner.query(`
      CREATE TABLE "credit_payment" (
        ${synced},
        "branch_id"     uuid NOT NULL REFERENCES "branch"("id"),
        "customer_id"   uuid NOT NULL REFERENCES "customer"("id"),
        "amount_santim" bigint NOT NULL,
        "method"        text NOT NULL,
        "paid_at"       timestamptz NOT NULL,
        "shift_id"      uuid REFERENCES "shift"("id"),
        "received_by"   uuid NOT NULL REFERENCES "app_user"("id"),
        "terminal_id"   uuid,
        "note"          text,
        CONSTRAINT "credit_payment_amount_positive" CHECK ("amount_santim" > 0),
        -- Never 'credit': a debt is not settled with another debt.
        CONSTRAINT "credit_payment_method_check" CHECK ("method" IN ('cash', 'other_recorded'))
      );
      CREATE INDEX "credit_payment_customer_idx"
        ON "credit_payment" ("tenant_id", "customer_id", "paid_at" DESC);
      CREATE INDEX "credit_payment_shift_idx" ON "credit_payment" ("shift_id");
    `);

    for (const table of ['customer', 'credit_payment']) {
      await queryRunner.query(`ALTER TABLE "${table}" ENABLE ROW LEVEL SECURITY;`);
      await queryRunner.query(`ALTER TABLE "${table}" FORCE ROW LEVEL SECURITY;`);
      await queryRunner.query(`
        CREATE POLICY "tenant_isolation" ON "${table}"
          USING ("tenant_id" = nullif(current_setting('app.current_tenant', true), '')::uuid)
          WITH CHECK ("tenant_id" = nullif(current_setting('app.current_tenant', true), '')::uuid);
      `);
      await queryRunner.query(`GRANT SELECT, INSERT, UPDATE ON "${table}" TO ${appUser};`);
    }

    await queryRunner.query(`
      ALTER TABLE "sale" ADD COLUMN "customer_id" uuid REFERENCES "customer"("id");
      CREATE INDEX "sale_customer_idx" ON "sale" ("tenant_id", "customer_id")
        WHERE "customer_id" IS NOT NULL;
    `);

    await queryRunner.query(`
      ALTER TABLE "payment" DROP CONSTRAINT "payment_method_check";
      ALTER TABLE "payment" ADD CONSTRAINT "payment_method_check"
        CHECK ("method" IN ('cash', 'other_recorded', 'credit'));
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    // Local iteration only: production migrations are forward-only (docs/06 §6.2). This
    // cannot restore the narrower payment check once a credit payment exists, and does not
    // pretend to.
    await queryRunner.query(`DROP INDEX IF EXISTS "sale_customer_idx";`);
    await queryRunner.query(`ALTER TABLE "sale" DROP COLUMN IF EXISTS "customer_id";`);
    await queryRunner.query(`DROP TABLE IF EXISTS "credit_payment" CASCADE;`);
    await queryRunner.query(`DROP TABLE IF EXISTS "customer" CASCADE;`);
  }
}
