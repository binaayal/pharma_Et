import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * Where an owner's end-of-day summary is delivered (FR-17, ADR-039).
 *
 * One row per person who has asked for the summary on Telegram: which chat it goes to, the
 * one-time code that proves the chat is theirs while they are linking it, and the last day
 * a summary was sent for — so a dispatch that runs twice sends once.
 *
 * Additive: a new table the previous release never touches.
 *
 * Tenant-isolated like every other table. The two things that are not a tenant request —
 * Telegram's webhook, which arrives with a code and no session, and the nightly dispatch,
 * which walks every pharmacy — read it through the platform connection, which states its
 * reason and logs it (BR-2.2).
 */
export class TelegramSummary1760200000000 implements MigrationInterface {
  name = 'TelegramSummary1760200000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    const appUser = process.env.DATABASE_APP_USER ?? 'pharmaet_app';

    await queryRunner.query(`
      CREATE TABLE "telegram_link" (
        "id"              uuid PRIMARY KEY,
        "tenant_id"       uuid NOT NULL REFERENCES "tenant"("id"),
        "user_id"         uuid NOT NULL REFERENCES "app_user"("id"),
        -- Null until the person has pressed Start in the bot, and again after they stop.
        "chat_id"         bigint,
        -- SHA-256 of the one-time code, never the code: a leaked table links nobody.
        "code_hash"       text,
        "code_expires_at" timestamptz,
        -- Which language to write to this person in. A delivery preference, not a property
        -- of any record: nothing is stored *in* a language or a calendar (BR-10.2).
        "message_language" text NOT NULL DEFAULT 'en',
        "linked_at"       timestamptz,
        -- The shop's day the last summary was sent for. A second dispatch for it sends nothing.
        "last_sent_for"   date,
        "created_at"      timestamptz NOT NULL DEFAULT now(),
        "updated_at"      timestamptz NOT NULL DEFAULT now(),
        "deleted_at"      timestamptz,
        -- The columns every tenant table carries (docs/04 §2). No terminal syncs this
        -- table, so change_seq stays 0; it is here so the convention has no exceptions.
        "row_version"     integer NOT NULL DEFAULT 1,
        "change_seq"      bigint NOT NULL DEFAULT 0,
        CONSTRAINT "telegram_link_language_known" CHECK ("message_language" IN ('en', 'am'))
      );
      -- One link per person. Asking again replaces the code; it does not add a row.
      CREATE UNIQUE INDEX "telegram_link_user_uq" ON "telegram_link" ("tenant_id", "user_id");
      CREATE UNIQUE INDEX "telegram_link_code_uq" ON "telegram_link" ("code_hash")
        WHERE "code_hash" IS NOT NULL;
      CREATE INDEX "telegram_link_chat_idx" ON "telegram_link" ("chat_id")
        WHERE "chat_id" IS NOT NULL;
    `);

    await queryRunner.query(`ALTER TABLE "telegram_link" ENABLE ROW LEVEL SECURITY;`);
    await queryRunner.query(`ALTER TABLE "telegram_link" FORCE ROW LEVEL SECURITY;`);
    await queryRunner.query(`
      CREATE POLICY "tenant_isolation" ON "telegram_link"
        USING ("tenant_id" = nullif(current_setting('app.current_tenant', true), '')::uuid)
        WITH CHECK ("tenant_id" = nullif(current_setting('app.current_tenant', true), '')::uuid);
    `);
    await queryRunner.query(`GRANT SELECT, INSERT, UPDATE ON "telegram_link" TO ${appUser};`);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    // Local iteration only: production migrations are forward-only (docs/06 §6.2).
    await queryRunner.query(`DROP TABLE IF EXISTS "telegram_link" CASCADE;`);
  }
}
