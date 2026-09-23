# ADR-002 — Single-writer offline in V1; multi-writer deferred to V2

**Status:** Accepted · **Date:** 2026-09-21

## Context

FR-9 (offline sync) has two difficulty tiers:

- **Single-writer:** one terminal per branch. No two devices write the same data concurrently, so no write conflicts are possible.
- **Multi-writer:** multiple terminals per branch operating offline concurrently, then syncing. This requires a full conflict-resolution policy (NFR-2).

Inventory is a **conservation-law domain**: a stock count is a claim about physical
goods that either exist or don't. You cannot sell the same physical box twice.

The critical property: **offline multi-writer on a decrementing quantity cannot *prevent*
an oversell — it can only *detect and report* it.** If two offline cashiers each sell the
last unit, both sales are physically real by the time they sync. No CRDT, vector clock, or
merge strategy undoes a physical fact that already happened in two places. The only honest
resolution is to allow the oversell, flag it, and reconcile against a physical count — which
is exactly the negative-stock policy already chosen for standard drugs.

## Decision

- **V1 ships single-writer offline only.** One terminal per branch. The sync protocol is a simple append-only outbox: the client queues operations locally in SQLite, the server (source of truth) applies them in order on reconnect, and the client pulls deltas. No conflict engine.
- **Multi-writer offline + conflict resolution (full FR-9 + NFR-2) is deferred to V2.**
- Standard-drug inventory uses the mutable, negative-stock (oversell-and-reconcile) model. Controlled substances use the append-only ledger (ADR-004).
- The supported offline window and its guarantees are specified in the SRS (NFR); candidate is up to 7 days (`[OPEN]` O-1).

## Rationale

- Most independent Ethiopian pharmacies run a single POS terminal per branch (`[ASSUMPTION]` A-3), so single-writer covers the large majority of V1 tenants with none of the conflict complexity.
- Leading V1 with the hardest distributed-systems problem in the system is the most common way projects of this shape fail. Sequencing it behind a proven core loop de-risks the whole program.
- Single-writer sync is simple enough to be fully auditable — essential next to a regulated ledger.
- Team size does not change this: more engineers make the eventual V2 conflict engine buildable, but they do not change the physics or the correct build order.

## Consequences

- A branch that genuinely needs concurrent terminals in V1 is unsupported until V2. This is an accepted, documented limitation, surfaced to sales.
- Inter-branch transfer (FR-5) is therefore **online-only** and deferred to V1.x: a long offline window would let a branch dispatch stock the other branch already consumed.
- The sync layer must treat deletes as **tombstones**, never physical row removals, so that the append-only guarantees (ADR-004) and soft-delete retention hold. This constraint is inherited by V2's conflict engine.
- **Before breadth features, we build a walking-skeleton spike** proving the sync spine end-to-end for one tenant/branch/terminal: receive stock → sell → decrement → sync → visible on the web dashboard.

## Alternatives rejected

- **Multi-writer offline in V1** — rejected: maximal risk, minority need, and it cannot deliver a guarantee (oversell prevention) that customers might assume it does.
- **Online-only V1 (no offline)** — rejected: violates the core value proposition; the counter must sell through power cuts.
- **Adopt a managed multi-writer sync engine now** — rejected for V1 (see ADR-001); revisit when V2 is scoped.
