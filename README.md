# PharmaEt — Pharmacy System

A multi-tenant, **offline-first** SaaS for independent Ethiopian pharmacies: inventory,
dispensing, cash control, and controlled-substance compliance across one or many branches.
Runs through power cuts; the counter never stops selling.

> **Read the docs before writing code.** [`docs/`](docs/README.md) is the single source of
> truth. The ADRs in [`docs/adr/`](docs/adr/README.md) are **binding** — if a task seems to
> require violating one, stop and flag it.

---

## Repository layout

```
pharma_Et/
├── docs/                  # The source of truth: vision → SRS → architecture → design → QA → delivery
│   ├── adr/               # Architecture Decision Records (binding)
│   ├── engineering/       # Repo layout, local setup, workflow, CI/CD
│   └── prototype/         # Visual/UX prototype (27 screens) — look only, no logic
├── apps/
│   ├── api/               # NestJS + TypeORM + PostgreSQL (RLS) — the one backend for all clients
│   ├── dashboard/         # React + Vite + TypeScript — web admin dashboard
│   └── mobile/            # Flutter — Android-primary counter app (local SQLite + outbox)
├── packages/
│   └── contracts/         # Sync envelope + API contract: ONE schema, generated TS and Dart types
└── scripts/               # Dev database, codegen, CI helpers
```

Why one repository: [ADR-010](docs/adr/ADR-010-repository-layout-and-tooling.md).

## Technology stack

| Layer | Choice | Decided in |
|---|---|---|
| Mobile | **Flutter** (Dart) — Android primary, iOS from the same codebase; local **SQLite** + append-only outbox | [ADR-001](docs/adr/ADR-001-platform-and-stack.md) |
| Backend | **NestJS** (Node 22, TypeScript) — modular monolith, one REST API for all clients | [ADR-001](docs/adr/ADR-001-platform-and-stack.md) |
| Database | **PostgreSQL 16+** — relational state *and* append-only event store, tenant isolation via **RLS** | [ADR-003](docs/adr/ADR-003-multi-tenancy-isolation.md), [ADR-004](docs/adr/ADR-004-controlled-substance-ledger.md) |
| Persistence layer | **TypeORM** with per-request `SET LOCAL` scoping | [ADR-007](docs/adr/ADR-007-persistence-and-rls-enforcement.md) |
| Web dashboard | **React 19 + Vite + TypeScript**, shipped as a static bundle against the same API | [ADR-001](docs/adr/ADR-001-platform-and-stack.md), [ADR-010](docs/adr/ADR-010-repository-layout-and-tooling.md) |
| Contracts | One schema in `packages/contracts` → generated TS + Dart types (anti-drift, `docs/05` §6) | [ADR-010](docs/adr/ADR-010-repository-layout-and-tooling.md) |
| Desktop | Deferred to V1.x/V2 (Flutter Desktop, Windows-first) | [ADR-001](docs/adr/ADR-001-platform-and-stack.md) |

Non-negotiables baked into the stack: money is integer **santim** (`bigint`, never float),
identifiers are **client-generated UUIDv7**, timestamps are **UTC** (the Ethiopian calendar
is presentation-only), and **nothing is hard-deleted**.

## Quickstart

```bash
pnpm install                 # workspace deps (api, dashboard, contracts)
./scripts/dev-db.sh up       # PostgreSQL 16 in Docker, on :5433
pnpm --filter @pharmaet/api migration:run
pnpm --filter @pharmaet/api seed
pnpm dev                     # API on :3000, dashboard on :5173

cd apps/mobile && flutter pub get && flutter run   # Android device/emulator
```

Full setup, troubleshooting, and the daily workflow: **[`docs/engineering/`](docs/engineering/README.md)**.

## Project status

**Phase 0 — Foundations + Walking Skeleton.** The thin vertical slice (one tenant, one
branch, one terminal: receive → sell → decrement → sync → dashboard) is being built to its
guardian gate (G1 isolation, G2 sync integrity, G4 money integrity, G7 offline resilience).
Breadth features start only after that gate is green — see
[`docs/06-delivery-plan.md`](docs/06-delivery-plan.md) §2.

**Open blocker for Phase 2 (compliance):** `[ASSUMPTION]` A-1 — EFDA directive 1121/2025
retention and psychotropic-dispensing rules await compliance verification.

## Contributing

Trunk-based: short-lived branches → PR → protected `main`. All CI gates green, including the
**guardian invariant suites**, which have no override. Changes to a *controlled artifact*
(sync envelope, event/ledger schema, RLS policies, compliance rules) additionally require an
ADR and two reviews. See [`CONTRIBUTING.md`](CONTRIBUTING.md) and `docs/06-delivery-plan.md` §7.
