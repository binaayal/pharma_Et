import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * Suppliers and what is owed to them (FR-18, ADR-038).
 *
 * Until now a delivery recorded a supplier's *name*, as free text, and nothing about whether
 * it had been paid for. What the pharmacy owed lived in a paper book and in the supplier's
 * own invoices. This is the mirror image of the customer credit ledger (ADR-034).
 *
 * Additive, and safe under the previous release:
 *
 *   - `supplier` and `supplier_payment` are new tables the previous release never touches.
 *   - `goods_receipt.supplier_id` is nullable and null on every receipt ever recorded;
 *     `goods_receipt.owed_santim` defaults to 0, which is what the previous release's
 *     receipts are taken to be — paid for. It goes on writing neither column.
 *   - `supplier_name` stays, and stays NOT NULL: it is what was written on the day.
 *
 * `supplier.balance_santim` is a running figure maintained in the transaction of the receipt
 * or payment that moves it, recomputable from those rows (`PayablesService.verify`).
 */
export class Suppliers1760100000000 implements MigrationInterface {
  name = 'Suppliers1760100000000';

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
      CREATE TABLE "supplier" (
        ${synced},
        "name"              text NOT NULL,
        "phone"             text,
        "note"              text,
        -- Positive: the pharmacy owes the supplier. Negative: it has paid ahead.
        "balance_santim"    bigint NOT NULL DEFAULT 0,
        "created_branch_id" uuid REFERENCES "branch"("id"),
        "created_by"        uuid REFERENCES "app_user"("id"),
        "terminal_id"       uuid,
        CONSTRAINT "supplier_name_present" CHECK (length(btrim("name")) > 0)
      );
      CREATE INDEX "supplier_tenant_seq_idx" ON "supplier" ("tenant_id", "change_seq");
    `);

    await queryRunner.query(`
      CREATE TABLE "supplier_payment" (
        ${synced},
        "branch_id"     uuid NOT NULL REFERENCES "branch"("id"),
        "supplier_id"   uuid NOT NULL REFERENCES "supplier"("id"),
        "amount_santim" bigint NOT NULL,
        "method"        text NOT NULL,
        "paid_at"       timestamptz NOT NULL,
        -- The till the cash came out of. Cash here comes off that shift's expected cash.
        "shift_id"      uuid REFERENCES "shift"("id"),
        "paid_by"       uuid NOT NULL REFERENCES "app_user"("id"),
        "terminal_id"   uuid,
        "note"          text,
        CONSTRAINT "supplier_payment_amount_positive" CHECK ("amount_santim" > 0),
        CONSTRAINT "supplier_payment_method_check" CHECK ("method" IN ('cash', 'other_recorded'))
      );
      CREATE INDEX "supplier_payment_supplier_idx"
        ON "supplier_payment" ("tenant_id", "supplier_id", "paid_at" DESC);
      CREATE INDEX "supplier_payment_shift_idx" ON "supplier_payment" ("shift_id");
    `);

    for (const table of ['supplier', 'supplier_payment']) {
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
      ALTER TABLE "goods_receipt"
        ADD COLUMN "supplier_id" uuid REFERENCES "supplier"("id"),
        ADD COLUMN "owed_santim" bigint NOT NULL DEFAULT 0,
        ADD CONSTRAINT "goods_receipt_owed_nonnegative" CHECK ("owed_santim" >= 0),
        -- A debt owed to nobody cannot be paid.
        ADD CONSTRAINT "goods_receipt_owed_has_supplier"
          CHECK ("owed_santim" = 0 OR "supplier_id" IS NOT NULL);
      CREATE INDEX "goods_receipt_supplier_idx" ON "goods_receipt" ("tenant_id", "supplier_id")
        WHERE "supplier_id" IS NOT NULL;
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    // Local iteration only: production migrations are forward-only (docs/06 §6.2).
    await queryRunner.query(`DROP INDEX IF EXISTS "goods_receipt_supplier_idx";`);
    await queryRunner.query(`
      ALTER TABLE "goods_receipt"
        DROP CONSTRAINT IF EXISTS "goods_receipt_owed_has_supplier",
        DROP CONSTRAINT IF EXISTS "goods_receipt_owed_nonnegative",
        DROP COLUMN IF EXISTS "owed_santim",
        DROP COLUMN IF EXISTS "supplier_id";
    `);
    await queryRunner.query(`DROP TABLE IF EXISTS "supplier_payment" CASCADE;`);
    await queryRunner.query(`DROP TABLE IF EXISTS "supplier" CASCADE;`);
  }
}
