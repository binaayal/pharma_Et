import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * Manual stock corrections (FR-3, docs/04 §5.3).
 *
 * BR-3.2 promises that an oversell is "recorded and flagged for **physical
 * reconciliation**". Until now the system could flag one and offer no way to resolve it,
 * which left the counter with a permanently negative number and no honest action to take —
 * the sort of gap that teaches people the stock figures are not worth maintaining.
 *
 * The row records the **delta**, not the resulting total, and both the reason and what the
 * terminal believed beforehand. That is what makes a correction reconstructable a year later
 * rather than merely applied.
 */
export class StockAdjustment1759000000000 implements MigrationInterface {
  name = 'StockAdjustment1759000000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    const appUser = process.env.DATABASE_APP_USER ?? 'pharmaet_app';

    await queryRunner.query(`
      CREATE TABLE "stock_adjustment" (
        "id"           uuid PRIMARY KEY,
        "tenant_id"    uuid NOT NULL REFERENCES "tenant"("id"),
        "created_at"   timestamptz NOT NULL DEFAULT now(),
        "updated_at"   timestamptz NOT NULL DEFAULT now(),
        "deleted_at"   timestamptz,
        "row_version"  integer NOT NULL DEFAULT 1,
        "change_seq"   bigint NOT NULL DEFAULT 0,

        "branch_id"    uuid NOT NULL REFERENCES "branch"("id"),
        "batch_id"     uuid NOT NULL REFERENCES "stock_batch"("id"),
        "product_id"   uuid NOT NULL REFERENCES "product"("id"),
        "actor_id"     uuid NOT NULL REFERENCES "app_user"("id"),
        "terminal_id"  uuid,

        -- Signed. Negative writes stock off, positive adds it back. Never an absolute:
        -- a terminal offline for days holds a count the server may already disagree with,
        -- and "set it to 40" would silently discard whatever happened in between.
        "delta"        bigint NOT NULL,
        "reason"       text NOT NULL,
        "note"         text,
        -- What the terminal believed beforehand. Kept so the decision can be reconstructed:
        -- a write-off of 5 from a believed 5 is a different act from one from a believed 500.
        "previous_qty_on_hand" bigint NOT NULL,
        "counted_at"   timestamptz NOT NULL,

        CONSTRAINT "stock_adjustment_delta_nonzero" CHECK ("delta" <> 0),
        CONSTRAINT "stock_adjustment_reason_known" CHECK ("reason" IN (
          'recount', 'damage', 'expiry_writeoff', 'theft_or_loss',
          'receipt_correction', 'other'
        )),
        -- The contract enforces this too. Repeated here because an unexplained write-off is
        -- indistinguishable from a covered-up one, and that is worth two layers.
        CONSTRAINT "stock_adjustment_note_required" CHECK (
          "reason" = 'recount' OR ("note" IS NOT NULL AND length(btrim("note")) > 0)
        )
      );

      CREATE INDEX "stock_adjustment_tenant_idx" ON "stock_adjustment" ("tenant_id");
      CREATE INDEX "stock_adjustment_batch_idx"
        ON "stock_adjustment" ("tenant_id", "batch_id", "counted_at" DESC);
      CREATE INDEX "stock_adjustment_branch_idx"
        ON "stock_adjustment" ("tenant_id", "branch_id", "counted_at" DESC);
    `);

    await queryRunner.query(`ALTER TABLE "stock_adjustment" ENABLE ROW LEVEL SECURITY;`);
    await queryRunner.query(`ALTER TABLE "stock_adjustment" FORCE ROW LEVEL SECURITY;`);
    await queryRunner.query(`
      CREATE POLICY "tenant_isolation" ON "stock_adjustment"
        USING ("tenant_id" = nullif(current_setting('app.current_tenant', true), '')::uuid)
        WITH CHECK ("tenant_id" = nullif(current_setting('app.current_tenant', true), '')::uuid);
    `);
    await queryRunner.query(`GRANT SELECT, INSERT, UPDATE ON "stock_adjustment" TO ${appUser};`);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`DROP TABLE IF EXISTS "stock_adjustment" CASCADE;`);
  }
}
