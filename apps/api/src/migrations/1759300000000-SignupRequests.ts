import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * Sign-up requests: the anti-abuse gate in front of onboarding (ADR-022).
 *
 * A pharmacy asks for an account from the app; a person at the platform calls the number
 * and decides. Self-signup creates a **request**, never a tenant — the prototype's
 * onboarding flow (screens 01, 02, 22) and Vision §4's manual verification.
 *
 * **No `tenant_id`, deliberately.** Until it is approved there is no tenant, and a rejected
 * request never becomes one. It is written by an anonymous caller and read only by the
 * platform, so it is on the CI list of known non-tenant tables beside `login_attempt`.
 */
export class SignupRequests1759300000000 implements MigrationInterface {
  name = 'SignupRequests1759300000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      CREATE TABLE "signup_request" (
        "id"             uuid PRIMARY KEY,
        "pharmacy_name"  text NOT NULL,
        "owner_name"     text NOT NULL,
        "phone"          text NOT NULL,
        "city"           text NOT NULL,
        "branch_band"    text NOT NULL,
        "status"         text NOT NULL DEFAULT 'pending',
        "submitted_at"   timestamptz NOT NULL DEFAULT now(),
        "decided_at"     timestamptz,
        "decided_by"     uuid REFERENCES "platform_admin"("id"),
        "decision_reason" text,
        -- Set on approval: the account this request became.
        "tenant_id_created" uuid REFERENCES "tenant"("id"),

        CONSTRAINT "signup_request_status_check"
          CHECK ("status" IN ('pending', 'approved', 'rejected')),
        CONSTRAINT "signup_request_band_check"
          CHECK ("branch_band" IN ('1', '2-3', '4+')),
        -- A decision has a decider and a time; a pending request has neither.
        CONSTRAINT "signup_request_decided_check"
          CHECK (("status" = 'pending') = ("decided_at" IS NULL))
      );

      -- One open request per phone number: the cheapest brake on somebody filling the queue.
      CREATE UNIQUE INDEX "signup_request_one_pending_per_phone"
        ON "signup_request" ("phone") WHERE "status" = 'pending';
      CREATE INDEX "signup_request_queue_idx"
        ON "signup_request" ("status", "submitted_at");
    `);
    // No grant to the tenant role: every read and write goes through the platform
    // connection (runAsPlatform), which logs each use.
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`DROP TABLE IF EXISTS "signup_request" CASCADE;`);
  }
}
