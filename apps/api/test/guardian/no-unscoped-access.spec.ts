import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative, resolve } from 'node:path';

/**
 * NO UNSCOPED DATABASE ACCESS (ADR-007, docs/05-qa §12 gate 3).
 *
 * The tenant-isolation guarantee rests on one structural fact: every query runs on an
 * EntityManager obtained from ScopedDbService, inside a transaction that has already applied
 * `SET LOCAL app.current_tenant`. A module that grabs the DataSource directly steps around
 * that and loses the scope — and because RLS then denies everything, the symptom is usually
 * "my query returns nothing", which gets "fixed" by connecting as a more privileged role.
 * That is how a tenant leak gets introduced with the best of intentions.
 *
 * A static check, rather than a runtime one, because the failure has to be impossible to
 * merge, not merely detectable once it runs.
 */

const SRC = resolve(__dirname, '../../src');

/**
 * The only files permitted to touch a DataSource, each for a reason that cannot be served
 * by the scoped path. Adding to this list is a controlled-artifact change (docs/06 §7).
 */
const ALLOWED = new Set([
  // Owns the mechanism itself.
  'common/db/scoped-db.service.ts',
  // Wires the two connections, and is where the non-owner role is chosen.
  'app.module.ts',
  // Migrations run as the owner, before any tenant exists.
  'config/data-source.ts',
  // Development seeding, outside request scope by nature.
  'seed.ts',
]);

const FORBIDDEN: Array<{ pattern: RegExp; why: string }> = [
  {
    pattern: /\bInjectDataSource\b/,
    why: 'injects a raw DataSource; use ScopedDbService so RLS scope is applied',
  },
  {
    pattern: /\bgetDataSourceToken\b/,
    why: 'resolves a raw DataSource; use ScopedDbService',
  },
  {
    pattern: /\bInjectRepository\b/,
    why:
      'binds a repository to the root EntityManager, which has no tenant scope; take the ' +
      'EntityManager from ScopedDbService.runInScope instead',
  },
  {
    pattern: /\bnew DataSource\b/,
    why: 'opens its own connection, bypassing both the scoped path and the role split',
  },
];

function walk(dir: string): string[] {
  return readdirSync(dir).flatMap((entry) => {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) return walk(full);
    return full.endsWith('.ts') ? [full] : [];
  });
}

describe('no unscoped database access', () => {
  const files = walk(SRC).filter((f) => !f.includes('/migrations/'));

  it('finds source files to check (guards against a silently empty scan)', () => {
    expect(files.length).toBeGreaterThan(10);
  });

  it.each(FORBIDDEN)('nothing outside the allow-list uses $pattern', ({ pattern, why }) => {
    const offenders = files
      .map((file) => ({ file, rel: relative(SRC, file) }))
      .filter(({ rel }) => !ALLOWED.has(rel))
      .filter(({ file }) => pattern.test(readFileSync(file, 'utf8')))
      .map(({ rel }) => rel);

    expect(offenders).toEqual([]);
    if (offenders.length) throw new Error(`${offenders.join(', ')}: ${why}`);
  });

  it('keeps the allow-list honest — every entry still exists', () => {
    const present = new Set(files.map((f) => relative(SRC, f)));
    for (const allowed of ALLOWED) {
      expect(present.has(allowed)).toBe(true);
    }
  });

  it('every RLS-protected table is covered by a policy in the migration', () => {
    // The other half of the same guarantee: a table created without its policy has no
    // isolation at all, and no application test would notice, because application queries
    // are scoped anyway.
    const migration = readFileSync(
      resolve(SRC, 'migrations/1758500000000-InitialSchema.ts'),
      'utf8',
    );
    const created = [...migration.matchAll(/CREATE TABLE "(\w+)"/g)].map((m) => m[1]);
    const scoped = [
      ...migration.matchAll(/private readonly tenantScopedTables = \[([\s\S]*?)\]/g),
    ][0][1]
      .split(',')
      .map((s) => s.trim().replace(/['"]/g, ''))
      .filter(Boolean);

    // `tenant` is policied separately (it is keyed on id, not tenant_id).
    const uncovered = created.filter((t) => t !== 'tenant' && !scoped.includes(t));
    expect(uncovered).toEqual([]);
  });
});
