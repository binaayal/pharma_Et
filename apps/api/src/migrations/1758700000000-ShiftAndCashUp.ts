import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * FR-8 — per-shift cash reconciliation (docs/04 §5.4).
 *
 * Vision §2.1.1 calls this the owner's primary anti-shrinkage control and the strongest
 * single reason to adopt the product. It is the first thing Phase 1 builds.
 *
 * Both tables carry their RLS policy in the same migration, as every table must (ADR-007):
 * a table that reaches production without one has no isolation, and no application test
 * would notice, because application queries are scoped anyway.
 */
export class ShiftAndCashUp1758700000000 implements MigrationInterface {
  name = 'ShiftAndCashUp1758700000000';

  private readonly tables = ['shift', 'cash_up'];

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
      CREATE TABLE "shift" (
        ${synced},
        "branch_id"             uuid NOT NULL REFERENCES "branch"("id"),
        "user_id"               uuid NOT NULL REFERENCES "app_user"("id"),
        "terminal_id"           uuid NOT NULL,
        "opened_at"             timestamptz NOT NULL,
        "closed_at"             timestamptz,
        -- What was in the drawer before trading. Part of the expected figure: a cash-up
        -- that ignored it would report a variance equal to the float on every shift, which
        -- is how a control gets switched off for being noisy.
        "opening_float_santim"  bigint NOT NULL DEFAULT 0,
        CONSTRAINT "shift_float_non_negative" CHECK ("opening_float_santim" >= 0),
        CONSTRAINT "shift_closes_after_opening"
          CHECK ("closed_at" IS NULL OR "closed_at" >= "opened_at")
      );
      CREATE INDEX "shift_branch_opened_idx"
        ON "shift" ("tenant_id", "branch_id", "opened_at" DESC);
      -- One open shift per user per terminal. Two open tills for one person means the
      -- expected figure is split across them and neither reconciles.
      CREATE UNIQUE INDEX "shift_one_open_per_user_terminal"
        ON "shift" ("tenant_id", "user_id", "terminal_id")
        WHERE "closed_at" IS NULL AND "deleted_at" IS NULL;
    `);

    await queryRunner.query(`
      CREATE TABLE "cash_up" (
        ${synced},
        "shift_id"                uuid NOT NULL REFERENCES "shift"("id"),
        "branch_id"               uuid NOT NULL REFERENCES "branch"("id"),
        "user_id"                 uuid NOT NULL REFERENCES "app_user"("id"),
        "counted_at"              timestamptz NOT NULL,
        -- What the TERMINAL computed and showed the cashier. Never recomputed or corrected:
        -- rewriting the number somebody was asked to reconcile against destroys the only
        -- evidence of what they actually agreed to (ADR-012 §3).
        "expected_santim"         bigint NOT NULL,
        "counted_santim"          bigint NOT NULL,
        -- counted - expected. Negative means cash is missing: the number this whole feature
        -- exists to surface.
        "variance_santim"         bigint NOT NULL,
        -- What the SERVER recomputed from synced sales when the operation landed. Kept
        -- separately for audit; a divergence usually means sales were still queued, and is
        -- itself a finding worth showing (ADR-012 §3).
        "server_expected_santim"  bigint,
        "note"                    text,
        CONSTRAINT "cash_up_counted_non_negative" CHECK ("counted_santim" >= 0),
        -- The arithmetic the contract asserts, enforced by the database too, so a money
        -- error cannot enter through a path that skipped the domain layer (guardian G4).
        CONSTRAINT "cash_up_variance_consistent"
          CHECK ("variance_santim" = "counted_santim" - "expected_santim")
      );
      -- A shift reconciles exactly once. A second cash-up would mean two conflicting
      -- statements about the same till, with no way to tell which one a person signed.
      CREATE UNIQUE INDEX "cash_up_one_per_shift"
        ON "cash_up" ("shift_id") WHERE "deleted_at" IS NULL;
    `);

    // Sales already carry shift_id; now it can actually reference something.
    await queryRunner.query(`
      ALTER TABLE "sale"
        ADD CONSTRAINT "sale_shift_fk" FOREIGN KEY ("shift_id") REFERENCES "shift"("id");
    `);

    for (const table of this.tables) {
      await queryRunner.query(`ALTER TABLE "${table}" ENABLE ROW LEVEL SECURITY;`);
      await queryRunner.query(`ALTER TABLE "${table}" FORCE ROW LEVEL SECURITY;`);
      await queryRunner.query(`
        CREATE POLICY "tenant_isolation" ON "${table}"
          USING ("tenant_id" = nullif(current_setting('app.current_tenant', true), '')::uuid)
          WITH CHECK ("tenant_id" = nullif(current_setting('app.current_tenant', true), '')::uuid);
      `);
      await queryRunner.query(`CREATE INDEX "${table}_tenant_idx" ON "${table}" ("tenant_id");`);
      await queryRunner.query(`GRANT SELECT, INSERT, UPDATE ON "${table}" TO ${appUser};`);
    }
    // Still no DELETE grant, on any table. Nothing here is ever physically removed.
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`ALTER TABLE "sale" DROP CONSTRAINT IF EXISTS "sale_shift_fk";`);
    await queryRunner.query(`DROP TABLE IF EXISTS "cash_up" CASCADE;`);
    await queryRunner.query(`DROP TABLE IF EXISTS "shift" CASCADE;`);
  }
}
