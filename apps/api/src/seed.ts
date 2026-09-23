import 'reflect-metadata';
import * as argon2 from 'argon2';
import * as dotenv from 'dotenv';
import { DataSource, EntityManager } from 'typeorm';
import { uuidv7 } from 'uuidv7';
import { firstRow } from './common/db/raw-query';
import { ALL_ENTITIES, AppUser, Branch, Product, StockBatch, Tenant, UserBranch } from './entities';

dotenv.config();

/**
 * Development and CI seed.
 *
 * It creates TWO tenants, always. Single-tenant data hides exactly the class of bug that is
 * an S1 here: a query missing its tenant predicate looks perfectly correct until a second
 * tenant exists (docs/05-qa §11). Every environment is multi-tenant by construction so that
 * cross-tenant leakage is visible the first time anyone looks.
 */

interface SeedTenant {
  code: string;
  name: string;
  branches: string[];
  products: Array<{ name: string; unit: string; priceSantim: number; controlled?: boolean }>;
}

const TENANTS: SeedTenant[] = [
  {
    code: 'abay',
    name: 'Abay Pharmacy',
    branches: ['Bole Branch', 'Piassa Branch'],
    products: [
      { name: 'Paracetamol 500mg', unit: 'tablet', priceSantim: 150 },
      { name: 'Amoxicillin 250mg', unit: 'capsule', priceSantim: 450 },
      { name: 'ORS Sachet', unit: 'sachet', priceSantim: 900 },
      // Flagged controlled so isolation and routing can be exercised now. Dispensing it is
      // Phase 2 and gated on A-1 — nothing in Phase 0 writes a ledger event.
      { name: 'Diazepam 5mg', unit: 'tablet', priceSantim: 1200, controlled: true },
    ],
  },
  {
    code: 'tana',
    name: 'Tana Pharmacy',
    branches: ['Bahir Dar Branch', 'Gondar Branch'],
    products: [
      { name: 'Ibuprofen 400mg', unit: 'tablet', priceSantim: 200 },
      { name: 'Metformin 500mg', unit: 'tablet', priceSantim: 350 },
    ],
  },
];

/** Dev-only credentials. Production users are provisioned through onboarding, never seeded. */
const DEV_PIN = '1234';
const DEV_PASSWORD = 'owner-dev-password';
const DEV_PLATFORM_PASSWORD = 'platform-dev-password';

async function seedTenant(em: EntityManager, spec: SeedTenant): Promise<void> {
  const tenantId = uuidv7();
  await em.getRepository(Tenant).insert({
    id: tenantId,
    name: spec.name,
    code: spec.code,
    status: 'active',
    deletedAt: null,
  });
  await em.query(`INSERT INTO tenant_change_seq (tenant_id, value) VALUES ($1, 0)`, [tenantId]);
  // Every tenant has a subscription, so "is this pharmacy paid up?" always has an answer —
  // the question gates every management write in the system (ADR-016).
  await em.query(
    `INSERT INTO subscription (id, tenant_id, state, current_period_end, price_santim)
     VALUES ($1, $2, 'active', now() + interval '30 days', 100000)`,
    [uuidv7(), tenantId],
  );

  const nextSeq = async (): Promise<number> => {
    const row = firstRow<{ value: string }>(
      await em.query(
        `UPDATE tenant_change_seq SET value = value + 1 WHERE tenant_id = $1 RETURNING value`,
        [tenantId],
      ),
    );
    return Number(row!.value);
  };

  const branchIds: string[] = [];
  for (const name of spec.branches) {
    const id = uuidv7();
    branchIds.push(id);
    await em.getRepository(Branch).insert({
      id,
      tenantId,
      name,
      address: 'Addis Ababa, Ethiopia',
      changeSeq: await nextSeq(),
      deletedAt: null,
    });
  }

  const [pinHash, passwordHash] = await Promise.all([
    argon2.hash(DEV_PIN, { type: argon2.argon2id }),
    argon2.hash(DEV_PASSWORD, { type: argon2.argon2id }),
  ]);

  const users: Array<{ username: string; role: 'owner' | 'branch_manager' | 'cashier' }> = [
    { username: 'owner', role: 'owner' },
    { username: 'manager', role: 'branch_manager' },
    { username: 'cashier', role: 'cashier' },
  ];

  for (const spec2 of users) {
    const id = uuidv7();
    await em.getRepository(AppUser).insert({
      id,
      tenantId,
      username: spec2.username,
      displayName: `${spec.name} ${spec2.username}`,
      role: spec2.role,
      pinHash,
      passwordHash: spec2.role === 'owner' ? passwordHash : null,
      changeSeq: await nextSeq(),
      deletedAt: null,
    });
    // Owners are all-branch by role and need no rows; everyone else is scoped to branch one.
    if (spec2.role !== 'owner') {
      await em.getRepository(UserBranch).insert({
        id: uuidv7(),
        tenantId,
        userId: id,
        branchId: branchIds[0],
        changeSeq: await nextSeq(),
        deletedAt: null,
      });
    }
  }

  for (const product of spec.products) {
    const productId = uuidv7();
    await em.getRepository(Product).insert({
      id: productId,
      tenantId,
      name: product.name,
      unit: product.unit,
      isControlled: product.controlled ?? false,
      psychotropicClass: product.controlled ? 'schedule-iv' : null,
      currentPriceSantim: product.priceSantim,
      changeSeq: await nextSeq(),
      deletedAt: null,
    });

    // Controlled substances get no mutable stock row — their quantity is a projection over
    // the ledger (BR-3.3), and the ledger does not exist until Phase 2.
    if (product.controlled) continue;

    // Two batches with different expiry dates, so FEFO selection has something to choose
    // between the first time anyone runs the app (AC-3.2).
    const expiries = ['2027-03-31', '2026-12-31'];
    for (const [index, expiry] of expiries.entries()) {
      await em.getRepository(StockBatch).insert({
        id: uuidv7(),
        tenantId,
        branchId: branchIds[0],
        productId,
        lotNo: `LOT-${spec.code.toUpperCase()}-${index + 1}`,
        expiryDate: expiry,
        qtyOnHand: 100,
        changeSeq: await nextSeq(),
        deletedAt: null,
      });
    }
  }

  console.log(`  ✓ ${spec.name} (code: ${spec.code}) — ${spec.branches.length} branches`);
}

/**
 * A development Platform Admin (us).
 *
 * Seeded rather than exposed through an endpoint: an API that mints platform identities is
 * an escalation path however carefully it is guarded. In production an admin is created by
 * an operator running a one-off statement.
 */
async function seedPlatformAdmin(em: EntityManager): Promise<void> {
  const existing = await em.query(`SELECT count(*)::int AS n FROM platform_admin`);
  const rows = Array.isArray(existing[0]) ? existing[0] : existing;
  if (Number(rows[0].n) > 0) return;

  await em.query(
    `INSERT INTO platform_admin (id, email, display_name, password_hash)
     VALUES ($1, $2, $3, $4)`,
    [
      uuidv7(),
      'admin@pharmaet.local',
      'Platform Admin',
      await argon2.hash(DEV_PLATFORM_PASSWORD, { type: argon2.argon2id }),
    ],
  );
  console.log('  ✓ platform admin (admin@pharmaet.local)');
}

async function main(): Promise<void> {
  const dataSource = new DataSource({
    type: 'postgres',
    url: process.env.DATABASE_URL,
    entities: ALL_ENTITIES,
    synchronize: false,
  });
  await dataSource.initialize();

  const existing = firstRow<{ n: number }>(
    await dataSource.query(`SELECT count(*)::int AS n FROM tenant`),
  );
  if ((existing?.n ?? 0) > 0) {
    console.log('database already seeded; run ./scripts/dev-db.sh reset to start over');
    await dataSource.destroy();
    return;
  }

  console.log('seeding two tenants (multi-tenant by construction — docs/05-qa §11):');
  await dataSource.transaction(async (em) => {
    await seedPlatformAdmin(em);
    for (const spec of TENANTS) await seedTenant(em, spec);
  });

  console.log(`\nlogin with:  tenantCode=abay  username=cashier  secret=${DEV_PIN}`);
  console.log(`             tenantCode=abay  username=owner    secret=${DEV_PASSWORD}`);
  console.log(`             tenantCode=tana  username=owner    secret=${DEV_PASSWORD}`);
  console.log(`platform:    admin@pharmaet.local / ${DEV_PLATFORM_PASSWORD}\n`);

  await dataSource.destroy();
}

void main().catch((error) => {
  console.error(error);
  process.exit(1);
});
