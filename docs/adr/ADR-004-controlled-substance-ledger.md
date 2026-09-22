# ADR-004 — Controlled-substance immutable ledger

**Status:** Accepted · **Date:** 2026-09-21

## Context

Controlled/psychotropic substances carry legal record-keeping obligations (FR-6). Per
`[ASSUMPTION]` A-1 (EFDA directive No. 1121/2025, pending compliance verification), records
must be retained for a minimum period (stated as 5 years) and must be auditable. Standard
drugs have no such requirement and are managed as ordinary mutable stock.

Mixing these two into one mutable model would be wrong in both directions: it would
under-protect controlled substances (mutable records aren't audit-defensible) and
over-engineer standard drugs (event-sourcing all inventory is needless complexity).

## Decision

- **Controlled substances use an append-only, event-sourced ledger.** Every relevant action (receipt, dispense, adjustment) is an **immutable event**. Current stock for a controlled substance is a **projection** computed over its events, not a mutable counter.
- **No physical deletes or updates on ledger events.** Corrections are new compensating events that reference the original; deletes are **tombstone events**. Nothing is ever removed or overwritten.
- **Retention:** minimum per EFDA (stated 5 years); we hold **7 years** for margin. Ledger data is never hard-deleted, including through the sync layer (tombstones only — inherited constraint from ADR-002).
- **Standard drugs remain mutable state** with a negative-stock (oversell-and-reconcile) policy and **soft-delete** (never hard-delete) for auditability, but are *not* event-sourced.
- Dispensing-time compliance rules (FR-4: dedicated prescription paper, one psychotropic substance per prescription, 15-day vs. 30-day validity) are enforced at POS and recorded as ledger events.

## Rationale

- An append-only ledger is the correct, standard pattern for an auditable, legally-retained record: it is tamper-evident, reconstructable to any point in time, and answers "who did what, when" by construction.
- Scoping event-sourcing to *only* the controlled subset keeps the pattern's cost where it pays off and keeps the 95% of ordinary inventory simple.
- Projections give fast "current stock" reads without sacrificing the immutable history.
- The general action audit log (folded into V1, see Vision & Scope §2.1.1) reuses this event infrastructure, generalized beyond controlled substances.

## Consequences

- The sync engine (ADR-002) must never treat a ledger delete as a physical removal; this is a hard invariant, tested.
- Storage grows monotonically for the controlled subset; acceptable given retention obligations and low relative volume.
- Compliance verification of A-1 is a **blocker before SRS freeze** — retention period, required fields, and dispensing rules must be confirmed by a compliance/legal review, not taken from memory.
- Backups must guarantee the retention window independent of tenant lifecycle (a tenant leaving does not purge legally-retained records within the window).

## Alternatives rejected

- **One mutable inventory model for all drugs** — rejected: not audit-defensible for controlled substances.
- **Event-source the entire inventory** — rejected: needless complexity for standard drugs; slows the team and the reads for no compliance benefit.
- **Hard-delete with an external audit log** — rejected: two sources of truth that can diverge; the ledger *is* the record.
