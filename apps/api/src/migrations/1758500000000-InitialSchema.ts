import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * Phase 0 schema — the walking skeleton (docs/04-system-design.md §13).
 *
 * Tables AND their RLS policies are created together, on purpose (ADR-007): a migration
 * that adds a table without its policy ships a table with no isolation, and the gap would
 * not be visible in any application test that only ever queries in scope.
 *
 * Absent by design: the controlled-substance event store, its projections, shifts, cash-up,
 * subscriptions. Those are Phase 1/2 — the ledger in particular waits behind the A-1
 * compliance gate (docs/06-delivery-plan.md §2).
 */
export class InitialSchema1758500000000 implements MigrationInterface {
  name = 'InitialSchema1758500000000';

  /** Every tenant-scoped table, i.e. everything that RLS must cover. */
  private readonly tenantScopedTables = [
    'branch',
    'app_user',
    'user_branch',
    'product',
    'stock_batch',
    'sale',
    'sale_line',
    'payment',
    'goods_receipt',
    'goods_receipt_line',
    'applied_op',
    'tenant_change_seq',
    'oversell_event',
  ];

  public async up(queryRunner: QueryRunner): Promise<void> {
    const appUser = process.env.DATABASE_APP_USER ?? 'pharmaet_app';
    const appPassword = process.env.DATABASE_APP_PASSWORD ?? 'pharmaet_app_dev_password';

    // ---------------------------------------------------------------- roles
    // The application role is NOT the table owner. Postgres exempts owners and superusers
    // from row-level security, so an app connecting as the owner would have RLS enabled and
    // entirely inert — the most dangerous possible state, since every test would still pass.
    await queryRunner.query(`
      DO $$
      BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${appUser}') THEN
          CREATE ROLE ${appUser} LOGIN PASSWORD '${appPassword}';
        END IF;
      END
      $$;
    `);

    // ---------------------------------------------------------------- tables
    await queryRunner.query(`
      CREATE TABLE "tenant" (
        "id"         uuid PRIMARY KEY,
        "name"       text NOT NULL,
        "code"       text NOT NULL,
        "status"     text NOT NULL DEFAULT 'active',
        "created_at" timestamptz NOT NULL DEFAULT now(),
        "deleted_at" timestamptz,
        CONSTRAINT "tenant_status_check" CHECK ("status" IN ('active', 'closed'))
      );
      CREATE UNIQUE INDEX "tenant_code_uq" ON "tenant" (lower("code"));
    `);

    // Columns shared by every synced table (docs/04 §2). Repeated inline rather than via
    // inheritance so the schema reads as what Postgres actually holds.
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
      CREATE TABLE "branch" (
        ${synced},
        "name"    text NOT NULL,
        "address" text
      );
    `);

    await queryRunner.query(`
      CREATE TABLE "app_user" (
        ${synced},
        "username"      text NOT NULL,
        "display_name"  text NOT NULL,
        "role"          text NOT NULL,
        "pin_hash"      text,
        "password_hash" text,
        CONSTRAINT "app_user_role_check"
          CHECK ("role" IN ('owner', 'branch_manager', 'cashier'))
      );
      -- Usernames are unique per tenant, not globally: two pharmacies may both have a
      -- cashier called "abebe" and neither should block the other.
      CREATE UNIQUE INDEX "app_user_tenant_username_uq"
        ON "app_user" ("tenant_id", lower("username")) WHERE "deleted_at" IS NULL;
    `);

    await queryRunner.query(`
      CREATE TABLE "user_branch" (
        ${synced},
        "user_id"   uuid NOT NULL REFERENCES "app_user"("id"),
        "branch_id" uuid NOT NULL REFERENCES "branch"("id")
      );
      CREATE UNIQUE INDEX "user_branch_uq" ON "user_branch" ("user_id", "branch_id");
    `);

    await queryRunner.query(`
      CREATE TABLE "product" (
        ${synced},
        "name"                  text NOT NULL,
        "unit"                  text NOT NULL,
        "is_controlled"         boolean NOT NULL DEFAULT false,
        "psychotropic_class"    text,
        "current_price_santim"  bigint NOT NULL,
        -- Money is an integer count of santim and is never negative (docs/04 §3, G4).
        CONSTRAINT "product_price_non_negative" CHECK ("current_price_santim" >= 0)
      );
    `);

    await queryRunner.query(`
      CREATE TABLE "stock_batch" (
        ${synced},
        "branch_id"   uuid NOT NULL REFERENCES "branch"("id"),
        "product_id"  uuid NOT NULL REFERENCES "product"("id"),
        "lot_no"      text NOT NULL,
        "expiry_date" date NOT NULL,
        -- Deliberately NO non-negative constraint. Standard-drug stock may go negative:
        -- a sale is never blocked by a stock count (BR-3.2), because an offline terminal
        -- cannot know the true count and refusing the sale would stop the counter. The
        -- oversell is recorded in "oversell_event" instead of being prevented (G5).
        "qty_on_hand" bigint NOT NULL DEFAULT 0
      );
      CREATE INDEX "stock_batch_fefo_idx"
        ON "stock_batch" ("tenant_id", "branch_id", "product_id", "expiry_date")
        WHERE "deleted_at" IS NULL;
    `);

    await queryRunner.query(`
      CREATE TABLE "sale" (
        ${synced},
        "branch_id"    uuid NOT NULL REFERENCES "branch"("id"),
        "shift_id"     uuid,
        "cashier_id"   uuid NOT NULL REFERENCES "app_user"("id"),
        "terminal_id"  uuid NOT NULL,
        "total_santim" bigint NOT NULL,
        "sold_at"      timestamptz NOT NULL,
        CONSTRAINT "sale_total_non_negative" CHECK ("total_santim" >= 0)
      );
      CREATE INDEX "sale_branch_sold_at_idx" ON "sale" ("tenant_id", "branch_id", "sold_at" DESC);
    `);

    await queryRunner.query(`
      CREATE TABLE "sale_line" (
        ${synced},
        "sale_id"            uuid NOT NULL REFERENCES "sale"("id"),
        "product_id"         uuid NOT NULL REFERENCES "product"("id"),
        "batch_id"           uuid REFERENCES "stock_batch"("id"),
        "qty"                bigint NOT NULL,
        "unit_price_santim"  bigint NOT NULL,
        "line_total_santim"  bigint NOT NULL,
        CONSTRAINT "sale_line_qty_positive" CHECK ("qty" > 0),
        CONSTRAINT "sale_line_money_non_negative"
          CHECK ("unit_price_santim" >= 0 AND "line_total_santim" >= 0),
        -- The arithmetic that guardian G4 asserts, enforced by the database as well, so a
        -- money error cannot enter through a path that skipped the domain layer.
        CONSTRAINT "sale_line_total_consistent"
          CHECK ("line_total_santim" = "qty" * "unit_price_santim")
      );
      CREATE INDEX "sale_line_sale_idx" ON "sale_line" ("sale_id");
    `);

    await queryRunner.query(`
      CREATE TABLE "payment" (
        ${synced},
        "sale_id"       uuid NOT NULL REFERENCES "sale"("id"),
        "method"        text NOT NULL,
        "amount_santim" bigint NOT NULL,
        CONSTRAINT "payment_method_check" CHECK ("method" IN ('cash', 'other_recorded')),
        CONSTRAINT "payment_amount_non_negative" CHECK ("amount_santim" >= 0)
      );
      CREATE INDEX "payment_sale_idx" ON "payment" ("sale_id");
    `);

    await queryRunner.query(`
      CREATE TABLE "goods_receipt" (
        ${synced},
        "branch_id"     uuid NOT NULL REFERENCES "branch"("id"),
        "supplier_name" text NOT NULL,
        "received_at"   timestamptz NOT NULL,
        "terminal_id"   uuid NOT NULL
      );
    `);

    await queryRunner.query(`
      CREATE TABLE "goods_receipt_line" (
        ${synced},
        "goods_receipt_id" uuid NOT NULL REFERENCES "goods_receipt"("id"),
        "product_id"       uuid NOT NULL REFERENCES "product"("id"),
        "lot_no"           text NOT NULL,
        "expiry_date"      date NOT NULL,
        "qty"              bigint NOT NULL,
        "cost_santim"      bigint NOT NULL,
        CONSTRAINT "goods_receipt_line_qty_positive" CHECK ("qty" > 0),
        CONSTRAINT "goods_receipt_line_cost_non_negative" CHECK ("cost_santim" >= 0)
      );
      CREATE INDEX "goods_receipt_line_receipt_idx"
        ON "goods_receipt_line" ("goods_receipt_id");
    `);

    // ------------------------------------------------------- sync bookkeeping
    await queryRunner.query(`
      CREATE TABLE "applied_op" (
        "tenant_id"    uuid NOT NULL REFERENCES "tenant"("id"),
        "op_id"        uuid NOT NULL,
        "entity_id"    uuid NOT NULL,
        "entity_type"  text NOT NULL,
        "terminal_id"  uuid NOT NULL,
        "terminal_seq" bigint NOT NULL,
        "applied_at"   timestamptz NOT NULL DEFAULT now(),
        -- The idempotency guarantee itself (ADR-006). A retried push after a dropped
        -- connection re-sends operations already applied; this key turns the second attempt
        -- into a "duplicate" ack instead of a second sale. Guardian G2 depends on it.
        CONSTRAINT "applied_op_pk" PRIMARY KEY ("tenant_id", "op_id")
      );
      CREATE INDEX "applied_op_terminal_idx"
        ON "applied_op" ("tenant_id", "terminal_id", "terminal_seq" DESC);
    `);

    await queryRunner.query(`
      CREATE TABLE "tenant_change_seq" (
        "tenant_id" uuid PRIMARY KEY REFERENCES "tenant"("id"),
        "value"     bigint NOT NULL DEFAULT 0
      );
    `);

    await queryRunner.query(`
      CREATE TABLE "oversell_event" (
        "id"           uuid PRIMARY KEY,
        "tenant_id"    uuid NOT NULL REFERENCES "tenant"("id"),
        "branch_id"    uuid NOT NULL REFERENCES "branch"("id"),
        "product_id"   uuid NOT NULL REFERENCES "product"("id"),
        "batch_id"     uuid REFERENCES "stock_batch"("id"),
        "sale_id"      uuid NOT NULL REFERENCES "sale"("id"),
        "resulting_qty" bigint NOT NULL,
        "observed_at"  timestamptz NOT NULL DEFAULT now(),
        CONSTRAINT "oversell_is_negative" CHECK ("resulting_qty" < 0)
      );
    `);

    // ------------------------------------------------------------------ RLS
    // The isolation backstop (ADR-003). Beneath the application scope guard, so that a
    // single missed predicate in code cannot become a cross-tenant leak.
    //
    // FORCE is not optional: without it the table owner bypasses its own policies, and our
    // integration tests — which must exercise exactly what production does — would pass
    // against an inert mechanism.
    //
    // The policy reads the session setting with the missing_ok flag and passes it through
    // NULLIF. Both parts matter: without missing_ok an unset scope raises, and a custom GUC
    // that has never been set — or whose SET LOCAL has since reverted — reads back as the
    // EMPTY STRING, not NULL, which would fail the ::uuid cast and turn "no scope" into a
    // 500 instead of an empty result. With NULLIF it becomes NULL, NULL compares to nothing,
    // and the default is deny.
    await queryRunner.query(`ALTER TABLE "tenant" ENABLE ROW LEVEL SECURITY;`);
    await queryRunner.query(`ALTER TABLE "tenant" FORCE ROW LEVEL SECURITY;`);
    await queryRunner.query(`
      CREATE POLICY "tenant_isolation" ON "tenant"
        USING ("id" = nullif(current_setting('app.current_tenant', true), '')::uuid)
        WITH CHECK ("id" = nullif(current_setting('app.current_tenant', true), '')::uuid);
    `);

    for (const table of this.tenantScopedTables) {
      await queryRunner.query(`ALTER TABLE "${table}" ENABLE ROW LEVEL SECURITY;`);
      await queryRunner.query(`ALTER TABLE "${table}" FORCE ROW LEVEL SECURITY;`);
      await queryRunner.query(`
        CREATE POLICY "tenant_isolation" ON "${table}"
          USING ("tenant_id" = nullif(current_setting('app.current_tenant', true), '')::uuid)
          WITH CHECK ("tenant_id" = nullif(current_setting('app.current_tenant', true), '')::uuid);
      `);
      // A tenant predicate is in every query plan whether the author wrote one or not, so
      // every table is indexed for it.
      await queryRunner.query(
        `CREATE INDEX "${table}_tenant_idx" ON "${table}" ("tenant_id");`,
      );
    }

    // --------------------------------------------------------------- grants
    // DML only. The application role can read and write rows; it cannot alter the schema,
    // and it cannot drop the policies that constrain it.
    await queryRunner.query(`GRANT USAGE ON SCHEMA public TO ${appUser};`);
    await queryRunner.query(
      `GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO ${appUser};`,
    );
    // Deliberately no DELETE grant anywhere: nothing in this system is physically deleted.
    // Relational rows get deleted_at; regulated records get tombstone events (NFR-5.3).
    await queryRunner.query(
      `ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE ON TABLES TO ${appUser};`,
    );
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    // Production migrations are forward-only (docs/06 §6.2); `down` exists for local
    // iteration and CI teardown, not as a production rollback path.
    const tables = [
      'oversell_event',
      'tenant_change_seq',
      'applied_op',
      'goods_receipt_line',
      'goods_receipt',
      'payment',
      'sale_line',
      'sale',
      'stock_batch',
      'product',
      'user_branch',
      'app_user',
      'branch',
      'tenant',
    ];
    for (const table of tables) {
      await queryRunner.query(`DROP TABLE IF EXISTS "${table}" CASCADE;`);
    }
  }
}
