# ADR-034 — The customer credit ledger: a debt is a payment row, and the balance is two figures

**Status:** Accepted · **Date:** 2026-10-07
**Implements:** FR-16 (customer credit ledger, ዕዳ) — `07-v2-sellability-plan.md` §3.2
**Reverses, as ADR-029 §4 decided:** the non-goal in `01-vision-and-scope.md` §2.3
**Depends on:** ADR-002 (offline first), ADR-006 (client-minted ids), ADR-009 (N-1),
ADR-012 (extending the envelope; §3, two figures kept apart), ADR-003 (tenant isolation)
**Constrained by:** guardian G4 (money is exact), BR-8.2 (the cash-up counts cash only)

## Context

A large share of a pharmacy's real sales are not paid at the counter. Regulars pay at month
end; a clinic sends its staff; an organisation settles by cheque. V1 could only record money
already received, so every one of those sales was either rung up as cash — and the cash-up
came out short — or kept in a paper book beside the phone.

The paper book is the tool to retire. It is also the owner's strongest reason to keep paying:
a debt that is written down and added up is a debt that gets collected.

Three things make this harder than "add a customer table":

1. it happens **offline** — the first time someone asks to pay later is not a moment to go
   and find a network;
2. it is **money**, so it must add up exactly, be counted once, and not appear where it is
   not (in a cash drawer);
3. one customer buys from **more than one phone**, so no single phone knows the balance.

## Decision

### 1. Credit is a payment method on an ordinary sale

A sale's payments already had to be recorded. `credit` joins `cash` and `other_recorded`:
the part of the total **not paid now**. A sale half paid in cash carries two payment rows,
and for any sale with credit the rows must add up to the total.

So "what was paid now" and "what is owed" are one list, the sale's total is unchanged, and
nothing about lines, stock, FEFO or packs is touched. The sale names its `customerId`,
required whenever any of it is on credit. A debt owed by nobody cannot be collected, so
neither the phone nor the contract will record one.

That add-up rule is enforced **only where credit is present**. The contract has always
accepted a sale with no payment rows; tightening that for every sale would start refusing
operations from terminals already in the field.

### 2. A repayment is its own operation, not a negative sale

`credit_payment`: customer, amount (more than zero), cash or other tender, when, who took
it, and the till it was taken in. Nothing leaves a shelf, so it is not a sale.

It may exceed what is owed. Someone settling 480 with a 500 note is ordinary; the honest
record is that they are 20 ahead, and the balance goes below zero and says so.

### 3. A customer is created at the counter and mirrored back

`customer` is the first entity that travels both ways: created on a terminal with a
client-minted id, pushed, and then returned by the pull so every other phone — and this one
after a reinstall — knows them. The outbox orders it ahead of the sale that names it.

This does not reopen ADR-002's "no conflict code". A terminal only ever **creates** a
customer; it never edits one, so there is nothing to conflict. Renaming a customer or fixing
a phone number is a later, online change, like editing a product.

A customer record is **who owes money**: a name, optionally a phone number and a note. No
date of birth, no address, nothing about treatment — `01` §2.3's line between running a shop
and holding patient records stands. A sale is linked to a customer **only when something is
owed**; a cash sale to a known customer is not recorded against them.

### 4. The server keeps a running balance, and can prove it

`customer.balance_santim` moves in the same transaction as the credit sale or repayment that
changes it, under a row lock, and bumps `change_seq` so the new figure reaches the
terminals. It is not the truth. The truth is the rows — credit payments on that customer's
sales, less their repayments — and `CreditService.verify` recomputes it. A guardian test
holds the two equal after long mixed sequences, replays, and two terminals syncing the same
customer at once.

Customers and their balances are **tenant-wide, not per branch**: an organisation that buys
at one branch and pays at another owes one pharmacy one sum.

### 5. On the phone, the balance is two figures added, never merged

A phone shows **the server's figure, plus what it has itself queued**: credit sold and
repayments taken that the server has not acknowledged.

- A pull replaces the server's figure and nothing else, so it can never erase an unsynced
  debt.
- An acknowledgement marks the entry synced, so it stops being added at the moment the next
  pull brings a figure that already includes it. It is never counted twice.

This is ADR-012 §3 — the cash-up's "what the terminal showed" and "what the server
computed" — applied to money owed. Where part of a balance is still queued the screen says
so, because another phone will not see it yet.

The history listed under a customer is **this phone's entries only**. The balance is
complete; the list is not, and says it is not.

### 6. Cash against a debt is in the drawer

A cash repayment taken while a till is open goes into the same drawer as the cash from
sales. Both the terminal's expected cash and the server's recomputation therefore add
`credit_payment` rows of method `cash` for that shift. Left out, every repayment would show
as unexplained extra cash — or cover a shortfall of the same size.

The credit part of a sale is the opposite: it never reached the drawer and is never
expected. A repayment taken with no till open is still recorded, with a warning that no
cash-up will expect it.

### 7. Credit is not money received

The sales summary reports `creditSantim` apart from cash and from other tender. Lumped into
"other", a debt would read as money that came in.

### 8. Nobody is refused, and nobody new is gated

There is no credit limit and no block on a customer who already owes. Whether to extend
credit is a judgment made by the person at the counter; the system records it and who made
it. A limit that blocks is a sale lost at the till; if owners ask for one it should warn,
not refuse — the same shape as an oversell (BR-3.2).

Anyone who may sell may sell on credit and take a repayment. No new capability, so the FR-2
permission matrix is unchanged. The owner's control is the record: every credit sale and
repayment carries who did it.

### 9. Contract 1.7.0, additive

New operations `customer` and `credit_payment`; `credit` as a payment method; `customerId`
on a sale; `customers` on a pull — all optional or new. A 1.6.0 terminal sends none of them
and ignores the pulled list; an ordinary sale from a 1.7.0 terminal is byte-identical to a
1.6.0 one. The database's payment-method check is widened, never narrowed, so the previous
release runs unchanged on the new schema. Logged in ADR-012 §4. Local schema v7.

### 10. A deadlocked operation is retried, not rejected

Found by this change's own concurrency test: two terminals syncing credit sales for one
customer could deadlock, and the loser came back `rejected` — a real sale parked for a
person to puzzle over because of when it arrived. Two fixes: the customer is locked before
the sale row that references it is written, with a lock mode that does not fight the
foreign key; and `SyncService` now retries an operation the database aborted as a deadlock
victim. Each retry is a whole fresh transaction, and the `applied_op` check inside it means
a retry cannot apply twice. That second fix protects every operation type, not only credit.

## Consequences

- **A credit sale naming a customer the server has never heard of is rejected** and parked
  on the terminal. In order it cannot happen; when it does, something was lost and a person
  should look.
- **A phone's balance for a customer can be behind** by whatever other phones have not yet
  synced. It is never wrong about what it knows, and never silently ahead.
- **A receipt for a credit sale states the debt for that sale**, not the customer's balance,
  which the phone may only partly know.
- There is no editing or merging of customers yet, no statement across phones, no ageing
  ("owed for 60 days") and no reminders. The first two are the obvious next steps; refill
  reminders stay out of V2 (`07` §3.3).
- Backups (ADR-033) carry unsynced customers and repayments.

## Alternatives rejected

- **Compute the balance on the phone from its own sales.** Wrong the moment a second phone
  or a reinstall exists, and wrong in the direction that loses money.
- **Compute the balance on the server on every pull, with no running figure.** Correct, and
  sums a customer's whole history for every terminal every two minutes.
- **A separate "credit sale" entity.** Duplicates lines, stock movement and packs for a
  difference that is one field.
- **A customer on every sale** (purchase history). Not needed to collect a debt, and it is
  the step from a debt book to a record of who takes which medicine.
- **A capability for selling on credit.** A change to the permission matrix to stop the one
  person at the counter from doing what the counter needs.
- **Reject a credit sale over a limit.** Refuses a sale the owner would have made.
