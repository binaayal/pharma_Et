# ADR-001 — Platform & technology stack

**Status:** Accepted · **Date:** 2026-09-21

## Context

We are building a multi-tenant, offline-first system for Ethiopian pharmacies, used only
by owners and staff (not end customers). We need mobile clients, a backend API, a web
admin dashboard for platform operations, and eventually a desktop client. The team is
multi-engineer and uses Claude Code.

The decision that actually dominates client choice is **not** the UI toolkit — it is the
**offline persistence + sync layer**. The UI framework is chosen downstream of that.

## Decision

- **Mobile:** **Flutter**, single codebase for Android and iOS. **Android is the primary build and test target**; iOS ships from the same codebase.
- **Backend:** **Node.js + NestJS**, exposing one common REST API for all clients.
- **Database:** **PostgreSQL** (see ADR-003 for the tenancy model; ADR-004 for the ledger).
- **Web admin dashboard:** a web app (React/Next.js) for tenant onboarding, payment-screenshot verification, and subscription control.
- **Desktop:** **deferred** to V1.x/V2, delivered via **Flutter Desktop (Windows-first)** to reuse the mobile codebase.
- **Local persistence (mobile):** device-local **SQLite** with an append-only outbox of operations; the server is the source of truth (mechanics in ADR-002 and `04-system-design.md`).

## Rationale

- Flutter delivers Android + iOS (+ later desktop) from one codebase with mature SQLite tooling, which matters because our hard problem is local persistence, not widgets.
- NestJS gives a structured, opinionated, testable backend that a multi-engineer team can scale without divergent conventions — valuable for a regulated domain needing consistency.
- PostgreSQL supports row-level security (RLS) for tenant isolation and is a natural fit for both the mutable inventory model and the append-only ledger.
- Desktop is deferred because the counter runs on cheap Android devices and the owner's back-office oversight is already served by the web dashboard; spending V1 risk budget on a rougher desktop surface buys little.

## Consequences

- iOS incurs Apple developer account, review, and device-testing overhead for a small share of Ethiopian users (tracked as risk R-2). Accepted per product direction.
- Choosing SQLite + an outbox means we own the sync protocol (ADR-002); this is deliberate, so the single-writer V1 protocol stays simple and auditable.
- Web dashboard and mobile share the same NestJS API and RBAC model (ADR-003); no second backend.

## Alternatives rejected

- **React Native + Electron** — two runtimes to reach mobile + desktop; more surface area, no offline advantage.
- **Native per platform (Kotlin + Swift)** — best UX ceiling, but triples client effort for a solo-codebase team and a market that is Android-dominant.
- **DB-per-tenant / MongoDB** — rejected on tenancy and ledger grounds (see ADR-003, ADR-004).
- **A managed sync engine (PowerSync/ElectricSQL/WatermelonDB) in V1** — powerful for multi-writer, but adds a heavy dependency we don't need while V1 is single-writer. Reconsider when V2 multi-writer is scoped.
