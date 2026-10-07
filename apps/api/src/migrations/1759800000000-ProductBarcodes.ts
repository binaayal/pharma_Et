import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * Product barcodes (FR-13, ADR-031).
 *
 * The counter scans a box instead of typing a name, so a product has to know which barcodes
 * are it. One medicine comes from several manufacturers, each with its own GTIN, so this is
 * a list.
 *
 * One additive column, defaulting to an empty list: every existing product is exactly what
 * it was — found by name — and the previous release never reads the column.
 *
 * Stored canonical (a GTIN as 14 digits; see `canonicalBarcode` in the contract), so the
 * EAN-13 printed on a box and the GTIN inside its DataMatrix are one value here.
 *
 * "One barcode, one product" within a pharmacy is enforced by the service that writes this
 * column, inside the write's transaction, rather than by a constraint: the rule spans rows
 * and a JSON list, which a CHECK cannot see. The GIN index is what makes that lookup — and
 * nothing else — cheap.
 */
export class ProductBarcodes1759800000000 implements MigrationInterface {
  name = 'ProductBarcodes1759800000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      ALTER TABLE "product"
        ADD COLUMN "barcodes" jsonb NOT NULL DEFAULT '[]'::jsonb,
        ADD CONSTRAINT "product_barcodes_is_list" CHECK (jsonb_typeof("barcodes") = 'array');
    `);
    await queryRunner.query(`
      CREATE INDEX "product_barcodes_idx" ON "product" USING GIN ("barcodes" jsonb_path_ops);
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    // Local iteration only: production migrations are forward-only (docs/06 §6.2).
    await queryRunner.query(`DROP INDEX IF EXISTS "product_barcodes_idx";`);
    await queryRunner.query(`
      ALTER TABLE "product"
        DROP CONSTRAINT IF EXISTS "product_barcodes_is_list",
        DROP COLUMN IF EXISTS "barcodes";
    `);
  }
}
