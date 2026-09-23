# ADR-012 — Extending the sync envelope: additive entity types, and what the terminal is allowed to compute

**Status:** Accepted · **Date:** 2026-09-23
**Depends on:** ADR-005 (sync seam), ADR-006 (identifiers), ADR-009 (N-1 compatibility), ADR-010 (codegen)
**Related:** `04-system-design.md` §7, `06-delivery-plan.md` §7 (controlled artifacts)

## Context

Phase 1 adds capabilities the counter performs offline — cash-up first, then the rest of the
core loop — and each needs a new operation type on the wire. The envelope is a **controlled
artifact**: every change to it needs an ADR (`06` §7), and every deployed server must keep
serving the previous contract for longer than the offline ceiling (ADR-009).

Two questions arise the first time, and would otherwise be re-argued every time:

1. **How does a new entity type reach terminals that have not updated?** Clients update
   out-of-band through a store; a pharmacy can be running a months-old build.
2. **Cash-up needs an "expected cash" figure. Who computes it?** The terminal has only its
   local sales; the server has everything that has synced. They can legitimately disagree.

## Decision

### 1. New entity types are additive, and the contract MINOR version carries them

`entityType` is a discriminated union. Adding a variant is backward-compatible **in one
direction only**, and the asymmetry is the whole point:

- an **old client** never sends the new type, so a new server handles it fine;
- a **new server** receiving an old client's operations handles them fine;
- an **old client** receiving a new server's *pull* payload must not choke on unknown
  fields — so pull responses only ever gain optional fields, never change existing ones.

So: a new entity type bumps **MINOR** (1.0.0 → 1.1.0) and `SUPPORTED_CONTRACT_VERSIONS`
gains it while keeping every version inside the N-1 window. A **MAJOR** bump means a
breaking change, needs its own ADR, and needs dual handling in the server for the length of
the window.

**Section 4 below is the version log.** An additive change appends an entry there rather
than spawning a new ADR — that entry, the contract tests, and the guardian update are what
the controlled-artifact gate is checking for.

### 2. A rejected operation must never be caused by a *newer* client talking to an *older* server

A terminal that updates before its server — a store rollout racing a deploy — will push an
entity type the server has never heard of. The server rejects it with a reason, the client
parks it for attention, and **the transaction is not lost**; it applies after the server
catches up and the client retries. That is already how `rejected` works (`04` §7.1); this
ADR states that it is a *supported* path, not a pathological one, and that the client must
therefore keep retrying parked operations after an app update rather than only on demand.

### 3. The terminal computes what the cashier is shown; the server recomputes for audit

Cash-up needs "expected cash". The terminal can only know its **local** sales. The server
knows everything that has **synced**. These differ whenever anything is still queued — which
is the normal state of this product, not an edge case.

Both numbers are kept:

| Field | Meaning | Authority for |
|---|---|---|
| `expectedSantim` | what the terminal computed and **showed the cashier** at count time | the human event — what the person was asked to reconcile against |
| `countedSantim` | what the cashier physically counted | the human event |
| `varianceSantim` | `counted − expected`, as shown | the human event |
| `serverExpectedSantim` | recomputed by the server from synced sales when the operation lands | audit and reconciliation |

The terminal's figure is **never overwritten**. A cash-up is a record of something a person
did at a moment in time, and rewriting the number they were shown would destroy the only
evidence of what they actually agreed to. When the two disagree, that is a finding to
surface — usually queued sales, occasionally something worse — and it is exactly the signal
an owner deploying this product for anti-shrinkage wants.

## Rationale

- Versioning the contract on MINOR for additive change keeps ADR-009's window meaningful
  without a version explosion.
- Keeping both expected figures follows the same principle as the oversell counter (ADR-002,
  guardian G5): where offline makes a discrepancy *unpreventable*, the system's job is to
  make it **visible and attributable**, never to paper over it by picking one number.
- Storing the shown figure immutably is what makes the cash-up defensible if it is ever
  disputed. A reconciliation report that silently corrects itself is not evidence.

## Consequences

- `cash_up` carries two expected figures, and every report showing one must be explicit
  about which. The Z-report shows both when they differ, and says why.
- The server must recompute expected cash on apply — cheap, and it needs the shift's sales
  anyway.
- A cash-up pushed before some of its shift's sales have synced will record a divergence
  that later resolves. The report must therefore state data currency (BR-8.1) rather than
  present a stale number as final.
- Every future entity type appends to §4 rather than arguing this again.

## Alternatives rejected

- **Server computes expected, terminal displays nothing until it syncs.** Breaks cash-up
  offline, which is when a pharmacy actually does it — at close, often with the power out.
- **Terminal's figure is authoritative, server never recomputes.** Loses the audit, and
  makes the anti-shrinkage control trivially defeatable by a terminal that was never synced.
- **Overwrite the terminal's figure with the server's on arrival.** Destroys the record of
  what the cashier was shown, which is the only thing that makes a variance attributable.
- **A new contract MAJOR per entity type.** Version churn with no compatibility benefit,
  and it would force dual handling for changes that are purely additive.

---

## 4. Contract version log

| Version | Date | Change | Compatibility |
|---|---|---|---|
| **1.0.0** | 2026-09-22 | Initial envelope: `sale`, `goods_receipt` (`04` §7) | — |
| **1.1.0** | 2026-09-23 | Adds `shift` and `cash_up` entity types (FR-8). Pull response unchanged. | Additive. A 1.0.0 client is fully served; a 1.1.0 client against a 1.0.0 server has its new operations `rejected` with a reason and retried later, never dropped. |
