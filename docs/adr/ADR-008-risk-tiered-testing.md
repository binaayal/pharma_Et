# ADR-008 — Risk-tiered testing; guardian invariant suites are the CI gate

**Status:** Accepted · **Date:** 2026-09-21

## Context
This is a regulated (controlled-substance), offline-first, multi-tenant system where the
expensive failures are specific: cross-tenant data leakage, lost/duplicated transactions on
sync, a corrupted or mutable controlled-substance ledger, and money errors. A blanket
coverage target (e.g. "80%") measures the wrong thing — it rewards covering trivial code
and can pass while a critical invariant is untested.

## Decision
- Code is **risk-tiered** (see `05-qa-and-test-strategy.md` §3). Test rigor is set per tier, not globally.
- The **CI merge gate** is a set of named **guardian invariant suites** that must pass — always, no override:
  1. **Tenant isolation** — no unscoped query; RLS blocks cross-tenant access.
  2. **Sync integrity** — idempotent replay, ordered apply, zero loss/duplication across offline.
  3. **Ledger immutability** — no update/delete path; projection == fold(events).
  4. **Money integrity** — integer santim, no float; totals reconcile.
  5. **Oversell is detected & reported**, never silently swallowed.
  6. **Psychotropic rules** — block (not warn), validity enforced.
  7. **Offline resilience** — committed data survives kill/reboot; a core sale is never blocked.
- Coverage thresholds exist **per tier** as a secondary signal, not the primary gate.

## Rationale
- The invariants above are where real money and real compliance live; making them the gate ties CI to the actual risk model.
- Per-tier thresholds stop coverage-chasing on low-risk glue code while demanding depth where it matters.

## Consequences
- Every guardian suite is first-class, maintained, and non-flaky; a flaky guardian test is a release-blocking defect, not a "retry".
- New features touching a guarded area must extend the relevant guardian suite before merge.
- Reviewers check requirement→test traceability (RTM), not just a coverage number.

## Alternatives rejected
- **Blanket global coverage % as the gate** — rewards the wrong tests; can pass with critical invariants untested.
- **No mandatory gate (trust review)** — insufficient for a regulated, data-critical system.
