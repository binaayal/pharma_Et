# Engineering Handbook

**Status:** ✅ Draft · owner: Bina
**Depends on:** `../04-system-design.md`, `../05-qa-and-test-strategy.md`, `../06-delivery-plan.md`, ADR-010
**Audience:** engineers and Claude Code, on their first day and every day after.

> `01`–`06` say *what* to build and *why*. This directory says *how to actually build it
> here*: the repository, the local loop, the daily workflow, and what CI will block you on.

| Doc | Purpose |
|---|---|
| `README.md` (this file) | Repo layout, prerequisites, local setup, day-to-day commands |
| [`workflow.md`](workflow.md) | Branching, commits, PRs, reviews, change control, releases |
| [`ci-cd.md`](ci-cd.md) | What runs on a PR, what runs on merge, how to read a red pipeline |
| [`walking-skeleton.md`](walking-skeleton.md) | Phase 0 scope, its guardian gate, and how to verify it |

---

## 1. Repository layout

```
pharmaEt/
├── apps/
│   ├── api/                  NestJS backend (the one API for all clients)
│   │   ├── src/modules/      Modular monolith: auth, tenant, inventory, pos, sync, …
│   │   ├── src/common/       Tenant scope guard, request context, RLS plumbing
│   │   ├── src/migrations/   TypeORM migrations — tables AND RLS policies
│   │   └── test/             Integration + guardian suites (real Postgres)
│   ├── dashboard/            React + Vite + TS admin console
│   └── mobile/               Flutter counter app
│       └── lib/
│           ├── data/         Local SQLite, outbox, repositories
│           ├── sync/         Sync client (client half of the SyncService seam)
│           └── contracts/    GENERATED Dart contract types — do not hand-edit
├── packages/
│   └── contracts/            Zod schemas → TS types, JSON Schema, Dart codegen
├── docs/                     Source of truth (this tree)
├── scripts/                  dev-db.sh, gen-contracts.ts, …
└── .github/workflows/        CI/CD
```

**The rules that the layout encodes** (all from ADRs — see `../adr/`):

1. **No unscoped database access.** Every repository call goes through the request-scoped
   `EntityManager` that has `SET LOCAL app.current_tenant` applied (ADR-007). CI has a test
   that fails if an unscoped path exists.
2. **The contract is generated, never hand-written** on either side (ADR-010, `05-qa` §6).
   Edit `packages/contracts/src/`, run `pnpm gen:contracts`, commit the output. The
   generated Dart is deliberately **not** run through `dart format` — CI compares its bytes,
   and the formatter's output moves between SDK versions. Do not reformat it by hand either;
   `dart format .` over the whole tree will, so format with
   `find lib test -name '*.dart' -not -path 'lib/contracts/*'` as CI does.
3. **Nothing is hard-deleted.** Relational rows get `deleted_at`; ledger and audit get
   tombstone events (ADR-004).
4. **Money is `bigint` santim.** No float touches money, anywhere, in any language (`04` §3).
5. **Identifiers are client-generated UUIDv7** (ADR-006) — the client mints the id, so an
   offline write is complete before it has ever seen the server.

## 2. Prerequisites

| Tool | Version | Notes |
|---|---|---|
| Node.js | ≥ 22 LTS | Backend + dashboard + codegen |
| pnpm | ≥ 9 | `corepack enable` then `corepack prepare pnpm@latest --activate` |
| Docker | any recent | Only for the local PostgreSQL |
| Flutter | **3.47.5 (stable)** | Pinned exactly — CI uses this version, and its Dart SDK decides how Dart source is formatted. With the Android SDK; **Android is the primary target**. |
| PostgreSQL client | 16+ | Optional, for `psql` against the dev database |

Verify: `node -v && pnpm -v && docker info >/dev/null && flutter doctor`.

## 3. First-time setup

```bash
pnpm install                       # installs api, dashboard, contracts
cp apps/api/.env.example apps/api/.env
./scripts/dev-db.sh up             # PostgreSQL 16 on localhost:5433
pnpm --filter @pharmaet/api migration:run
pnpm --filter @pharmaet/api seed   # 2 tenants × 2 branches × all roles (05-qa §11)
```

The seed deliberately creates **two** tenants. Single-tenant local data hides exactly the
class of bug (cross-tenant leakage) that is an S1 here, so every environment is multi-tenant
by construction.

## 4. Daily commands

| What | Command |
|---|---|
| Run API + dashboard | `pnpm dev` |
| Run API alone | `pnpm --filter @pharmaet/api dev` (http://localhost:3000) |
| Run dashboard alone | `pnpm --filter @pharmaet/dashboard dev` (http://localhost:5173) |
| Run the mobile app | `cd apps/mobile && flutter run` |
| Regenerate contracts | `pnpm gen:contracts` (then commit the diff) — pure Node, no Dart SDK needed |
| Unit tests | `pnpm test` · `cd apps/mobile && flutter test` |
| Guardian suites | `pnpm test:guardian` — **the merge gate** |
| Integration tests | `pnpm test:integration` (needs the dev database up) |
| Lint + typecheck | `pnpm lint && pnpm typecheck` |
| New migration | `pnpm --filter @pharmaet/api migration:generate -- src/migrations/Name` |
| Reset the dev DB | `./scripts/dev-db.sh reset` |

## 5. Local database

`scripts/dev-db.sh` runs PostgreSQL 16 in Docker on **port 5433** (so it never collides with
a host PostgreSQL) with the database `pharmaet_dev`.

```bash
./scripts/dev-db.sh up | down | reset | psql | logs
```

Integration tests run against **real PostgreSQL**, never a mock — RLS, constraints, and
`SET LOCAL` scoping are the things under test, and a mocked database cannot exercise any of
them (`05-qa` §5).

## 6. Where to start reading, by task

| You are working on… | Read first |
|---|---|
| Anything at all | `../01-vision-and-scope.md` §6, then the relevant ADRs |
| The sync engine | `../04-system-design.md` §7, ADR-002, ADR-005, ADR-006, ADR-009 |
| Tenant isolation / RLS | `../04-system-design.md` §8, ADR-003, ADR-007 |
| Controlled substances | `../04-system-design.md` §5.6, §6, ADR-004 — and note A-1 is unverified |
| Inventory / POS | `../02-srs.md` FR-3, FR-4 |
| Tests | `../05-qa-and-test-strategy.md` §3 (tiers), §4 (guardian suites) |
| UI look and feel | `../prototype/index.html` — **visual intent only**, behaviour comes from `02`/`04` |

## 7. Things that will get a PR rejected

- A query, repository, or migration that can read across tenants.
- Hand-edited generated contract code, or a contract change on only one side.
- A floating-point type anywhere near money.
- A hard `DELETE` on domain data, or an `UPDATE` on the `event` table.
- A new feature that implements something the docs mark **deferred to V1.x/V2** — including
  "while I was in there" conflict-resolution code (ADR-002 is explicit: **no conflict code
  in V1**).
- A change to a controlled artifact without an ADR (`../06-delivery-plan.md` §7).
- A retried "flaky" guardian test. A flaky guardian test is itself a blocking defect.
