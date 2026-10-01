import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * Payment screenshots stored in Postgres, until object storage is affordable (ADR-028).
 *
 * `payment_proof_blob` holds the ciphertext of each screenshot (ProofStorageService.seal), by
 * the same storage key object storage would use, so moving to R2/B2 later is a copy of these
 * rows into a bucket and one environment variable — no change to `payment_proof`.
 *
 * **No grant to the application role.** A pharmacy never reads a screenshot back; writes and
 * reads go through the platform connection (runAsPlatform), which logs each use. RLS is still
 * enabled and forced with the usual tenant policy, so a future grant cannot silently cross
 * tenants.
 *
 * `payment_proof.image_deleted_at` records that the platform deleted the image after deciding
 * — the row itself, the amount, the decision and who made it are kept, because those are the
 * billing record; the picture of somebody's bank app is not.
 */
export class PaymentProofBlobs1759600000000 implements MigrationInterface {
  name = 'PaymentProofBlobs1759600000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      CREATE TABLE "payment_proof_blob" (
        "storage_key" text PRIMARY KEY,
        "tenant_id"   uuid NOT NULL REFERENCES "tenant"("id"),
        "bytes"       bytea NOT NULL,
        "created_at"  timestamptz NOT NULL DEFAULT now()
      );
      CREATE INDEX "payment_proof_blob_tenant_idx" ON "payment_proof_blob" ("tenant_id");

      ALTER TABLE "payment_proof_blob" ENABLE ROW LEVEL SECURITY;
      ALTER TABLE "payment_proof_blob" FORCE ROW LEVEL SECURITY;
      CREATE POLICY "tenant_isolation" ON "payment_proof_blob"
        USING ("tenant_id" = nullif(current_setting('app.current_tenant', true), '')::uuid)
        WITH CHECK ("tenant_id" = nullif(current_setting('app.current_tenant', true), '')::uuid);

      ALTER TABLE "payment_proof" ADD COLUMN "image_deleted_at" timestamptz;
    `);
    // Deliberately no GRANT: the default privileges from InitialSchema would otherwise give
    // the app role SELECT/INSERT/UPDATE on this new table.
    const appUser = process.env.DATABASE_APP_USER ?? 'pharmaet_app';
    await queryRunner.query(`REVOKE ALL ON "payment_proof_blob" FROM ${appUser};`);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      ALTER TABLE "payment_proof" DROP COLUMN IF EXISTS "image_deleted_at";
      DROP TABLE IF EXISTS "payment_proof_blob";
    `);
  }
}
