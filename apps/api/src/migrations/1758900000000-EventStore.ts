import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * The append-only event store (docs/04 §5.6, ADR-004).
 *
 * This is the second of the system's two persistence models: ordinary state is mutable and
 * soft-deleted, while this log is immutable and never physically removed. Phase 2 builds the
 * store and the general audit log; the controlled-substance event types and everything
 * regulatory wait for A-1 (ADR-015).
 *
 * **Immutability is enforced by the database, three ways, because one is not enough:**
 *
 *   1. the application role holds no UPDATE and no DELETE on this table, so ordinary code
 *      cannot mutate a row even with a bug;
 *   2. a trigger raises on UPDATE and DELETE, which also stops the OWNER — the role that
 *      runs migrations and support scripts, and the one a well-meaning fix is most likely to
 *      be run as at 2am during an incident;
 *   3. RLS, as everywhere, so none of this leaks across tenants.
 *
 * The first alone would leave the owner free to "just fix one row", which is precisely the
 * act an audit log exists to make impossible. Grants express intent; the trigger enforces it.
 */
export class EventStore1758900000000 implements MigrationInterface {
  name = 'EventStore1758900000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    const appUser = process.env.DATABASE_APP_USER ?? 'pharmaet_app';

    await queryRunner.query(`
      CREATE TABLE "event" (
        "id"           uuid PRIMARY KEY,
        "tenant_id"    uuid NOT NULL REFERENCES "tenant"("id"),
        "branch_id"    uuid REFERENCES "branch"("id"),

        -- What this log is FOR. 'audit' is the general who-did-what (Vision §2.1.1);
        -- 'controlled_stock' is reserved and unused until A-1 clears (ADR-015).
        "stream"       text NOT NULL,
        -- The aggregate this event belongs to: a product, a user, a branch.
        "stream_id"    uuid NOT NULL,
        -- Position within the stream. Monotonic from 1, with no gaps: a gap in an audit
        -- trail is indistinguishable from a deletion, which is the one thing this table
        -- must be able to rule out.
        "seq"          bigint NOT NULL,

        "event_type"   text NOT NULL,
        "payload"      jsonb NOT NULL DEFAULT '{}'::jsonb,

        -- Who, where, when. An audit entry that cannot answer all three answers none.
        "actor_id"     uuid NOT NULL,
        "terminal_id"  uuid,
        "occurred_at"  timestamptz NOT NULL,
        "recorded_at"  timestamptz NOT NULL DEFAULT now(),

        -- Idempotency, exactly as the sync path uses it: an event replayed by a retried
        -- push must not append twice (ADR-006).
        "op_id"        uuid,

        CONSTRAINT "event_seq_positive" CHECK ("seq" >= 1),
        CONSTRAINT "event_stream_known" CHECK ("stream" IN ('audit', 'controlled_stock')),
        -- No two events may occupy the same position in a stream. This is what makes the
        -- ordering a fact rather than an intention.
        CONSTRAINT "event_stream_position_unique" UNIQUE ("tenant_id", "stream", "stream_id", "seq")
      );

      CREATE INDEX "event_tenant_idx" ON "event" ("tenant_id");
      CREATE INDEX "event_stream_idx" ON "event" ("tenant_id", "stream", "occurred_at" DESC);
      CREATE INDEX "event_actor_idx" ON "event" ("tenant_id", "actor_id", "occurred_at" DESC);
      -- Partial and unique: an op_id appears at most once per tenant, and most audit events
      -- have none (they originate on the server, not from a pushed operation).
      CREATE UNIQUE INDEX "event_op_id_unique"
        ON "event" ("tenant_id", "op_id") WHERE "op_id" IS NOT NULL;
    `);

    // ------------------------------------------------------------- immutability
    await queryRunner.query(`
      CREATE OR REPLACE FUNCTION event_is_append_only() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION
          'the event log is append-only: % on event is not permitted. Append a compensating event instead.',
          TG_OP
          USING ERRCODE = 'restrict_violation';
      END;
      $$ LANGUAGE plpgsql;
    `);
    await queryRunner.query(`
      CREATE TRIGGER event_no_update
        BEFORE UPDATE ON "event"
        FOR EACH ROW EXECUTE FUNCTION event_is_append_only();
    `);
    await queryRunner.query(`
      CREATE TRIGGER event_no_delete
        BEFORE DELETE ON "event"
        FOR EACH ROW EXECUTE FUNCTION event_is_append_only();
    `);
    // TRUNCATE bypasses row triggers entirely, so it needs its own statement-level guard.
    // Without it, the one command that can empty the table in a single line is the one
    // command nothing stops.
    await queryRunner.query(`
      CREATE TRIGGER event_no_truncate
        BEFORE TRUNCATE ON "event"
        FOR EACH STATEMENT EXECUTE FUNCTION event_is_append_only();
    `);

    // --------------------------------------------------------------------- RLS
    await queryRunner.query(`ALTER TABLE "event" ENABLE ROW LEVEL SECURITY;`);
    await queryRunner.query(`ALTER TABLE "event" FORCE ROW LEVEL SECURITY;`);
    await queryRunner.query(`
      CREATE POLICY "tenant_isolation" ON "event"
        USING ("tenant_id" = nullif(current_setting('app.current_tenant', true), '')::uuid)
        WITH CHECK ("tenant_id" = nullif(current_setting('app.current_tenant', true), '')::uuid);
    `);

    // ------------------------------------------------------------------ grants
    // SELECT and INSERT only. Every other table in this schema grants UPDATE; this one
    // deliberately does not, and the omission is the point.
    await queryRunner.query(`GRANT SELECT, INSERT ON "event" TO ${appUser};`);
    await queryRunner.query(`REVOKE UPDATE, DELETE, TRUNCATE ON "event" FROM ${appUser};`);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    // Dropping the table is permitted; mutating its rows is not. A migration that removes
    // the log entirely is a visible, reviewed schema change — an UPDATE that quietly edits
    // one row is not, and that asymmetry is the one that matters.
    await queryRunner.query(`DROP TRIGGER IF EXISTS event_no_truncate ON "event";`);
    await queryRunner.query(`DROP TRIGGER IF EXISTS event_no_delete ON "event";`);
    await queryRunner.query(`DROP TRIGGER IF EXISTS event_no_update ON "event";`);
    await queryRunner.query(`DROP TABLE IF EXISTS "event" CASCADE;`);
    await queryRunner.query(`DROP FUNCTION IF EXISTS event_is_append_only();`);
  }
}
