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

  /** Reverse proxies in front of the app — 1 behind Fly's edge (see common/http/security.ts). */
  TRUST_PROXY: z.coerce.number().int().min(0).max(5).default(0),

  /** Per-address request budgets. Off only where a suite deliberately floods one address. */
  RATE_LIMIT: z
    .enum(['on', 'off'])
    .optional()
    .transform((v) => (v ?? (process.env.NODE_ENV === 'test' ? 'off' : 'on')) === 'on'),

  /**
   * AES-256 key for payment screenshots at rest, base64 (32 bytes). Required in staging and
   * production: those images are somebody's bank app (docs/engineering/security.md).
   */
  PROOF_ENCRYPTION_KEY: z
    .string()
    .optional()
    .refine((v) => v === undefined || Buffer.from(v, 'base64').length === 32, {
      message: 'PROOF_ENCRYPTION_KEY must be 32 bytes, base64-encoded (openssl rand -base64 32)',
    }),
});

export type AppConfig = z.infer<typeof envSchema> & { corsOrigins: string[] };

export function loadConfiguration(): AppConfig {
  const parsed = envSchema.safeParse(process.env);
  if (!parsed.success) {
    const issues = parsed.error.issues.map((i) => `  ${i.path.join('.')}: ${i.message}`).join('\n');
    throw new Error(`Invalid environment configuration:\n${issues}`);
  }
  const deployed = parsed.data.NODE_ENV === 'production' || parsed.data.NODE_ENV === 'staging';
  if (parsed.data.NODE_ENV === 'production' && parsed.data.JWT_SECRET.includes('dev-only')) {
    throw new Error('refusing to start production with the development JWT secret');
  }
  if (parsed.data.NODE_ENV === 'production' && parsed.data.JWT_SECRET.length < 32) {
    // HS256 is only as strong as its key. Sixteen characters was the floor for development.
    throw new Error('JWT_SECRET must be at least 32 characters in production');
  }
  if (parsed.data.NODE_ENV === 'production' && !parsed.data.PROOF_ENCRYPTION_KEY) {
    throw new Error(
      'PROOF_ENCRYPTION_KEY is required in production: payment screenshots are encrypted at ' +
        'rest (openssl rand -base64 32)',
    );
  }
  if (deployed && !parsed.data.PROOF_ENCRYPTION_KEY) {
    // Staging keeps booting without it, so adding the requirement cannot take a deployed
    // environment down on the next merge — but it says so on every start.
    console.warn(
      'WARNING: PROOF_ENCRYPTION_KEY is not set — payment screenshots are stored UNENCRYPTED. ' +
        'Set it: fly secrets set PROOF_ENCRYPTION_KEY=$(openssl rand -base64 32)',
    );
  }
  return {
    ...parsed.data,
    corsOrigins: parsed.data.CORS_ORIGINS.split(',')
      .map((s) => s.trim())
      .filter(Boolean),
  };
}
