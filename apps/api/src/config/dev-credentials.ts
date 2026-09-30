/**
 * The development seed's platform-admin password (`src/seed.ts`).
 *
 * In its own file so the server can check, at boot, that no deployed platform admin still
 * answers to it — the repository is public, so this string is a password to anyone who
 * reads it. Importing `seed.ts` instead would run the seed.
 */
export const DEV_PLATFORM_PASSWORD = 'platform-dev-password';
