import { MigrationInterface, QueryRunner } from 'typeorm';

/**
 * Price tiers — a retail and a wholesale price (FR-19, ADR-037).
 *
 * Many pharmacies sell to walk-in customers at one price and to clinics and organisations
 * at another. Until now a product had one price, so the cashier worked the other out in
 * their head — and the cash-up had no way to tell a wholesale sale from an undercharge.
 *
 * Two nullable columns, each of which the previous release ignores:
 *
 *   - `product.wholesale_price_santim` is null on every existing product: no wholesale
 *     price, which is what they have.
 *   - `sale.price_tier` is null on every sale ever recorded, and null means retail — which
 *     is what they were.
 *
 * A pack's wholesale price lives inside `product.packs` (ADR-030), so it needs no column.
 */
export class PriceTiers1760000000000 implements MigrationInterface {
  name = 'PriceTiers1760000000000';

  public async up(queryRunner: QueryRunner): Promise<void> {
    await queryRunner.query(`
      ALTER TABLE "product"
        ADD COLUMN "wholesale_price_santim" bigint,
        ADD CONSTRAINT "product_wholesale_price_non_negative"
          CHECK ("wholesale_price_santim" IS NULL OR "wholesale_price_santim" >= 0);
    `);
    await queryRunner.query(`
      ALTER TABLE "sale"
        ADD COLUMN "price_tier" text,
        -- NULL is retail. Written as NULL rather than 'retail' so there is one way to say
        -- "an ordinary sale", and every sale before this already says it.
        ADD CONSTRAINT "sale_price_tier_known"
          CHECK ("price_tier" IS NULL OR "price_tier" IN ('retail', 'wholesale'));
    `);
  }

  public async down(queryRunner: QueryRunner): Promise<void> {
    // Local iteration only: production migrations are forward-only (docs/06 §6.2).
    await queryRunner.query(`
      ALTER TABLE "sale"
        DROP CONSTRAINT IF EXISTS "sale_price_tier_known",
        DROP COLUMN IF EXISTS "price_tier";
    `);
    await queryRunner.query(`
      ALTER TABLE "product"
        DROP CONSTRAINT IF EXISTS "product_wholesale_price_non_negative",
        DROP COLUMN IF EXISTS "wholesale_price_santim";
    `);
  }
}
