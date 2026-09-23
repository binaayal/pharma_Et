import 'reflect-metadata';
import { join } from 'node:path';
import * as dotenv from 'dotenv';
import { DataSource } from 'typeorm';
import { ALL_ENTITIES } from '../entities';

dotenv.config();

/**
 * The migration DataSource. It connects as the OWNER role from DATABASE_URL, because
 * migrations create tables, policies and roles — things the application role is deliberately
 * not granted (see InitialSchema).
 *
 * The running application uses a different connection entirely; see app.module.ts.
 *
 * The migration glob is resolved relative to this file rather than to the working
 * directory, so the same data source works under ts-node (`src/migrations/*.ts`) and inside
 * the built container (`dist/migrations/*.js`). A cwd-relative glob silently matches nothing
 * when the container starts from `/app`, and a migration step that finds no migrations
 * reports success — it would deploy a schema-less database and call it done.
 */
export default new DataSource({
  type: 'postgres',
  url: process.env.DATABASE_URL,
  entities: ALL_ENTITIES,
  migrations: [join(__dirname, '..', 'migrations', '*.{ts,js}')],
  // Never true, in any environment. Schema changes go through reviewed, forward-only
  // migrations that carry their RLS policies with them (docs/06 §6.2).
  synchronize: false,
  logging: process.env.TYPEORM_LOGGING === 'true',
});
