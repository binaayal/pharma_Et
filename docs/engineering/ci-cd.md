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
                  ├── mobile ──── analyze ── format ── flutter test (incl. guardian G2/G4/G7)
                  ├── migrations ─ rollback safety: previous code on the NEW schema
                  ├── api ─────── coverage (reported, never gated)
                  └── docs|src ── traceability: the RTM points at things that exist
```

| Gate | Job | Why it blocks |
|---|---|---|
| **Guardian suites G1–G7** | `api`, `mobile` | The S1 list. No override, no flaky-retry (ADR-008). |
| **Contract codegen freshness** | `contracts` | `pnpm gen:contracts` must produce no diff — proves both sides moved together (ADR-010). |
| **Contract tests, current + N-1** | `api`, `mobile` | An offline terminal may reconnect on the previous contract (ADR-009). |
| **Contract conformance (provider)** | `api` | Real server responses are parsed with the contract's own response schemas — the objects the Dart types are generated from. `../05-qa` §6 asks for *both* halves validated; requests were, responses were only typed, and types are erased at runtime. |
| **No-unscoped-access** | `api` | A single unscoped query is a cross-tenant leak waiting to happen (ADR-007). |
| **Migration + RLS policy check** | `api` | Migrations must apply cleanly *and* leave RLS policies in force. |
| **Core e2e journeys** | `api` | The daily loop as a pharmacy performs it, pushed through `/sync/push` in outbox order. Phase 1 exit gate (`../06` §2). |
| **NFR-3 budgets** | `api` | Sync p95, dashboard p95, a 72h backlog, and an index behind every tenant predicate — sequentially **and** under concurrency, since a p95 with nothing to contend against is not a load test (`../05-qa` §9). RLS overhead is measured too. Printed with margins. |
| **Traceability** | `traceability` | Every path the RTM cites exists, and every ADR is in both indexes. `../05-qa` §8 makes the RTM the evidence; prose does not compile, so a rename leaves the claim standing and false. |
| **Dependency scan** | `security` | No high-severity advisories. |
| **Launch-readiness claims** | `traceability` | A ticked §11 box must cite evidence that exists. Outstanding gates do not fail CI — being pre-GA is not a defect — but an unsubstantiated claim is. |
| **Rollback safety** | `rollback_safety` | Migrations are forward-only, so a rollback is "redeploy the previous image" against a database that has *already* migrated. The job checks the only thing that then matters — see §1.1. |

### 1.1 Rollback safety

Runs when a migration changes (or when the job's own definition does). It applies the PR's
migrations, puts the **base branch's** application code back over the top — keeping the new
migration files — and runs that older code's guardian suites against the newer schema.

The question it asks is the only one production ever asks. `../06` §6.2 makes migrations
**forward-only**, so rolling back means redeploying the previous image onto a database that
has already moved forward. Testing `down()` would answer a question nobody asks; `down()`
exists for local iteration and says so in `InitialSchema`. **Expand-then-contract** is the
rule, and this job is what makes the rule true rather than merely intended: add the new
shape now, remove the old one in a later release, once nothing is running on it.

A failure here means the PR's migration would turn a rollback — the thing you reach for when
something is already wrong — into a second outage.

Integration jobs run a **real PostgreSQL 16 service container**. Mocked-database tests cannot
validate RLS, so they are not accepted as evidence for anything isolation-related.

**Coverage is reported, not gated.** The `coverage` job prints the table into the run summary
and never fails on a percentage, because `../05-qa` §3 calls coverage a secondary signal —
"n/a — gated by suites passing, not %" for the invariant tier — and §16 asks for it "as a
trend, not a target". It runs beside `api` rather than inside it: it re-runs every suite, so
as a step it would double that job for a number nobody blocks on.

> This row previously claimed per-tier coverage **blocked** a PR. It did not: nothing in CI
> produced a coverage number at all, and `pnpm test:cov` had never run to completion — the
> babel instrumenter could not load NestJS's decorator metadata, and Jest's threshold checker
> crashes under `projects` with the v8 provider. A documented control that does not exist is
> worse than an absent one, because it is counted on. It now runs, on the v8 provider, with
> no threshold.

## 2. What runs on merge to `main`

`cd.yml`:

```
build & publish image (API + dashboard, GHCR, immutable sha-<commit> tag)
  └─ verify: stand THAT image up against a real Postgres, migrate, seed,
             run scripts/smoke.sh over HTTP, confirm the dashboard is served and
             /api still 404s, re-run the migration to prove it no-ops
       └─ live: migrate Neon with that image → Render deploy hook → wait for the commit → read-only smoke (ADR-027)
            └─ production: manual dispatch only, and currently refuses (GA checklist unmet)
```

The **verify** stage is the one that matters. It exercises the promotion path on a stack
nobody depends on, so a deploy that would have failed fails there. Three things it proves
that a unit test cannot: the image actually boots, the migrations actually apply from inside
it, and the API actually serves the walking skeleton over HTTP.

- **Migrations** run in CD from the **same image** that will serve, against Neon, *before* Render is told to deploy it (ADR-027). A failed migration stops the release.

Setup, rollback and running the whole thing locally: [`staging.md`](staging.md).

## 3. Environments

| Env | Data | Notes |
|---|---|---|
| Local | Synthetic, 2 tenants | Real Postgres in Docker so RLS runs |
| CI | Synthetic, ephemeral | Real Postgres service container, multi-tenant seed |
| Pre-release (CD verify) | **Synthetic only** — two fixture tenants | docker compose in CD: the release image + Postgres 16, same RLS policies and non-owner app role as live (`staging.md`). |
| Live | Real pharmacies | Render (Frankfurt) + Neon Postgres 16 + Cloudflare R2, free tiers (ADR-027, `hosting.md`). |
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
| `cd / deploy-live` | Usually a missing secret or variable — the job lists them in its summary and does not fail the pipeline (`hosting.md` §6). Otherwise: the *Migrate Neon* step is the migration; *Wait* failing means read the Render deploy log. |
| `cd / release-android`, `cd / release-ios` | Usually missing signing secrets. Each job says which ones in its summary and builds nothing. Setup: `mobile-release.md`. A red Android run that says *debug-signed* means `key.properties` was not written. |

**Never** re-run a red guardian job hoping for green. A flaky guardian test is a blocking
defect in its own right (`../05-qa` §4) — fix the flake, or you have no gate at all.

## 5. Secrets

Secrets live in the GitHub environment/secret store and the runtime secret manager — never in
the repository, never baked into an image, and never shared between environments. `.env` is
git-ignored; `.env.example` documents the keys with dummy values.
