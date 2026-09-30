# ADR-026 — The security baseline: console cookie, rate limits, encryption at rest

**Status:** Accepted · **Date:** 2026-09-30
**Related:** NFR-4, ADR-017 (login throttling), ADR-022 (sign-up requests), ADR-025,
`../engineering/security.md` (the full checklist)

## Context

Before selling, the platform was checked against a twenty-point security checklist. Most
points were already met by design (RLS, argon2id, global authentication, parameterised
SQL). Five needed a decision rather than a patch.

## Decisions

1. **The platform console authenticates with an HttpOnly cookie, not a script-held token.**
   The token that can suspend or deactivate every pharmacy used to sit in `sessionStorage`,
   where any script on the page could read it. It is now a cookie with `HttpOnly`,
   `SameSite=Strict`, `Secure` (deployed) and `Path=/api/platform`. The console and the API
   share one origin (docs/03 §7), so no cross-site cookie is ever needed. CSRF is closed
   twice: SameSite=Strict, and a required `x-contract-version` header on cookie-authenticated
   writes, which a cross-site request cannot set. Bearer tokens still work for scripts and
   the test suites. The phone app is unchanged: it has no cookies, and its tokens are in the
   Keychain/Keystore.

2. **Proxy trust is explicit (`TRUST_PROXY`).** Behind Fly, every request came from the edge's
   address, so ADR-017's "20 failures per address" was one counter for the whole country.
   Any twenty wrong PINs anywhere locked everyone out of signing in for 15 minutes. This was
   a latent outage, not a hardening item. `fly.toml` now sets `TRUST_PROXY=1`.

3. **Rate limits in front of the credential throttle, in memory.** A per-address budget
   (sign-in 30/min, refresh 60/min, sign-up 5/hour, everything 600/min) protects the argon2
   verifier, which is deliberately expensive, from volume. It is in memory rather than
   Redis, so there is no new infrastructure; across N instances the budget is N × the limit,
   still bounded. The persisted throttle (ADR-017) stays the authority on credentials, and
   now covers platform-admin sign-in, which had no throttle at all.

4. **Payment screenshots are encrypted at the application layer (AES-256-GCM).** Disk or
   volume encryption at the provider protects against a stolen disk, not against a leaked
   backup, a copied volume snapshot or an over-broad bucket policy. GCM also authenticates
   the file, so a doctored image fails to open instead of misleading a reviewer. Files
   written before the key existed are read as they are; nothing needs migrating. The key is
   required in production and warned about in staging, so adding it cannot take staging down.

5. **Seeded credentials cannot reach production.** The seed refuses to run when
   `NODE_ENV=production`. At boot, staging and production check whether any live platform
   admin still answers to the public development password: production refuses to start,
   staging logs an error on every boot. `entrypoint create-admin` creates or rotates an admin
   and retires the seeded one.

## Consequences

- The console signs in once per two hours per browser. The session cannot be read by
  scripts or restored from storage, so a reload keeps it but a stolen `sessionStorage` does
  not.
- Operators must set `PROOF_ENCRYPTION_KEY` and run `create-admin` once per environment
  (`../engineering/security.md` §2).
- New CI jobs (gitleaks over full history, OSV for npm and pub, CodeQL) and Dependabot PRs.

## Verification

`apps/api/test/guardian/g1-http-security.spec.ts` (19), `apps/api/test/unit/security.spec.ts`
(limiter, CSV injection, encryption, SQL interpolation scan), `apps/dashboard/test/*.spec.ts`
(no credential in browser storage), `apps/mobile/test/unit/api_endpoint_test.dart`.
