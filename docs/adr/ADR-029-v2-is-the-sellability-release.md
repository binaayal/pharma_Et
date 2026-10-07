# ADR-029 — V2 is the sellability release; multi-writer offline stays deferred

**Status:** Accepted · **Date:** 2026-10-07
**Amends:** `01-vision-and-scope.md` §2.2 and §2.3, `06-delivery-plan.md` §2 (what "V2" names)
**Does not amend:** ADR-002 — its decision and its reasons stand
**Related:** `../07-v2-sellability-plan.md`, `../v2-sellability-backlog.md`

## Context

`01` §2.2 and ADR-002 used "V2" to mean one thing: multi-writer offline and the conflict
engine. That was written before anyone had tried to sell the product.

A review of the shipped v1.0.0 app against what a pharmacy owner does all day found that the
distance to a sale is not concurrency. It is that the app cannot yet replace anything: no pack
sizes, no loaded catalogue, no scanning, no printed receipt, no credit book. An owner runs it
beside the old tools, and a second system is not worth a monthly fee.

Meanwhile the documents forbid building most of the fixes. `01` §2.3 lists the customer credit
ledger as a non-goal. `01` §2.2 defers supplier-side purchasing (FR-7a/b) and advanced
reporting (FR-8a). The contributing rules reject a PR that builds something marked deferred.
Those rules are right, so the documents have to change before the code does.

## Decision

1. **"V2" now names the sellability release** defined in `07-v2-sellability-plan.md`: the
   work that lets an owner retire an existing tool. Its requirements are FR-11 to FR-20, plus
   FR-7a and FR-8a.
2. **Multi-writer offline is still deferred, to "V3".** Nothing in ADR-002 is reopened: it is
   still the highest-risk piece in the system, most independent pharmacies still run one
   terminal, and V2 contains **no conflict-resolution code**. Wherever an earlier document
   says "deferred to V2" about multi-writer or NFR-2, read "V3".
3. **Un-deferred**, each with the reason it was deferred now answered:
   - **FR-7a usage-based ordering**, as reorder suggestions. It waited for sales history;
     there is now a sales history to read.
   - **FR-8a advanced reporting**, as profit, best-seller and dead-stock reports. It was
     called polish; it is what an owner looks at when deciding whether to renew.
   - **A supplier entity** (FR-18), which the goods-receipt contract marked deferred.
4. **A non-goal reversed: the customer credit ledger** (FR-16). `01` §2.3 said it "may be
   reconsidered — credit sales are common in Ethiopian retail". It is reconsidered. The rest
   of that non-goal stands: no loyalty scheme and no customer-facing app. Refill reminders
   remain out of V2.
5. **Still deferred or out, unchanged:** FR-5 inter-branch transfer (online-only, after V2),
   FR-7b multi-wholesaler ordering, the desktop app, payment-gateway integration, e-prescription.
6. **Every V1 constraint binds V2.** Offline-first writes, integer santim, no hard deletes,
   tenant scoping, additive sync changes with an N-1 window, the controlled-artifact gate,
   and the A-1 switch. A V2 feature that cannot be built inside them is redesigned, not
   exempted.

## Rationale

- The order of risk has changed. In V1 the risk was technical — would the sync spine hold —
  and the plan was sequenced against it. That risk is retired by the guardian suites. The
  remaining risk is commercial, and the same rule applies: sequence by risk.
- Reusing "V2" rather than inventing "V1.5" keeps the word meaning what an owner would mean
  by it: the next version they can buy.
- Reversing a non-goal in an ADR, rather than quietly adding a customer table, keeps the
  rule that scope changes are written down with their reason.

## Consequences

- `01` §2.2 and §2.3, `06` §2 and the documentation index are updated in the same change.
- Each V2 requirement is specified in `02-srs.md` when it is ready to build, and gets an RTM
  row like any other.
- Several V2 items change the sync envelope. Each is a contract MINOR with a log entry in
  ADR-012 §4, and its own ADR where it decides something beyond "a field was added".

## Alternatives rejected

- **Build multi-writer next, as originally labelled.** It solves a problem no prospective
  customer has raised, at the highest engineering risk in the system.
- **Ship the sellability items as V1.x patches without changing the scope documents.** That
  is exactly the smuggling `01` §6 principle 4 exists to prevent.
