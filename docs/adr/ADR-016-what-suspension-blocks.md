# ADR-016 — What a suspended subscription actually blocks

**Status:** Accepted · **Date:** 2026-09-23
**Interprets:** BR-1.3 — *"A tenant in suspended subscription state is read-only for its
users **except where noted**"*
**Related:** `01-vision-and-scope.md` §4 (manual payment), ADR-002 (offline-first), FR-1

## Context

V1 has no payment gateway. A tenant pays ETB 1,000/month, submits a screenshot, and a
Platform Admin verifies it and unlocks the subscription (Vision §4). When payment lapses the
subscription is suspended, and BR-1.3 says the tenant becomes read-only — leaving open
exactly which writes stop, which is the whole question.

The naive reading is "block all writes". Applied literally to this architecture it does
something indefensible.

A terminal may be holding days of **already-completed sales** in its outbox: money taken,
receipts printed, stock physically gone off the shelf. Those operations are a record of
things that happened in the world, not requests to do something. If `/sync/push` rejects
them because the subscription lapsed, the outbox holds them, retries, and is rejected again.
Eventually the device is replaced, reset, or the app reinstalled, and **the pharmacy's real
trading records are destroyed over a billing dispute**.

That is the opposite of what this product is for. Vision §6 puts "never lose a regulated
record" second only to "the daily loop never breaks", and a system that deletes a customer's
books when they are late paying has no business claiming either.

There is also a plain commercial reading: a pharmacy whose data we destroyed is not a
pharmacy that resumes paying.

## Decision

Suspension blocks **management writes**, and nothing else.

| Surface | Suspended | Why |
|---|---|---|
| `POST /sync/push` | **Allowed** | These are records of things that already happened. Refusing them destroys data we do not own. |
| `GET /sync/pull` | **Allowed** | A terminal running on stale prices charges customers the wrong amount. Suspension is between us and the owner; it must not reach the counter's customers. |
| Reports and reads | **Allowed** | Their data. Withholding it is leverage, not enforcement. |
| Creating branches, staff, products; changing prices | **Blocked** | Growing the business on the platform is the service being paid for. |
| Submitting a payment proof | **Allowed** | Blocking the one action that ends the suspension would be absurd. |

So "read-only" means: **the pharmacy cannot expand its use of the platform, but it never
loses a record and never overcharges a customer.**

### The block is enforced server-side, and the app is told why

A `SubscriptionGuard` runs after authentication and refuses management writes with `402
Payment Required` and a reason naming the subscription state. `402` rather than `403`: the
client can distinguish "you may not" from "this is a billing matter", and only the second
should send the owner to a payment screen.

### Suspension never rewrites history

Suspending is a state change on the subscription, recorded as an audit event. It touches no
sale, no shift, no stock. When payment resumes, nothing needs to be replayed or repaired —
the data was never interfered with.

## Rationale

- The distinction that matters is **records versus requests**. A sale pushed from an outbox
  is a record; creating a branch is a request. Suspension is a commercial lever and belongs
  on requests only.
- Applying the lever to reads and pulls punishes the pharmacy's *customers*, who have no
  part in the billing relationship, by causing wrong prices at the counter.
- The narrower the block, the less likely anyone is tempted to disable it in a hurry when a
  legitimate customer is wrongly suspended — and a control that gets disabled under pressure
  is not a control.

## Consequences

- A suspended tenant can go on trading indefinitely from its terminals, and the server will
  keep accepting the record of it. **That is intended**: the commercial lever is the loss of
  the console, the reports, and the ability to change anything — not the destruction of
  their books. If it proves too weak in the pilot, the answer is a different lever, not a
  more destructive one.
- The `SubscriptionGuard` must be explicit about which routes it exempts. An exemption list
  that grows by accident would hollow the rule out, so the exemptions are declared on the
  route with `@AllowWhenSuspended()` and are countable.
- A tenant suspended mid-sync sees some operations applied and no error. Correct: each one
  is a record, and each is accepted on its own merits.
- The pilot (`A-2`) must check that owners understand what suspension does and does not
  stop. A lever nobody understands does not change behaviour.

## Alternatives rejected

- **Block all writes including sync.** Destroys customer data over a billing matter, and
  contradicts Vision §6's second principle. Rejected outright; it is not a trade-off.
- **Accept sync but discard the operations silently.** Worse than rejecting: the terminal
  clears its outbox believing the data is safe, so the loss is both certain and invisible.
- **Block pull, allow push.** The terminal keeps selling at prices that may have changed,
  and the people harmed are customers of a pharmacy, not a party to our billing.
- **Put the tenant in a read-only *database* role.** Attractive at first glance — RLS-level
  enforcement rather than application-level — but it would block the audit and event writes
  that record the suspension itself, and it cannot make the record/request distinction,
  which is the entire point.
