# ADR-040 — Sync checks the permission matrix for each kind of operation

**Status:** Accepted · **Date:** 2026-10-08
**Closes:** the gap recorded in ADR-038 §7 and Consequences
**Depends on:** FR-2 (the permission matrix), ADR-005 (per-operation acks), ADR-016 (records
of what happened are not refused over billing), ADR-038 (supplier payments)
**Constrained by:** BR-4.1 (a real transaction is never dropped), AC-2.1 (denied at the API
layer, not only in the app)

## Context

Every management route checks the FR-2 matrix. `POST /sync/push` did not: any signed-in
member of a pharmacy could push any kind of operation, and the only thing deciding who did
what was which buttons the phone showed.

For most of the system's life that was harmless, because every role may do everything a
terminal sends — sell, receive, count a till. ADR-038 changed that. Paying a supplier is
offered to the owner and a branch manager only, and it can take cash out of a till's expected
figure. A cashier with a client of their own could have recorded "paid supplier 500 from the
till" and had the cash-up agree with them. ADR-038 said so and left it open as a change to
sync as a whole. This is that change.

## Decision

### 1. One capability per operation type, checked before anything else

`OPERATION_CAPABILITY` maps every entity type to the capability its sender needs. `applyOne`
looks the role in the token up against it before any read or write.

| Operation | Needs | Why |
|---|---|---|
| `sale`, `customer`, `credit_payment` | `sale.create` | the debt book is part of selling (ADR-034 §1) |
| `shift`, `cash_up` | `cashup.perform` | |
| `goods_receipt`, `stock_adjustment`, `supplier` | `goods.receive` | a supplier is opened by receiving; a miscount is found by whoever shelves |
| `supplier_payment` | `catalog.manage` | money leaving the business: owner and branch manager |
| `controlled_dispense`, `controlled_adjustment` | `controlled.dispense` | and still refused outright while the regulated half is off (ADR-024) |

The map is typed by the operation union, so **a new operation does not compile until
somebody has decided who may send it**.

### 2. A refusal is a rejected ack, not an error

The operation comes back `rejected` with a plain reason and is parked on the terminal, like
any other rejection (ADR-005). The rest of the batch is unaffected. Nothing is dropped
(BR-4.1): if a manager is demoted while holding a queued supplier payment, it sits in "needs
attention" with its reason until the owner deals with it.

### 3. What this deliberately does not check

- **The branch.** An operation for a branch the sender is not assigned to is still accepted.
  A cashier moved between branches while offline has real sales queued for the old one, and
  refusing them strands money that was really taken. Reading across branches is refused
  (`branch-scope.ts`); writing a record of what happened is not.
- **That the actor is the signed-in user.** A shared phone pushes what an earlier user rang
  up. The sale names its cashier; the push is made by whoever is holding the phone.
- **`own` versus `branch`.** A cashier's `cashup.perform` is "own shift". The matrix says
  *whether*; whose shift it is belongs to the cash-up, which carries its owner.

Each is a narrower control that could be added; each would start rejecting operations that
are true. They are listed so the absence is a decision.

## Consequences

- **Today exactly one thing changes:** a cashier's `supplier_payment` is refused. Every
  other operation is one every role already holds the capability for. The guardian suite
  asserts that list, so widening it is a visible act.
- The phone already hid the button, so no released build can produce a refused operation.
- Roles are read from the access token, which lives fifteen minutes. A demotion takes
  effect on sync within that.
- A future operation that only some roles may send is one line here, not a new mechanism.

## Verification

`apps/api/test/guardian/g4-suppliers.spec.ts`, "who may pay a supplier": a cashier is
refused and nothing is written; a cashier cannot move a till's expected cash this way; the
owner and a manager are accepted; the refusal does not take the rest of the batch with it; a
cashier still receives goods and opens a supplier; and the full list of operation types is
pinned, with exactly one closed to a cashier.
