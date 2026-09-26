import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * The controlled-substance ledger's read model (FR-6, BR-3.3, docs/04 §6.3; ADR-024).
 *
 * The ledger itself needs no new table: `controlled.*` events go into the existing
 * append-only `event` store on the reserved `controlled_stock` stream, under the same
 * immutability triggers G3 already asserts. What is new is the projection — current
 * controlled stock per (tenant, branch, product), maintained in the transaction that appends
 * each event and rebuildable from the events at any time. The events are the truth; this
 * table is a cache of a sum.
 *
 * Built ahead of A-1 by owner decision and inert until the `CONTROLLED_DISPENSING` switch
 * is on (ADR-024). No retention rule is added: the event store never deletes at all.
 */
export class ControlledLedger1759400000000 implements MigrationInterface {
  name = 'ControlledLedger1759400000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    const appUser = process.env.DATABASE_APP_USER ?? 'pharmaet_app';

    await queryRunner.query(`
      CREATE TABLE "controlled_stock_view" (
        "id"           uuid PRIMARY KEY,
        "tenant_id"    uuid NOT NULL REFERENCES "tenant"("id"),
        "created_at"   timestamptz NOT NULL DEFAULT now(),
        "updated_at"   timestamptz NOT NULL DEFAULT now(),
        "deleted_at"   timestamptz,
        "row_version"  integer NOT NULL DEFAULT 1,
        "change_seq"   bigint NOT NULL DEFAULT 0,

        "branch_id"    uuid NOT NULL REFERENCES "branch"("id"),
        "product_id"   uuid NOT NULL REFERENCES "product"("id"),
        -- Signed on purpose. A dispense taken offline is recorded even if the projection
        -- says the shelf was empty: the box has already left, and the ledger's job is to
        -- say so, not to refuse to remember it.
        "qty_on_hand"  bigint NOT NULL DEFAULT 0,
        -- The newest event folded in, so a rebuild can be checked against it.
        "as_of_seq"    bigint NOT NULL DEFAULT 0,

        CONSTRAINT "controlled_stock_view_one_row"
          UNIQUE ("tenant_id", "branch_id", "product_id")
      );
    `);

    await queryRunner.query(`ALTER TABLE "controlled_stock_view" ENABLE ROW LEVEL SECURITY;`);
    await queryRunner.query(`ALTER TABLE "controlled_stock_view" FORCE ROW LEVEL SECURITY;`);
    await queryRunner.query(`
      CREATE POLICY "tenant_isolation" ON "controlled_stock_view"
        USING ("tenant_id" = nullif(current_setting('app.current_tenant', true), '')::uuid)
        WITH CHECK ("tenant_id" = nullif(current_setting('app.current_tenant', true), '')::uuid);
    `);
    await queryRunner.query(
      `GRANT SELECT, INSERT, UPDATE ON "controlled_stock_view" TO ${appUser};`,
    );
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`DROP TABLE IF EXISTS "controlled_stock_view" CASCADE;`);
  }
}
