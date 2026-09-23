# CI/CD

**Implements:** `../06-delivery-plan.md` §6 and `../05-qa-and-test-strategy.md` §12.
**Workflows:** `.github/workflows/`

---

## 1. What runs on a pull request

`ci.yml` fans out by changed path, so a Dart-only change does not rebuild the backend. Every
job that runs must be green to merge.

```
                  ┌── contracts ── build schemas ── verify codegen is not stale
changed paths ────┼── api ─── lint ── typecheck ── unit ── integration (real Postgres)
                  │             └── guardian G1–G7 ── no-unscoped-access ── migration + RLS check
                  ├── dashboard ─ lint ── typecheck ── unit ── build
                  └── mobile ──── analyze ── format ── flutter test (incl. guardian G2/G4/G7)
```

| Gate | Job | Why it blocks |
|---|---|---|
| **Guardian suites G1–G7** | `api`, `mobile` | The S1 list. No override, no flaky-retry (ADR-008). |
| **Contract codegen freshness** | `contracts` | `pnpm gen:contracts` must produce no diff — proves both sides moved together (ADR-010). |
| **Contract tests, current + N-1** | `api`, `mobile` | An offline terminal may reconnect on the previous contract (ADR-009). |
| **No-unscoped-access** | `api` | A single unscoped query is a cross-tenant leak waiting to happen (ADR-007). |
| **Migration + RLS policy check** | `api` | Migrations must apply cleanly *and* leave RLS policies in force. |
| **Per-tier coverage** | `api`, `mobile` | T1 ≥ 90% branch, T2 ≥ 80% line (`../05-qa` §3). Trend, not vanity. |
| **Dependency scan** | `security` | No high-severity advisories. |

Integration jobs run a **real PostgreSQL 16 service container**. Mocked-database tests cannot
validate RLS, so they are not accepted as evidence for anything isolation-related.

## 2. What runs on merge to `main`

`cd.yml`:

```
build & publish image (API + dashboard, GHCR, immutable sha-<commit> tag)
  └─ verify: stand THAT image up against a real Postgres, migrate, seed,
             run scripts/smoke.sh over HTTP, confirm the dashboard is served and
             /api still 404s, re-run the migration to prove it no-ops
       └─ deploy to Fly.io → release command migrates → rolling → smoke the live URL
            └─ production: manual dispatch only, and currently refuses (GA checklist unmet)
```

The **verify** stage is the one that matters. It exercises the promotion path on a stack
nobody depends on, so a deploy that would have failed fails there. Three things it proves
that a unit test cannot: the image actually boots, the migrations actually apply from inside
it, and the API actually serves the walking skeleton over HTTP.

- **Migrations** run as Fly's `release_command`, from the **same image** that will serve the
  traffic — a separate migration image drifts, and the drift surfaces as a schema the running
  code does not expect. Forward-only and expand-then-contract, so the previous release still
  works if this one is rolled back.
- **Backend** deploys rolling, and must keep **serving the N-1 sync contract** throughout
  (ADR-009). Rollback is redeploying the previous sha-tagged image; the schema is never
  reversed.
- **Dashboard** is built into the API image and served by it (`docs/03` §7). One artifact,
  one origin: no CORS, and a console can never be live against a server it was not built
  for. Vite's `assets/` output is cached `immutable` for a year; `index.html` is `no-cache`,
  because caching it means a deploy never reaches anyone holding the old copy.
- **Mobile** clients update out-of-band. **The server never assumes a client has updated.**

Setup, rollback and running the whole thing locally: [`staging.md`](staging.md).

## 3. Environments

| Env | Data | Notes |
|---|---|---|
| Local | Synthetic, 2 tenants | Real Postgres in Docker so RLS runs |
| CI | Synthetic, ephemeral | Real Postgres service container, multi-tenant seed |
| Staging | **Synthetic only** — two fixture tenants | Fly.io (`fra`) + Neon Postgres 16; dashboard on GitHub Pages. Same Postgres major, same RLS policies, same non-owner app role as production will use. Low-end Android device lab is Phase 1. |
| Production | Live | Single region; managed Postgres; backups sized to the **7-year** ledger retention |

Staging and production share **no** credentials and **no** data. Staging never holds real
patient or controlled-substance data.

## 4. Reading a red pipeline

| Red job | First thing to check |
|---|---|
| `contracts / codegen-fresh` | You edited `packages/contracts/src/` without running `pnpm gen:contracts`. Run it, commit the output. |
| `api / guardian` | Read *which* suite. G1 = isolation, G2 = sync, G3 = ledger, G4 = money, G5 = oversell, G6 = psychotropic, G7 = offline. The suite name tells you which invariant you broke. |
| `api / no-unscoped-access` | A repository or query is reaching the database outside the request-scoped `EntityManager`. |
| `api / migration-check` | Migration does not apply cleanly on a fresh database, or dropped an RLS policy. |
| `api / contract-n1` | Your envelope change is not backward compatible. Make it additive, or cut a new contract version with dual support (ADR-009). |
| `mobile / analyze` | `dart format` or analyzer findings. Format with the CI invocation — it skips the generated contract file — then re-run. |
| `cd / verify` | The image did not boot, the migration did not apply inside it, or the smoke test failed. Reproduce exactly: `docker compose -f docker-compose.staging.yml up -d --wait && ./scripts/smoke.sh http://localhost:3100/api`. |
| `cd / deploy-staging-api` | Usually a missing `FLY_API_TOKEN` — the job says so in its summary and does not fail the pipeline. Otherwise read the release-command output: it is the migration. |

**Never** re-run a red guardian job hoping for green. A flaky guardian test is a blocking
defect in its own right (`../05-qa` §4) — fix the flake, or you have no gate at all.

## 5. Secrets

Secrets live in the GitHub environment/secret store and the runtime secret manager — never in
the repository, never baked into an image, and never shared between environments. `.env` is
git-ignored; `.env.example` documents the keys with dummy values.
