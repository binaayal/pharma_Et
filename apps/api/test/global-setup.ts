import { execSync } from 'node:child_process';
import { resolve } from 'node:path';
import * as dotenv from 'dotenv';
import { Client } from 'pg';

/**
 * Creates the test database if it does not exist and brings its schema up to date.
 *
 * Doing this here rather than in a README step means `pnpm test:guardian` works on a clean
 * checkout, and — more importantly — that the schema under test is always the one the
 * migrations produce. A hand-maintained test schema drifts, and the first thing it stops
 * reproducing is the RLS policies, which is precisely what these suites exist to verify.
 */
export default async function globalSetup(): Promise<void> {
  dotenv.config({ path: resolve(__dirname, '../.env.test') });
  dotenv.config({ path: resolve(__dirname, '../.env') });

  const configured = process.env.TEST_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!configured) throw new Error('DATABASE_URL is not set; cannot prepare the test database');

  const url = new URL(configured);
  const database = url.pathname.replace(/^\//, '');
  const testDatabase =
    process.env.TEST_DATABASE_URL || database.endsWith('_test') ? database : `${database}_test`;

  if (testDatabase !== database) {
    const admin = new URL(configured);
    admin.pathname = '/postgres';
    const client = new Client({ connectionString: admin.toString() });
    await client.connect();
    try {
      const exists = await client.query('SELECT 1 FROM pg_database WHERE datname = $1', [
        testDatabase,
      ]);
      if (exists.rowCount === 0) {
        // Identifier, not a value — it cannot be a bind parameter, so it is quoted instead.
        await client.query(`CREATE DATABASE "${testDatabase.replace(/"/g, '""')}"`);
        console.log(`\ncreated test database ${testDatabase}`);
      }
    } finally {
      await client.end();
    }
  }

  const target = new URL(configured);
  target.pathname = `/${testDatabase}`;

  execSync('pnpm typeorm migration:run', {
    cwd: resolve(__dirname, '..'),
    stdio: 'pipe',
    env: { ...process.env, DATABASE_URL: target.toString() },
  });
}
