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
| Web dashboard | **React 18 + Vite + TypeScript**, shipped as a static bundle against the same API | [ADR-001](docs/adr/ADR-001-platform-and-stack.md), [ADR-010](docs/adr/ADR-010-repository-layout-and-tooling.md) |
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

| Phase | State |
|---|---|
| **P0** Foundations + walking skeleton | ✅ Complete |
| **P1** Core loop (FR-1/2/3/4/7/8/9/10) | ✅ Closed |
| **P2** Compliance subset | ◐ **Closed partial** — the append-only event store and audit log are built and carrying traffic; the regulated half is gated on A-1 and *not started* ([ADR-015](docs/adr/ADR-015-audit-log-before-a1.md)) |
| **P3** Hardening | ✅ Everything buildable; the device matrix and field pilot need hardware and a pharmacy |
| **P4** GA | Gate built, **never passed** — see below |

Every functional requirement in [`docs/02-srs.md`](docs/02-srs.md) is implemented except the
three explicitly gated on A-1. The RTM is machine-checked: a row citing a file that does not
exist fails CI.

**GA is blocked, and the pipeline enforces it.** `scripts/release-readiness.mjs` reads
`docs/06` §11 and refuses a production deploy until every box is ticked *and* cites evidence
that resolves. Four of nine are met; the other five each need something other than code — a
restore drill, a low-end Android handset, a pilot pharmacy, the EFDA retail directive, and
somewhere to send an alert.

**Open blocker for the regulated half:** `[ASSUMPTION]` A-1 — EFDA directive 1121/2025
(controlled-substance retention, psychotropic dispensing rules). Directive **872/2022** was
reviewed on 2026-09-23 and does **not** clear it: its Art. 3 scope is import/export/wholesale
and excludes retail pharmacy. Recorded in
[`docs/compliance-sign-off.md`](docs/compliance-sign-off.md) as an engineering reading, not a
compliance sign-off.

## Contributing

Trunk-based: short-lived branches → PR → protected `main`. Every CI gate must be green,
including the **guardian invariant suites**, which have no override and no flaky-retry.

A change to a *controlled artifact* — the sync envelope, the event/ledger schema, the RLS
policies, the compliance rules — additionally requires an ADR and a guardian-suite update,
enforced by the `controlled-artifact` job rather than by a reviewer. There is no second
approver: [ADR-011](docs/adr/ADR-011-solo-maintainer-change-control.md) explains why a
mechanical gate is the better substitute for one maintainer, and why it is not a weakening.

What CI blocks a merge on:

| Gate | Checks |
|---|---|
| **Guardian suites** | The S1 invariants — tenant isolation, sync integrity, ledger immutability, money, oversell, offline resilience |
| **Contract** | Codegen freshness, the N-1 window, and real server responses parsed against the contract's own schemas |
| **Isolation** | Every route attempted across the tenant boundary; an unclassified route fails |
| **Traceability** | Every path the RTM cites exists; every ADR is indexed |
| **Rollback safety** | On a migration change, the *base branch's* suites run against the *new* schema |
| **Security** | Dependency advisories, no secrets in the diff |

Coverage is reported, never gated — `docs/05` §3 makes it a secondary signal and §16 asks for
a trend, not a target.

See [`CONTRIBUTING.md`](CONTRIBUTING.md) and
[`docs/engineering/`](docs/engineering/README.md).
