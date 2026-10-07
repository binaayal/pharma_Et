import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * Sell units — break-bulk (FR-11, ADR-030).
 *
 * A pharmacy buys a box of 100 and sells a strip, a tablet, or the box. Until now a product
 * had one unit and every quantity was a count of it, so receiving five boxes meant typing
 * 500 and a box price that was not a multiple of the tablet price could not be recorded.
 *
 * Three additive columns, each of which the previous release can ignore:
 *
 *   - `product.packs` defaults to an empty list, so every existing product is exactly what
 *     it was: sold in its base unit only.
 *   - `sale_line.pack_size` and `goods_receipt_line.pack_size` are null for every row ever
 *     written, and null means "in the base unit" — which is what those rows are.
 *
 * `sale_line_total_consistent` is deliberately untouched. A line sold by the box carries the
 * box count in `qty` and the box price in `unit_price_santim`, so `total = qty × unit price`
 * still holds to the santim. That is the reason the pack is stored beside the line rather
 * than multiplied into it.
 */
export class SellUnits1759700000000 implements MigrationInterface {
  name = 'SellUnits1759700000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      ALTER TABLE "product"
        ADD COLUMN "packs" jsonb NOT NULL DEFAULT '[]'::jsonb,
        ADD CONSTRAINT "product_packs_is_list" CHECK (jsonb_typeof("packs") = 'array');
    `);

    await queryRunner.query(`
      ALTER TABLE "sale_line"
        ADD COLUMN "pack_size" integer,
        ADD COLUMN "pack_name" text,
        -- A pack of one is the base unit and is written as NULL, so there is exactly one way
        -- to say "sold loose" and a report never has to treat 1 and NULL as the same thing.
        ADD CONSTRAINT "sale_line_pack_size_valid"
          CHECK ("pack_size" IS NULL OR "pack_size" BETWEEN 2 AND 100000);
    `);

    await queryRunner.query(`
      ALTER TABLE "goods_receipt_line"
        ADD COLUMN "pack_size" integer,
        ADD CONSTRAINT "goods_receipt_line_pack_size_valid"
          CHECK ("pack_size" IS NULL OR "pack_size" BETWEEN 2 AND 100000);
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    // Local iteration only: production migrations are forward-only (docs/06 §6.2).
    await queryRunner.query(`
      ALTER TABLE "goods_receipt_line"
        DROP CONSTRAINT IF EXISTS "goods_receipt_line_pack_size_valid",
        DROP COLUMN IF EXISTS "pack_size";
    `);
    await queryRunner.query(`
      ALTER TABLE "sale_line"
        DROP CONSTRAINT IF EXISTS "sale_line_pack_size_valid",
        DROP COLUMN IF EXISTS "pack_name",
        DROP COLUMN IF EXISTS "pack_size";
    `);
    await queryRunner.query(`
      ALTER TABLE "product"
        DROP CONSTRAINT IF EXISTS "product_packs_is_list",
        DROP COLUMN IF EXISTS "packs";
    `);
  }
}
