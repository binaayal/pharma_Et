import { z } from 'zod';

/**
 * Configuration is validated at boot and fails fast. A server that starts with a missing
 * JWT secret or the wrong database user is worse than one that refuses to start: RLS is
 * silently inert for a superuser connection (ADR-007), so a misconfiguration here looks
 * exactly like a working system until it leaks across tenants.
 */
const envSchema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'staging', 'production']).default('development'),
  PORT: z.coerce.number().int().positive().default(3000),

  DATABASE_URL: z.string().url(),
  DATABASE_APP_USER: z.string().min(1).default('pharmaet_app'),
  DATABASE_APP_PASSWORD: z.string().min(1),

  JWT_SECRET: z.string().min(16, 'JWT_SECRET must be at least 16 characters'),
  JWT_ACCESS_TTL: z.string().default('15m'),
  JWT_REFRESH_TTL: z.string().default('30d'),

  OFFLINE_AUTH_TTL_HOURS: z.coerce.number().int().positive().default(168),

  CORS_ORIGINS: z.string().default('http://localhost:5173'),
});

export type AppConfig = z.infer<typeof envSchema> & { corsOrigins: string[] };

export function loadConfiguration(): AppConfig {
  const parsed = envSchema.safeParse(process.env);
  if (!parsed.success) {
    const issues = parsed.error.issues.map((i) => `  ${i.path.join('.')}: ${i.message}`).join('\n');
    throw new Error(`Invalid environment configuration:\n${issues}`);
  }
  if (parsed.data.NODE_ENV === 'production' && parsed.data.JWT_SECRET.includes('dev-only')) {
    throw new Error('refusing to start production with the development JWT secret');
  }
  return {
    ...parsed.data,
    corsOrigins: parsed.data.CORS_ORIGINS.split(',')
      .map((s) => s.trim())
      .filter(Boolean),
  };
}
