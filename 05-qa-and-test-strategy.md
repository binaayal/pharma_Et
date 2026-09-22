# 05 — QA & Test Strategy

**Project:** Pharmacy System · **Release:** V1
**Status:** ✅ Draft · owner: Bina
**Depends on:** `02-srs.md`, `03-architecture.md`, `04-system-design.md`, ADR-002/004/007/008
**Feeds:** `06-delivery-plan.md`, CI configuration, the walking-skeleton spike

> The quality standard here is **risk-weighted**, not coverage-chasing. The merge gate is a
> set of named guardian invariant suites (ADR-008). This document defines those suites, the
> test pyramid, the compliance traceability that makes the system auditable, and the
> definition of done.

---

## 1. Objectives

Prove, continuously and automatically, that the failures this system cannot afford **do not
happen**: cross-tenant leakage, lost/duplicated transactions, a mutable or corrupted
controlled-substance ledger, money errors, silent oversell, unenforced psychotropic rules,
and data loss across offline periods. Everything else is secondary to these.

---

## 2. Testing philosophy (ADR-008)

- **Invariants over percentages.** The CI gate is the guardian suites (§4), not a global coverage number.
- **Test where the risk is.** Rigor is tiered (§3).
- **The hard problems get the right tools** — property-based testing for sync, contract testing for the client/server sync envelope, real-device testing for offline claims. Example-based unit tests alone cannot certify a sync engine.
- **Traceability is an audit artifact.** Every regulated requirement maps to ≥ 1 test (§8).

---

## 3. Risk tiers

| Tier | Scope | Rigor | Coverage signal (secondary) |
|---|---|---|---|
| **T0 — Invariants** | Tenant isolation, sync engine, ledger, money | Guardian suites (§4) + property-based; near-exhaustive on the invariant | n/a — gated by suites passing, not % |
| **T1 — Domain logic** | Inventory (FEFO, negative-stock), POS/dispensing rules, cash-up, projections | Thorough unit + integration | ≥ 90% branch |
| **T2 — Adapters/API** | Controllers, repositories, sync endpoints, dashboard API | Integration + contract | ≥ 80% line |
| **T3 — UI glue** | Flutter screens, dashboard views | Critical-path e2e + smoke; widget tests for stateful UI | no hard % target |

A missed test in T0 is a release blocker; a missed test in T3 is a backlog item. Rigor
follows consequence.

---

## 4. Guardian invariant suites (the merge gate)

These **must pass on every PR**. No override, no "flaky-retry" — a flaky guardian test is
itself a blocking defect.

| # | Invariant | Representative assertions |
|---|---|---|
| **G1** | **Tenant isolation** | With ≥ 2 seeded tenants, no API/repository call returns another tenant's row; RLS blocks a deliberately unscoped query (the "no unscoped access" test); Platform-Admin tenant reads are explicit + audited. |
| **G2** | **Sync integrity** | Replaying any `op_id` applies zero additional effect (AC-9.2); a generated batch applied in `terminal_seq` order yields the same state regardless of network drops; N offline ops sync exactly once with zero loss (AC-9.1). |
| **G3** | **Ledger immutability** | No code path updates or physically deletes an `event`; a correction only appends a compensating event; `controlled_stock_view == fold(events)` after arbitrary event sequences (AC-3.3, AC-6.1). |
| **G4** | **Money integrity** | All money is integer santim; no float appears in money math; `sale.total == Σ line_total`; payments reconcile to sale totals. |
| **G5** | **Oversell detected** | Selling below zero stock for a standard drug completes the sale, drives stock negative, and raises an oversell flag/counter — never silently (AC-3.1, ADR-002). |
| **G6** | **Psychotropic rules** | Two psychotropics on one prescription is **blocked** (AC-4.2); a >15-day psychotropic prescription is **rejected** (AC-4.3); rules run offline (locally). |
| **G7** | **Offline resilience** | A locally committed sale survives app kill and device reboot and later syncs (NFR-1.3); no core sale is ever hard-blocked, even past the offline ceiling (BR-2.3). |

---

## 5. Test pyramid & types

- **Unit (bulk):** pure domain logic — FEFO selection, pricing, cash-up variance, projection folds, validity checks. Fast, deterministic, no I/O.
- **Integration:** repositories against a **real Postgres** (not mocked) so RLS, constraints, and `SET LOCAL` scoping are exercised as they run in production. Mocked-DB tests cannot validate RLS.
- **Contract (§6):** the client/server sync envelope — the highest-value drift guard.
- **Property-based:** the sync engine and the ledger fold. Generate random op sequences, replays, reorderings, and partitions; assert G2/G3 hold for all. This is the correct tool for concurrency/replay logic; example tests only cover the cases you imagined.
- **End-to-end:** critical user journeys through real clients (receive → sell → cash-up → dashboard).
- **Offline/resilience scenario (§7):** simulated 72h offline, reconnect, kill/partition chaos.
- **Performance (§9)** and **security (§10)** as their own suites.

---

## 6. Sync contract & anti-drift strategy

The client/server sync envelope (`04-system-design.md` §7) is the one contract whose drift
is catastrophic — divergent client/server versions silently drop or duplicate real
transactions. Therefore:

- The sync envelope + endpoints have a **single source of truth** schema (OpenAPI or a shared schema file). Dart (Flutter) and TypeScript (NestJS) types are **generated** from it, not hand-written on each side.
- **Contract tests** run both halves against the schema: server responses and client requests are validated; a breaking change fails CI on both sides.
- Any change to §7 requires bumping the contract and passing both consumer and provider contract tests before merge.

---

## 7. Offline & resilience testing

The offline guarantees (NFR-1) cannot be certified by mocks alone.

- **Offline scenario harness:** drive a client through a simulated **72h offline** period — accumulate sales/dispenses/cash-up, then reconnect and assert G2/G7 (exact-once sync, zero loss).
- **Chaos:** kill the app mid-sale and mid-sync; drop the network mid-push; corrupt-then-restart; assert durability and idempotent recovery.
- **Device matrix:** **real low-end Android devices**, not only emulators. The target market runs cheap Android hardware; local-op latency (NFR-3.2 <100ms), SQLite behavior under low storage, and power-loss durability are **device-dependent** and must be measured on representative hardware. iOS is tested on the shared codebase as a secondary target (ADR-001).

---

## 8. Compliance testing & traceability

The regulated requirements are the highest-priority traceability targets and produce
**audit artifacts**:

- Every controlled-substance/psychotropic requirement (FR-4 rules, FR-6, NFR-5.1 retention) maps to ≥ 1 explicit, named test, recorded in the **Requirements Traceability Matrix** (SRS §6, filled here).
- Retention is tested as policy: ledger events cannot be deleted; retention duration is configurable to the **verified** EFDA value once `[ASSUMPTION]` A-1 clears. **Until A-1 is verified, compliance tests are marked provisional** — they assert the mechanism (immutability, retention enforcement) but not final regulatory numbers.
- The controlled-substance ledger export (FR-6) is tested to reproduce a complete, ordered history for an audit window.

> **Gate:** no regulated requirement is "done" without a passing, RTM-linked test. This is the concrete meaning of the "software quality assurance standard" from the project's outset.

---

## 9. Performance & load testing (mapped to NFRs)

| NFR | Test |
|---|---|
| NFR-3.2 local op < 100ms | Measured on **low-end Android**, not emulator, under realistic local DB size. |
| NFR-3.3 sync < 10s after 72h | Sync a 72h transaction volume; assert wall-clock on a typical mobile connection. |
| NFR-3.4 API p95 < 500ms (sync) / < 1s (dashboard) | Load test at target concurrency. |
| NFR-3.1 1,000 tenants | Seed representative multi-tenant data; verify query plans use tenant/branch indexes and don't degrade; RLS overhead measured. |
| NFR-1.4 99.5% availability | Verified operationally (monitoring/SLO), not a unit test. |

---

## 10. Security testing

- **Isolation/penetration:** attempt cross-tenant reads/writes by every route; assert RLS + guard block them (extends G1).
- **Authorization matrix:** test **every role × capability cell** of the FR-2 matrix — allowed cells succeed, denied cells fail at both app and API layers (AC-2.1).
- **Auth:** PIN rate-limiting, token expiry, offline-cache expiry at the window boundary.
- **Dependencies:** automated dependency/vulnerability scanning in CI.
- **Transport:** TLS enforced; secure on-device storage for cached credentials.

---

## 11. Test data & multi-tenant harness

A shared harness seeds **≥ 2 tenants, each with ≥ 2 branches and staff across all roles**,
so isolation and scoping are exercised *by construction* in every integration test. No test
runs single-tenant — cross-tenant leakage is only visible when a second tenant exists.

---

## 12. Environments & CI quality gates

**Environments:** local → CI → staging (production-like Postgres + RLS) → production.

**CI gates (block merge):**
1. All **guardian suites** (§4) green.
2. **Contract tests** (§6) green on both client and server.
3. **"No unscoped access"** lint + test (ADR-007) green.
4. Per-tier coverage thresholds met (T1 ≥ 90% branch, T2 ≥ 80% line).
5. Migration check (schema + RLS policies apply cleanly).
6. Dependency scan clean of high-severity issues.

**Release gates (block GA):** all merge gates + performance suite within NFR budgets +
successful **field UAT** (§15).

---

## 13. Definition of Done

**Standard requirement:** code + tests (appropriate tier) + RTM entry + passes all guardian
suites + peer review + docs/ updated if a contract changed.

**Regulated requirement (FR-4 rules, FR-6, NFR-5.1):** all of the above **plus** an
RTM-linked compliance test **plus** explicit sign-off. A regulated feature is never "done"
on green tests alone until A-1 is verified and the compliance test reflects the real
directive.

---

## 14. Bug severity & release-blocker policy

| Severity | Definition | Policy |
|---|---|---|
| **S1** | Data loss, cross-tenant leakage, ledger corruption, money error | **Release blocker.** Stop the line. |
| **S2** | Core-loop broken (can't sell/receive/cash-up), sync failure | Blocker for the affected release. |
| **S3** | Non-core functional defect | Scheduled fix. |
| **S4** | Cosmetic/minor | Backlog. |

The S1 list is exactly the guardian-suite (§4) domain — these bugs should be caught before
merge, and any that escape are treated as escaped-defect incidents (§16).

---

## 15. Field UAT / pilot

NFR-1 (offline through real power cuts) **cannot be fully certified in CI**. Before GA, run
a supervised pilot in ≥ 1 real pharmacy through real outages, validating the daily loop,
cash-up adoption, and offline durability in the field. Pilot sign-off is a release gate.

---

## 16. Quality metrics

Tracked continuously: escaped-defect count by severity, sync failure/retry rate (from
telemetry, NFR-7), **oversell counts** (a real business signal, not only a test concern),
guardian-suite flakiness (target zero), and coverage per tier as a trend, not a target.

---

## 17. Walking-skeleton test scope
The spike ships with a **minimum guardian set**: G1 (isolation — two tenants), G2 (sync
exact-once across a simulated offline period), G4 (money integer/reconcile), and G7 (commit
survives kill/reboot). If the spine can't pass these four, no breadth is built on it.
