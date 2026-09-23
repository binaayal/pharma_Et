import { resolve } from 'node:path';
import * as dotenv from 'dotenv';

/**
 * Integration and guardian suites talk to a REAL PostgreSQL — RLS, constraints and
 * SET LOCAL scoping are the things under test, and a mocked database exercises none of
 * them (docs/05-qa §5).
 *
 * They also TRUNCATE every table between suites, which is why they must never run against
 * the development database. Wiping a developer's seeded data as a side effect of running
 * the test suite is the kind of small betrayal that teaches people not to run tests.
 *
 * Resolution order:
 *   1. TEST_DATABASE_URL, if set — explicit always wins. CI sets this to its own ephemeral
 *      service container.
 *   2. Otherwise derive a sibling database by appending `_test` to the configured name, so
 *      `pharmaet_dev` becomes `pharmaet_test` with no configuration at all.
 */
dotenv.config({ path: resolve(__dirname, '../.env.test') });
dotenv.config({ path: resolve(__dirname, '../.env') });

process.env.NODE_ENV = 'test';

if (process.env.TEST_DATABASE_URL) {
  process.env.DATABASE_URL = process.env.TEST_DATABASE_URL;
} else if (process.env.DATABASE_URL) {
  const url = new URL(process.env.DATABASE_URL);
  const database = url.pathname.replace(/^\//, '');
  if (!database.endsWith('_test')) {
    url.pathname = `/${database}_test`;
    process.env.DATABASE_URL = url.toString();
  }
}

jest.setTimeout(60000);
