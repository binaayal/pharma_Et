import * as dotenv from 'dotenv';
import { resolve } from 'node:path';

// Integration and guardian suites talk to a real PostgreSQL. `.env.test` overrides the dev
// database when present; otherwise the dev database is used, which is fine locally and is
// what CI's ephemeral service container provides.
dotenv.config({ path: resolve(__dirname, '../.env.test') });
dotenv.config({ path: resolve(__dirname, '../.env') });

process.env.NODE_ENV = 'test';
jest.setTimeout(60000);
