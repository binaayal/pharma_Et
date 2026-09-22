# ADR-009 — Sync API backward-compatibility window for offline clients

**Status:** Accepted · **Date:** 2026-09-21

## Context
The system is offline-first with a supported window of up to 7 days (NFR-1). A terminal may
be running an **older app/contract version** than the server when it finally reconnects —
because it was offline while the backend was deployed and upgraded. If a backend release
breaks the sync contract (`04-system-design.md` §7), a reconnecting terminal could fail to
sync and **lose days of real, committed sales and dispenses**. This is an S1 (data-loss)
failure.

## Decision
- The sync API is **versioned independently** of the app version, and the server **must
  accept the current contract and at least the previous one (N-1)**, for a window **≥ the
  offline ceiling (7 days) plus a safety margin** — practically, N-1 support is maintained
  for no less than one full release cycle beyond the offline window.
- Changes to the sync envelope are **additive/backward-compatible by default**; a breaking
  change requires a new contract version, dual-support for the window, and a documented
  client-migration path — never a same-version breaking change.
- Every backend release is verified against the **previous** client contract in CI
  (provider contract tests, `05-qa` §6) before it can promote.

## Rationale
- Offline-first is meaningless if a backend deploy can strand offline data. Compatibility is
  the property that makes the 7-day guarantee real.
- Independent contract versioning lets the backend evolve without forcing lockstep client
  updates that offline terminals cannot receive in time.

## Consequences
- The CI promotion gate includes an **N-1 contract compatibility check**; failing it blocks
  the release (delivery plan §6).
- The `SyncService` (ADR-005) carries a contract version; the server routes by it.
- Deprecating a contract version is a controlled change: only after telemetry shows no active
  clients on it and the window has elapsed.

## Alternatives rejected
- **Single contract version, force-update clients** — impossible for offline terminals; guarantees data loss.
- **Best-effort compatibility (no window guarantee)** — leaves the S1 risk unmanaged.
