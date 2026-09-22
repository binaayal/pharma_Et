# Pharmacy System — Documentation

Engineering documentation for the **Pharmacy System**: a multi-tenant, offline-first
SaaS for independent Ethiopian pharmacies, built to run the pharmacy owner's
managerial workflow (inventory, dispensing, cash control, compliance) across one or
many branches.

This tree is the single source of truth. It is written to be read by **both engineers
and Claude Code** — every document is self-contained, states its assumptions, and links
its dependencies.

---

## How to use this documentation

**Read in order.** Each document derives from the one above it. Do not design against
the SRS before Vision & Scope is settled; do not build against the architecture before
the SRS is settled.

**For Claude Code specifically:**
- Start any task by reading `01-vision-and-scope.md` (what and why) and the relevant ADRs (the constraints you must not violate).
- ADRs are **binding**. If a task appears to require violating an ADR, stop and flag it — do not silently work around it.
- When a document says a decision is "deferred to V2," do not implement it in V1 code, even opportunistically.
- Treat everything marked `[ASSUMPTION]` or `[OPEN]` as unverified. Do not build load-bearing logic on it without the owner confirming.

---

## Document map

| # | Document | Status | Purpose |
|---|----------|--------|---------|
| 00 | `README.md` (this file) | ✅ Draft | Index, conventions, status |
| 01 | `01-vision-and-scope.md` | ✅ Draft | Why we build, for whom, what's in/out of V1 |
| 02 | `02-srs.md` | ✅ Draft | Detailed functional (FR) & non-functional (NFR) requirements + traceability |
| 03 | `03-architecture.md` | ✅ Draft | C4 views, component boundaries, deployment topology |
| 04 | `04-system-design.md` | ✅ Draft | Data model, sync protocol, API contract, RBAC model |
| 05 | `05-qa-and-test-strategy.md` | ✅ Draft | Test pyramid, coverage targets that mean something, compliance test cases |
| 06 | `06-delivery-plan.md` | ✅ Draft | SDLC model, phases, sprint plan, definition of done |
| — | `adr/` | ✅ Draft | Architecture Decision Records (binding decisions + rationale) |

Status legend: ✅ Draft · ⏳ Next up · 🔜 Planned · 🔒 Frozen (change requires an ADR)

---

## Architecture Decision Records

ADRs record **irreversible-by-default decisions** with their rationale and the
alternatives we rejected. They exist so that "why did we do it this way?" has one
answer, permanently.

| ADR | Decision | Status |
|-----|----------|--------|
| [ADR-001](adr/ADR-001-platform-and-stack.md) | Platform & technology stack | Accepted |
| [ADR-002](adr/ADR-002-offline-single-writer-first.md) | Single-writer offline in V1; multi-writer deferred | Accepted |
| [ADR-003](adr/ADR-003-multi-tenancy-isolation.md) | Multi-tenancy isolation model | Accepted |
| [ADR-004](adr/ADR-004-controlled-substance-ledger.md) | Controlled-substance immutable ledger | Accepted |
| [ADR-005](adr/ADR-005-sync-protocol.md) | Sync protocol: hand-rolled REST behind a SyncService seam | Accepted |
| [ADR-006](adr/ADR-006-identifiers-and-offline-writes.md) | Client-generated UUIDv7 identifiers & idempotent offline writes | Accepted |
| [ADR-007](adr/ADR-007-persistence-and-rls-enforcement.md) | Persistence via TypeORM with per-request Postgres RLS | Accepted |
| [ADR-008](adr/ADR-008-risk-tiered-testing.md) | Risk-tiered testing; guardian invariant suites are the CI gate | Accepted |
| [ADR-009](adr/ADR-009-sync-backward-compatibility.md) | Sync API backward-compatibility window for offline clients | Accepted |

---

## Conventions

- **FR-n / NFR-n** — requirement identifiers, stable for the life of the project. Never renumber; deprecate instead.
- **`[ASSUMPTION]`** — a belief we are building on that has not been verified. Must have an owner and a resolution date.
- **`[OPEN]`** — an unresolved question blocking a decision.
- **Tenant** — a pharmacy business (one owner). **Branch** — a physical store belonging to a tenant. **Terminal** — a single device running the app at a branch.
- Currency is **ETB (Ethiopian Birr)**. Dates in user-facing surfaces support the **Ethiopian calendar**; storage is always UTC ISO-8601.
- Regulatory references (EFDA) are treated as `[ASSUMPTION]` until confirmed by compliance review — see `01-vision-and-scope.md` §7.

---

## Current status (V1)

Phase: **Design track complete.** The full documentation suite (`01`–`06`) and ADR-001–009
are drafted, cross-referenced, and traceable. No production code yet. The next action is
**Phase 0** (`06-delivery-plan.md` §2): stand up CI/CD and environments and build the
walking-skeleton spike — one tenant/branch/terminal, receive→sell→decrement→sync→dashboard —
to its guardian gate (G1, G2, G4, G7) before any breadth features begin.

**Open blocker before compliance work (Phase 2):** `[ASSUMPTION]` A-1 — EFDA directive
1121/2025 retention and psychotropic-dispensing rules must be verified by compliance review.
It gates freezing the controlled-substance data model, not the earlier phases.
