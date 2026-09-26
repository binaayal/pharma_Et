# ADR-024 — The regulated half, built ahead of A-1 and switched off until it clears

**Status:** Accepted · **Date:** 2026-09-26
**Supersedes in part:** ADR-015 (its "not built, and not partially built" list)
**Implements:** FR-4 §4a–4b and BR-4.2/4.3, FR-6 (AC-6.1, AC-6.2, BR-6.3), BR-3.3,
docs/04 §6; contract 1.4.0
**Decided by:** the owner, 2026-09-26 — *"Build it provisionally … behind a switch that stays
OFF until you verify A-1."*

## Context

ADR-015 split Phase 2 at the line between mechanism and regulation and left the regulated
half unbuilt, on the reasoning that a validity window or a substance limit written in before
verification *is* a regulatory answer nobody checked. That reasoning still holds for what goes
**live**. What changed is the owner's call on what gets **built**: a finished app, ready to be
switched on the day A-1 clears, rather than a known, bounded build started only then.

The two positions are reconcilable if — and only if — nothing regulated can reach a pharmacy
before verification, and the unverified numbers cannot hide.

## Decision

1. **Built:** the controlled-substance ledger on the reserved `controlled_stock` stream of the
   existing append-only event store — `controlled.received`, `controlled.dispensed`,
   `controlled.adjusted` — with a `controlled_stock_view` projection maintained in the same
   transaction and rebuildable from the events; psychotropic rules enforced on the till
   (offline) and again on the server; ledger read, stock and CSV export endpoints; prototype
   screens 11 (dispense) and 17 (ledger).

2. **One switch, off.** `CONTROLLED_DISPENSING=on` is the only way any of it runs. Off, every
   controlled operation is **rejected and writes nothing** — no event, no sale, no projection
   row — and a guardian asserts exactly that. `/health` reports the state; terminals hide
   dispensing when it is off, and remember the last answer so an outage does not flip it.
   **The switch may be turned on in a deployed environment only after A-1 is verified and
   recorded in `docs/compliance-sign-off.md`.** Local development and the guardian suite turn
   it on to exercise the rules; nothing else does.

3. **The numbers live in one file and say what they are.**
   `packages/contracts/src/compliance.ts` holds one psychotropic per prescription, 15 days
   psychotropic validity, 30 standard, the dedicated prescription paper — each from SRS FR-4
   §4a, `[ASSUMPTION]` A-1 — under `status: 'provisional'`. Every dispense event records that
   status, and the audit export prints it. The till's Dart copy is compared to it by a test,
   so verification changes one file (and its mirror) or CI fails.

4. **A controlled product can never leave through the standard sale path.** The server now
   refuses a `sale` line for a controlled product whatever the switch says; the till always
   did. Otherwise a terminal could route around the ledger entirely.

5. **A dispense is a sale too.** The customer pays and the cash belongs to the till's cash-up,
   so a `controlled_dispense` operation carries its line and payments and the server writes
   the sale and the ledger event in one transaction.

6. **Retention stays as ADR-015 left it.** The event store never deletes at all, so no
   duration is configured; NFR-5's number arrives with A-1.

## Consequences

- FR-4's psychotropic rules and FR-6's ledger move from "gated, not built" to "built,
  provisional, switched off". They are **not done**: `docs/05-qa` §13 still requires the
  compliance tests to reflect the verified directive, and the sign-off log stays empty.
- When A-1 is verified: correct `compliance.ts` and its Dart mirror if the directive differs,
  set `status` to `'verified'`, record the sign-off, and only then turn the switch on.
- Guardians: `apps/api/test/guardian/g5-controlled-ledger.spec.ts` (switch off → nothing
  written; AC-4.2; AC-4.3; AC-6.1; AC-6.2; BR-3.3 projection rebuild; isolation; replay),
  `apps/mobile/test/guardian/g5_controlled_dispense_test.dart` (the rules offline),
  `packages/contracts/test/compliance.test.ts` (TS/Dart parity). G3's "nothing controlled" is
  now "nothing controlled while the switch is off".
