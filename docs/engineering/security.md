# Security baseline

**Status:** ✅ Draft · owner: Bina
**Depends on:** NFR-4 (`../02-srs.md`), ADR-003, ADR-007, ADR-017, ADR-019, ADR-025, ADR-026
**Audience:** whoever deploys PharmaEt, and whoever is asked "is it secure?" by a customer.

This is the checklist PharmaEt is held to. Each control has three parts: what it is, where
the code is, and **what fails in CI if it is removed**. A control with no failing test is a
promise, not a control.

## 1. The twenty controls

| # | Control | How PharmaEt does it | Held by |
|---|---|---|---|
| 1 | **Hide API keys** | No client holds a secret. The phone and the console carry only the API's URL. Server secrets (`JWT_SECRET`, `DATABASE_*`, `PROOF_ENCRYPTION_KEY`) live in Render's environment settings and are read at boot. The console ships **no source maps**, and release phone builds are **obfuscated** (`--obfuscate --split-debug-info`). | `security.yml` → *no secrets in the diff*, *gitleaks* |
| 2 | **Purge git secrets** | The whole history (103 commits at the time of writing) was scanned with gitleaks on 2026-09-30: **no leaks, nothing to purge**. CI now rescans the *full* history on every PR and weekly, so a secret committed and then deleted still fails. Keystores, `.p8`, `.p12`, `.pem` and `key.properties` are git-ignored. | `security.yml` → *gitleaks* |
| 3 | **Use a public DB key** | Not applicable in the Supabase sense: no client ever talks to the database. Only the API does, and it connects as **`pharmaet_app`, a non-owner role** with SELECT/INSERT/UPDATE and no DELETE, so row-level security actually applies to it (ADR-007). The owner role is used only for migrations and logged platform reads. | `no-unscoped-access.spec.ts` |
| 4 | **Row-level security** | Every tenant table has `ENABLE` and `FORCE ROW LEVEL SECURITY` with a `tenant_isolation` policy on `app.current_tenant`, set per transaction with `set_config(…, true)` (ADR-003). A query that forgets its tenant returns nothing. | `g1-tenant-isolation`, `no-unscoped-access` (every table has a policy) |
| 5 | **Encrypt sensitive data** | *In transit:* TLS everywhere (#19). *At rest:* payment screenshots (bank app captures) are **AES-256-GCM** under `PROOF_ENCRYPTION_KEY`, and a tampered file fails to open. Files are written `0600`. PINs and passwords are never stored, only hashed (#10). On the phone, session tokens and the offline sign-in verifier are in the **Android Keystore / iOS Keychain**, and Android **backup is disabled**, so neither the database nor the keystore can be restored onto another phone. The database is encrypted at rest by Neon, and the screenshot bucket by Cloudflare R2. | `security.spec.ts` (sealed ≠ image, tamper refused) |
| 6 | **Enforce server-side auth** | `JwtAuthGuard` is **global**: every route is authenticated unless it says `@Public()`. The token's `typ` is checked, so a refresh token cannot call the API. Then come the capability matrix, the tenant-status guard (ADR-025) and the subscription guard. The phone's permission checks are UX only; the server re-checks everything. | `g1-permission-matrix`, `g1-token-lifecycle`, route sweep |
| 7 | **Lock record access** | RLS pins every read and write to the caller's tenant. Branch scoping and "own shift" grants narrow it further. Every route is attempted across the tenant boundary by the sweep, and **a route nobody has classified fails CI**. | `g1-cross-tenant-route-sweep` (every route) |
| 8 | **Block field tampering** | Every body is parsed by a Zod schema that **drops unknown keys**. `tenantId`, `role`, `userId` and `branchIds` are never read from a request body: they come from the verified token. Role escalation through `POST /users` is refused by the grant check. | `g1-permission-matrix`, `g2-contract-conformance` |
| 9 | **Secure session cookies** | The platform console's session is an **HttpOnly, SameSite=Strict, Secure** cookie scoped to `/api/platform`, so no script on the page can read it. Writes must also carry the `x-contract-version` header, which a cross-site request cannot set (CSRF). The phone app uses no cookies; its tokens are in the Keychain/Keystore. | `g1-http-security` (cookie flags, CSRF refusal), `console.spec.tsx` (no browser storage) |
| 10 | **Hash passwords** | **argon2id** for PINs, owner passwords and platform-admin passwords. On the phone, the offline verifier is salted PBKDF2-SHA256 (20,000 rounds), never the PIN. Platform-admin passwords set with `create-admin` must be at least 14 characters. | `offline_credentials_test.dart`, `g1-http-security` (no hash in any response) |
| 11 | **Rate limit login** | *Per identity and per address, persisted* (ADR-017): 5 failures per user and 20 per address in 15 min, which now covers **platform-admin sign-in** too. *Per address, in memory*: 30 sign-ins/min, 60 refreshes/min, 600 API calls/min. **Behind Render, `TRUST_PROXY` must match its proxy** (verified by `/api/health` → `clientIp`), or every request appears to come from the proxy and one attacker throttles every pharmacy at once. | `g1-login-throttling`, `g1-http-security`, `security.spec.ts` (limiter) |
| 12 | **Bot protection** | The only anonymous write is the sign-up form. It has a **honeypot** (a bot is answered like a person and nothing is stored), refuses links and markup in names, allows 5 submissions per address per hour, and one open request per phone number. Every request is then **verified by a person, by phone**, before any account exists (ADR-022). | `g1-http-security`, `g1-signup-requests` |
| 13 | **Parameterize queries** | Every runtime query binds its values (`$1…`). A test reads the source and **fails if any query string interpolates a value**. The four fragments it permits (literal SQL with their own placeholders) are listed and reviewed. | `security.spec.ts` → *parameterised SQL* |
| 14 | **Validate all input** | Bodies: Zod, shared with the clients (ADR-010). Path ids: `ParseUUIDPipe`. Query ids: UUID-checked. Limits: bounded. Malformed input is a **400, never a 500**. Uploads: #16. | `g1-http-security` → *malformed input* |
| 15 | **Escape user content** | React escapes all text; there is no `dangerouslySetInnerHTML`. A strict **Content-Security-Policy** (`script-src 'self'`) stops an injected script from running even if one got in. CSV exports neutralise **formula injection** (`=`, `+`, `-`, `@`). Flutter renders text as text. | `g1-http-security` (CSP), `security.spec.ts` (CSV) |
| 16 | **Restrict file uploads** | Payment proofs only: **JPEG/PNG/WebP by magic bytes** (the declared type is not trusted), ≤ 8 MB, one file, ≤ 5 small fields, stored under a random key outside the web root, never served inline to anyone but a platform admin, `Cache-Control: no-store`. | `g1-subscription-suspension`, `security.spec.ts` |
| 17 | **Trim API responses** | Responses are built field by field from views, never whole entities, so no hash, secret or internal column leaks. No `X-Powered-By`. 500s say "Internal server error" and nothing else. Telemetry carries no business data (ADR-021). | `g1-http-security` (no hash, no framework header), `g1-telemetry-leaks-nothing` |
| 18 | **Security headers** | `Content-Security-Policy`, `Strict-Transport-Security` (deployed), `X-Content-Type-Options`, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`, `Cross-Origin-Opener/Resource-Policy`, `Permissions-Policy`, and `Cache-Control: no-store` on all API data. | `g1-http-security` |
| 19 | **Force HTTPS** | Render's edge serves HTTPS only. The app **redirects GETs and refuses writes** that arrive over HTTP, and sends HSTS. A **release phone build refuses to start** with an `http://` server, Android release forbids cleartext (`usesCleartextTraffic=false`), and iOS App Transport Security allows only the local network, for development. | `api_endpoint_test.dart` |
| 20 | **Scan dependencies** | `pnpm audit` (high blocks), **OSV** for npm *and* the phone's Dart packages, **CodeQL** static analysis, and **Dependabot** weekly update PRs for npm, pub, Actions and Docker. All of it runs on every PR and weekly. | `security.yml`, `codeql.yml`, `dependabot.yml` |

## 2. What the operator must do (once per environment)

Done as part of [`hosting.md`](hosting.md): the encryption key, JWT secret and app-role
password are generated in §2–§3 and entered in Render; your own platform admin is created
with `pnpm create-admin` in §4 (the live database is never seeded, so there is no public demo
admin or demo pharmacy to retire); `TRUST_PROXY` is verified with `/api/health` in §7.
Production refuses to start without `PROOF_ENCRYPTION_KEY`, a 32+ character `JWT_SECRET`
and an explicit `PROOF_STORAGE`, and refuses to boot while any platform admin still uses the
public development password.

Keep `PROOF_ENCRYPTION_KEY` in your password manager as well: screenshots encrypted under a
lost key cannot be read again.

## 3. Known limits, stated plainly

- **The phone's local database is not encrypted.** SQLite on the device holds the catalogue
  and unsynced sales. The device's own storage encryption (on by default on every Android
  7+ and iOS device) protects it at rest, and backup is disabled. SQLCipher would add a
  second layer but needs a migration of every installed database, so it is tracked for
  V1.x rather than done in a hurry.
- **In-memory rate limits are per instance.** With N API machines the per-address budget is
  N × the limit: still bounded, which is the property that matters. The persisted
  credential throttle (ADR-017) is shared.
- **A phone that never reconnects cannot be reached** by a deactivation (ADR-025). This is
  bounded by the offline window (168 h).
