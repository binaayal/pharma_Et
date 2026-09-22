import 'reflect-metadata';
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
 */
export default new DataSource({
  type: 'postgres',
  url: process.env.DATABASE_URL,
  entities: ALL_ENTITIES,
  migrations: ['src/migrations/*.ts'],
  // Never true, in any environment. Schema changes go through reviewed, forward-only
  // migrations that carry their RLS policies with them (docs/06 §6.2).
  synchronize: false,
  logging: process.env.TYPEORM_LOGGING === 'true',
});
