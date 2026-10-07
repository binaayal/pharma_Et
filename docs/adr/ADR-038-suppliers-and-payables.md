# ADR-038 — Suppliers and what is owed to them: the credit ledger, turned round

**Status:** Accepted · **Date:** 2026-10-07
**Implements:** FR-18 (suppliers and payables) — `07-v2-sellability-plan.md` §3.3
**Depends on:** ADR-034 (the customer credit ledger, which this mirrors), ADR-002 (offline
first), ADR-006 (client-minted ids), ADR-009 (N-1), ADR-012 (extending the envelope; §3,
two figures kept apart), ADR-003 (tenant isolation), ADR-036 (the return list)
**Constrained by:** guardian G4 (money is exact), BR-8.2 (the cash-up counts the drawer)

## Context

A goods receipt recorded a supplier's **name**, as free text, and nothing about whether the
delivery had been paid for. So "EPSS", "Epss" and "E.P.S.S." were three suppliers, and what
the pharmacy owed lived in a drawer of invoices and in each supplier's own book. For most
owners that is the largest number they do not know.

ADR-036 already groups near-expiry stock by the supplier name on its receipt. This is the
other half: who the suppliers are, and what each is owed.

It is the customer credit ledger (ADR-034) with the direction reversed, and it is built the
same way on purpose — one design to understand, one set of failure modes already found.

## Decision

### 1. A supplier is opened by receiving from them

There is no "set up your suppliers" step. The receive screen keeps its one name field; what
is typed is matched, ignoring case and outer spaces, against the suppliers the phone knows,
and a name nobody has typed before opens a supplier. Known suppliers are offered as chips so
the usual case is one tap.

The id is minted on the terminal (ADR-006) and the `supplier` operation is queued ahead of
the receipt that names it, so all of it works offline.

### 2. What a delivery leaves owing is a figure on the receipt

`goods_receipt.owed_santim`: the part of this delivery **not paid for yet**. Zero means paid
on delivery — which is what every receipt before this is taken to be, and the default on the
screen. The receipt also gains `supplier_id`. `supplier_name` stays, and stays required: it
is what was written on the day, and what a 1.8.0 server stores.

A delivery cannot leave more owing than it cost (Σ qty × cost, in the unit counted), and a
debt must name its supplier. Both are refused by the contract and by the database.

The stock is credited exactly as before. Whether a delivery was paid for has nothing to do
with whether it is on the shelf.

### 3. A payment is its own operation

`supplier_payment`: who, how much, how, when, by whom, and an optional reference (a cheque
number). It may exceed what is owed; the balance then goes negative and says "paid ahead",
as a customer's does.

### 4. Cash paid out of a till comes off that till's expected cash

A supplier is very often paid from the drawer. If the cash-up did not know, every such
payment would show as a shortage of exactly that size — with the cashier's name on it — and
a real shortage of that size would hide behind the explanation.

So a payment carries `shiftId` **when, and only when, the cash came out of an open till**,
and expected cash becomes

    opening float + cash from sales + cash repaid by customers − cash paid to suppliers

on the server and on the phone alike. The cash-up screen shows it as its own line with a
minus, and the server's reconciliation reports `paidOutSantim`.

On the phone the source is an explicit choice of three — cash from the open till, cash not
from the till, bank/cheque/Telebirr — with **no default while a till is open**. Money does
not leave a drawer because nobody changed a preselected option. Only cash can be tied to a
till; a transfer "from the till" is refused.

This is the first time the cash-up counts money *out*. It is deliberately this narrow: it
is not a general expenses or petty-cash feature (see Consequences).

### 5. The balance is two figures, kept apart

`supplier.balance_santim` on the server is a running figure maintained in the transaction
of the receipt or payment, recomputable from the rows (`PayablesService.verify`). It reaches
every terminal on a pull. A terminal shows that **plus what it has recorded that is still
queued**; a pull replaces the first and cannot touch the second (ADR-012 §3, as ADR-034 §5).

For that to hold, an acknowledged receipt must stop counting as queued — so the outbox now
marks `goods_receipt` synced on acknowledgement, as it does a sale.

### 6. Locks, in the order ADR-034 found

The supplier row is locked (`FOR NO KEY UPDATE`) **before** the receipt that references it
is inserted, and `SyncService` already retries a deadlocked operation. Two terminals
receiving from one supplier at once queue rather than deadlock; the guardian suite runs it.

### 7. Who may do what

Anyone who may receive goods sees suppliers and what is owed: they took the delivery.
**Paying a supplier is offered to the owner and a branch manager only** — the people who
already manage the catalogue. No new capability, so the FR-2 matrix is unchanged.

That gate is on the phone. The sync endpoint does not check a capability per operation type
— it never has, for any operation — so the server accepts a `supplier_payment` from any
authenticated member of the tenant. What the server guarantees is the record: who, when,
how much, from which till. Closing that gap is a change to sync authorisation as a whole,
not to this feature, and is listed below.

### 8. Contract 1.9.0, additive

New operations `supplier` and `supplier_payment`; `supplierId` and `owedSantim` on a goods
receipt; `suppliers` on a pull — all optional or new. Logged in ADR-012 §4.

- A **1.8.0 terminal** sends none of them and ignores the pulled list. Its receipts apply
  unchanged: a name, no account, nothing owed.
- A receipt with no supplier from a 1.9.0 terminal omits both fields, so it is
  byte-identical to a 1.8.0 one. The owing rules are judged only where something is owed.
- A **1.9.0 terminal against a 1.8.0 server** would have its `supplier` operation refused.
  The server deploys on merge and the app ships after it, so that order does not occur in
  this project's release path; it is the same exposure ADR-034 accepted for `customer`.

The migration adds two tables with RLS, and two columns and two checks to `goods_receipt`;
the previous release runs unchanged on the new schema. Local schema v9, additive.

## Consequences

- **Not built: purchase orders as records.** The reorder list (ADR-036) can be shared as
  text, which is how an order is placed today. A stored order matched against the delivery
  that fulfils it is a further requirement.
- **Not built: invoices, due dates, ageing.** The ledger knows *how much* is owed, not which
  invoice is overdue. A reference can be typed on a payment; it is not parsed.
- **Not built: expenses.** Rent, salaries and petty cash also leave a drawer and are still
  invisible to the cash-up. §4 covers supplier payments and nothing else.
- **Two phones can each open "EPSS" before either syncs**, and the pharmacy then has two.
  Matching by name prevents it on one phone; merging suppliers is not built.
- **A supplier's history on a phone is that phone's entries.** The balance is complete; the
  list is not. A full statement across terminals is a server report that does not exist yet.
- **Receipts before this have no supplier account.** The return list (ADR-036) still groups
  them by name; they are not retro-linked, because a guess at which "Epss" was meant would
  put a figure on the wrong account.
- **The daily summary does not yet say what is owed to suppliers.** The Suppliers screen
  does. Adding it to the summary is small and separate.
- **Sync does not authorise by operation type** (§7). True before this change and for every
  operation; this is the first where the phone-side gate guards money leaving the business.

## Verification

- Server: `apps/api/test/guardian/g4-suppliers.spec.ts` (30) — the balance equals the rows
  after mixed, replayed and concurrent sequences; stock arrives regardless; the owing rules
  at the contract and in the database; cash from a till comes off its expected cash and cash
  from elsewhere does not; tenant isolation; a 1.8.0 receipt and pull unchanged.
- Device: `apps/mobile/test/guardian/g4_suppliers_test.dart` (22) — find-or-create by name,
  the two-figure balance through pull and acknowledgement, the wire payloads with and
  without a supplier, the cash-up, backup and restore.
- Screens: `apps/mobile/test/widget/suppliers_screen_test.dart` (21) — no default source
  with a till open, the till not offered when none is, a cashier not offered payment, the
  receive flow paid, unpaid and part paid.
- Schema: `g7_schema_upgrade_test.dart` holds a v1 install upgraded to v9 to the same
  columns as a fresh one.
- Not shown by any test: a week of real deliveries and payments beside the owner's own
  invoice drawer (`engineering/field-uat.md` §4.5).
