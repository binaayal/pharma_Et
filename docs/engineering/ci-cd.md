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
merge ── build artifacts ── deploy STAGING ── e2e + smoke + perf-smoke ── [manual approval] ── PRODUCTION ── health watch
```

- **Migrations** run as a **gated, forward-only** step, rehearsed on staging against
  production-like data. A migration that is not safe against live data does not ship.
  Schema changes are **expand-then-contract** so the previous app version keeps working.
- **Backend** deploys rolling / zero-downtime, and must keep **serving the N-1 sync
  contract** throughout. Rollback = redeploy the previous image; because migrations are
  forward-only, the schema must already tolerate it.
- **Mobile** builds a signed Android artifact to an internal test track, then a staged store
  rollout. iOS follows from the same codebase via TestFlight — **budget for review latency**;
  it is not same-day.
- **Dashboard** publishes a static bundle served alongside the API.

Clients update out-of-band. **The server never assumes a client has updated** (ADR-009).

## 3. Environments

| Env | Data | Notes |
|---|---|---|
| Local | Synthetic, 2 tenants | Real Postgres in Docker so RLS runs |
| CI | Synthetic, ephemeral | Real Postgres service container, multi-tenant seed |
| Staging | **Synthetic only** | Same Postgres version, RLS policies, and object storage as production; low-end Android device lab |
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
| `mobile / analyze` | `dart format` or analyzer findings. `dart format .` then re-run. |

**Never** re-run a red guardian job hoping for green. A flaky guardian test is a blocking
defect in its own right (`../05-qa` §4) — fix the flake, or you have no gate at all.

## 5. Secrets

Secrets live in the GitHub environment/secret store and the runtime secret manager — never in
the repository, never baked into an image, and never shared between environments. `.env` is
git-ignored; `.env.example` documents the keys with dummy values.
