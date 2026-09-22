# ADR-005 — Sync protocol: hand-rolled REST behind a SyncService seam

**Status:** Accepted · **Date:** 2026-09-21

## Context
V1 is single-writer offline (ADR-002): one terminal per branch, no write conflicts. The
client commits core-loop writes to local SQLite and an outbox, then syncs to the NestJS
backend (source of truth). V2 will add multi-writer offline with conflict resolution
(deferred), which may warrant a managed sync engine (PowerSync/ElectricSQL/etc.).

We must choose V1's sync mechanism without foreclosing V2.

## Decision
- V1 sync is **plain REST endpoints on NestJS** implementing: ordered, idempotent **push** of outbox operations, and **pull** of reference-data deltas since last sync.
- The mechanism sits **behind a `SyncService` interface** on both client and server, so the concrete protocol is an implementation detail the rest of the app does not depend on.
- Idempotency via client-generated **operation IDs**; the server records applied op IDs and ignores replays.
- Deletes propagate as **tombstones** (ADR-002/004 invariant).

## Rationale
- Single-writer sync is simple enough to hand-roll, fully auditable, and free of a heavy third-party dependency next to a regulated ledger.
- The interface seam means V2 can replace the engine (e.g., adopt a managed multi-writer sync) without a client rewrite — the cost of the seam now is negligible; the cost of not having it later is a rewrite.

## Consequences
- V1 owns retry, ordering, and idempotency logic — must be covered by tests (AC-9.1, AC-9.2).
- The `SyncService` contract (operation envelope, op IDs, delta cursor) is a stable interface documented in `04-system-design.md`.

## Alternatives rejected
- **Managed sync engine in V1** — rejected: heavy dependency for a conflict-free scenario.
- **No abstraction (endpoints called directly)** — rejected: couples clients to the V1 protocol and forces a rewrite at V2.
