# ADR-006 — Client-generated, time-ordered identifiers & idempotent offline writes

**Status:** Accepted · **Date:** 2026-09-21

## Context
The system is offline-first (ADR-002): a terminal creates records (sales, receipts, ledger
events) while offline and syncs them later. This makes **server-assigned sequential primary
keys impossible** — the record has an identity before the server ever sees it. Sync is
at-least-once, so the same operation may arrive more than once and must not double-apply.

## Decision
- **Primary keys are UUIDv7**, generated **on the client** at record creation. UUIDv7 is time-ordered (RFC 9562), so it stores natively as Postgres `uuid` and preserves index locality (unlike random UUIDv4).
- **Every sync operation carries an `op_id`** (also UUIDv7), a client-generated **idempotency key**. The server enforces `UNIQUE (tenant_id, op_id)`; a replayed op is acknowledged as a duplicate and applied zero additional times.
- **Ordering per terminal** is a monotonic `terminal_seq` (not wall-clock), because offline clock skew makes timestamps unsafe for ordering.

## Rationale
- Offline creation demands globally-unique IDs the client can mint without coordination.
- UUIDv7 gives that *and* good B-tree locality, avoiding the write-amplification of UUIDv4.
- An explicit idempotency key makes at-least-once sync safe without server-side dedup heuristics.

## Consequences
- All synced entities use UUIDv7 PKs; no `SERIAL`/auto-increment on synced tables.
- The server must persist applied `op_id`s for the retention needed to cover the offline window (and beyond, cheaply).
- Client and server share the UUIDv7 + op_id contract; documented in `04-system-design.md` §Sync.

## Alternatives rejected
- **Auto-increment / SERIAL PKs** — impossible offline; would require server round-trip to create a record.
- **UUIDv4** — client-generatable but random; fragments indexes at volume.
- **Composite natural keys** (branch+counter) — collide across offline terminals and leak business meaning into identity.
