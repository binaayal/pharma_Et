# ADR-015 — Building the event store and the audit log before A-1 clears

**Status:** Accepted; its "not built" list superseded by [ADR-024](ADR-024-regulated-half-built-provisionally.md) · **Date:** 2026-09-23
**Depends on:** ADR-004 (controlled-substance ledger), ADR-008 (risk-tiered testing)
**Constrains:** `06-delivery-plan.md` §2 — Phase 2's entry gate
**Related:** `01-vision-and-scope.md` §2.1.1, `05-qa-and-test-strategy.md` §8

## Context

`06-delivery-plan.md` §2 makes **A-1 verified** the entry gate for Phase 2, where A-1 is the
assumption that EFDA directive 1121/2025 requires ≥5-year retention for controlled-substance
records and that the psychotropic dispensing rules are as FR-4 states them. A-1 is still
unverified, and verifying it needs the directive text from a citable source plus a qualified
Ethiopian regulatory advisor — not something engineering can do for itself, and not something
to approximate.

Read strictly, that gate stops all Phase 2 work. But two other documents say something
different about the same phase, and they are not in error:

- **`01-vision-and-scope.md` §2.1.1** folds a **general action audit log** into V1 — "who did
  what, when (**not only controlled substances**) … Owner trust in staff *is* the product.
  Treated as part of FR-6's infrastructure, generalized." That is a product capability about
  staff accountability. It makes no regulatory claim.
- **`05-qa-and-test-strategy.md` §8** says "**Until A-1 is verified, compliance tests are
  marked provisional** — they assert the mechanism (immutability, retention enforcement) but
  not final regulatory numbers." A test that asserts a mechanism requires the mechanism to
  exist, so the QA strategy already assumes the infrastructure is built before verification.

So the gate is real, and it does not cover everything Phase 2 contains.

## Decision

**Split Phase 2 at the line between mechanism and regulation, and build only the first half.**

### Built now

- The **append-only event store** (`04-system-design.md` §5.6): the `event` table, its
  ordering, RLS, and immutability enforced by the database rather than by convention.
- The **general action audit log** — `audit.*` events for price changes, role and staff
  changes, stock adjustments, branch changes. Product capability, not compliance.
- **Guardian G3** (ledger immutability), asserting the mechanism: no code path updates or
  deletes an event, corrections are compensating events only, and the enforcement holds even
  against a privileged connection.

### Not built, and not partially built

- Any `controlled.*` event type.
- The psychotropic rules (FR-4 §4a) — substance-per-prescription limits, validity windows.
- The controlled-stock projection (BR-3.3).
- Retention enforcement fixed to a number.

**The line is this: we build what we would build regardless of what the directive says, and
we build nothing whose shape is an answer to a question we have not asked.** A retention
period, a validity window, a limit on substances per prescription — each of those *is* the
regulatory answer. Writing one in as a default and "adjusting later" produces a system that
looks compliant, tests green, and encodes a number nobody checked.

### Retention stays a parameter with no default

The event store has no retention logic at all. Not seven years, not a configurable value with
seven as its default — nothing. A default is a claim, and a claim that arrived by convenience
is the one nobody revisits. Retention arrives with the verified directive, in the same change
as the `controlled.*` events it governs.

### FR-6 does not become "done"

The RTM marks the audit-log half complete and FR-6 itself **open**. A regulated requirement
is never done on green tests alone until A-1 is verified and the compliance test reflects the
real directive (`05-qa` §13). Nothing here changes that, and the sign-off log
(`compliance-sign-off.md`) stays empty until somebody has actually read the directive.

## Rationale

- Waiting for A-1 to build the *mechanism* would leave the hardest and most invariant-heavy
  part of the system — an append-only store that must never lose or mutate a record —
  unbuilt and untested until the moment it is most urgent, which is exactly the sequencing
  the risk-first model exists to avoid (`06` §1).
- The audit log delivers on its own. Vision §2.1.1 calls owner trust in staff "the product",
  and a price changed at 11pm by someone who should not have is a finding an owner wants
  whether or not it touches a controlled substance.
- The split is checkable rather than a matter of judgement: the event store has no
  `controlled.*` type, and CI can assert that.

## Consequences

- Phase 2 is entered **partially**, against the letter of §2's gate. That is recorded here
  rather than done quietly, which is the whole point of an ADR.
- When A-1 clears, the remaining work is the regulated subset on top of infrastructure that
  is already proven — a smaller, better-understood change than building both at once under
  compliance pressure.
- Somebody could read a working audit log as "compliance is done". The RTM, this ADR, and an
  empty sign-off log all say otherwise, and the absence of any `controlled.*` event type is
  the fact that settles it.
- If verification returns something that contradicts the *mechanism* — a requirement for
  physically deleting records, say, which would contradict append-only — this ADR and ADR-004
  both need revisiting. That is unlikely, since retention rules are what regulators write,
  but it is the risk being taken and it is better stated than assumed.

## Alternatives rejected

- **Build all of Phase 2 with the assumed values.** The thing the gate exists to prevent. It
  produces a system that is confidently wrong in the one area where being wrong is a legal
  matter, and tests that assert our assumptions back to us.
- **Build nothing until A-1.** Defensible, and it stalls on something engineering cannot
  resolve, while leaving the riskiest component untested until the deadline.
- **Build the ledger but leave dispensing switched off behind a flag.** The flag is the
  problem: the ledger's *shape* — what a dispensing record contains — is itself a regulatory
  answer, so a switched-off ledger still encodes an unverified claim, with the added hazard
  that a flag can be flipped by someone who does not know why it is off.
