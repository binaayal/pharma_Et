# ADR-020 — Dispensing expired stock is warned, authorised and recorded — never blocked

**Status:** Accepted · 2026-09-24
**Implements:** E-4.2 (*"Expired-only stock available: system warns and requires explicit
override by an authorized role before dispensing"*)
**Constrained by:** NFR-1.2 (*"the app never hard-blocks a core sale"*), BR-4.1 (a committed
sale is never silently dropped), BR-3.2 (oversell is recorded, not prevented)
**Relates to:** ADR-002 (offline-first), ADR-015 (the compliance line)

---

## Context

E-4.2 is the last open functional requirement in V1, and until now the code did the one thing
nobody chose: FEFO excluded expired batches from selection, so when the only stock was
expired the terminal offered **no batch at all**. The sale completed with no batch attached,
nothing was decremented, and **nobody was warned**.

That is worse than it sounds. The counter assistant physically takes a box off the shelf. If
the only box there is expired, they take the expired one — and the software, which knew, said
nothing. The sale then records against no batch, so the expired stock stays on the books at
full quantity while the medicine is in a customer's bag.

## The tension

E-4.2 says dispensing expired stock **requires** an authorised override. NFR-1.2 says the app
**never hard-blocks a core sale**. Read carelessly, those contradict.

They do not, because they are about different things. NFR-1.2 protects the pharmacy's ability
to trade — a shop that cannot take money is a shop that uninstalls this app. E-4.2 protects a
patient from being handed expired medicine. The resolution is to notice that **the software
cannot physically prevent anything**: the box is on the shelf and a human hand reaches for it.
What software can do is warn, gate, and record.

## The decision

**Warn at the counter, gate the attribution on a capability, record every expired dispense,
and never refuse the sale.**

1. **The warning is unmissable and comes before the line is added.** Previously the expired
   batch was hidden, which reads to the user as "there is no stock" rather than "the only
   stock here is expired". Hiding it removed the information the person most needed.

2. **Attributing a sale to an expired batch requires `expiry.override`** — a new capability in
   the FR-2 matrix: `tenant` for an owner, `branch` for a branch manager, **denied to a
   cashier**. That is the "authorized role" E-4.2 asks for, expressed in the one place this
   system expresses authority, rather than as a special case somewhere in the POS.

3. **The sale is never refused, and never rejected on the server.** A cashier without the
   capability still completes the sale; what they cannot do is record it against the expired
   batch. The line goes through unattributed, exactly as it did before — but now with the
   warning shown.

   This is the honest boundary. Refusing the sale would not stop the box leaving the shelf; it
   would only stop the pharmacy trading, and would teach the counter to work around the app.

4. **Every expired dispense is audited, overridden or not.** The server knows each batch's
   expiry date, so it does not need to be told: on applying a sale whose line names a batch
   already expired at `soldAt`, it writes `audit.expired_dispense` recording the batch, the
   product, the actor, and whoever authorised it — or that nobody did.

   The unauthorised case is the one worth recording most. A sale that went out unattributed
   leaves expired stock on the books at full quantity, and that discrepancy surfaces in the
   expiry report (BR-3.4) and at the next physical count (BR-3.2). The audit event is what
   connects the discrepancy to the moment it was created.

## Why not reject the operation server-side

It would be the obvious enforcement point and it is the wrong one. A rejected operation never
reaches the server, so a legitimate, properly authorised sale that hit a validation edge would
sit in the outbox indefinitely — and BR-4.1 says a committed sale is never silently dropped.
Rejection also arrives minutes or days after the event, at a terminal, to nobody in
particular. The control has to be at the counter, at the moment, or it is not a control.

## Consequences

- `expiry.override` is additive to the permission matrix; every existing role's other cells
  are untouched, and the matrix suite tests the new cell at both layers like any other.
- The sale line gains an optional `expiryOverrideBy`. Additive to the sync envelope, so
  **contract 1.3.0**, N-1 window unchanged: a 1.2.0 terminal simply never sets it, and its
  sales apply exactly as before.
- An expired dispense is visible in three independent places — the warning at the time, the
  audit event afterwards, and the stock discrepancy later. None of them depends on the others.
- Past the offline authority ceiling (BR-2.3) the override is unavailable, because it is a
  privileged action and the terminal is running on authority it has not refreshed. Selling is
  unaffected, as always.
