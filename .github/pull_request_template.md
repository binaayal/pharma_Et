## What and why

<!-- One paragraph. What changes, and which requirement it serves. -->

**Requirement:** <!-- FR-n / NFR-n, or "none — tooling/docs" -->
**RTM row updated:** <!-- yes / n/a -->

## Controlled artifacts

Does this touch any of these? (docs/06-delivery-plan.md §7)

- [ ] The **sync envelope** (`packages/contracts/`, docs/04 §7)
- [ ] The **event / ledger schema** (docs/04 §5.6)
- [ ] **RLS policies** (`apps/api/src/migrations/`)
- [ ] **Compliance rules** (FR-4 psychotropic, FR-6 ledger)
- [ ] None of the above

If any box above is ticked, this PR needs **an ADR, both-side contract tests including N-1,
a guardian-suite update, a completed self-review and an RTM entry** — before merge, not
after. The `controlled-artifact` job checks the first three and the last mechanically and
will fail the build without them (ADR-011 replaces the two-reviewer rule; there is one
maintainer, and GitHub does not let you approve your own PR).

## Guardian suites

Which invariants does this touch or rely on? (docs/05-qa §4)

- [ ] G1 tenant isolation
- [ ] G2 sync integrity
- [ ] G3 ledger immutability
- [ ] G4 money integrity
- [ ] G5 oversell detected
- [ ] G6 psychotropic rules
- [ ] G7 offline resilience

## How it was verified

<!-- Not "tests pass". What did you actually run, and where?
     For offline behaviour, say on what device. -->

## Checklist

- [ ] No query can cross a tenant boundary; anything new runs on the scoped `EntityManager`
- [ ] No floating point anywhere near money
- [ ] No hard `DELETE` on domain data, no `UPDATE` on `event`
- [ ] Generated contract code was regenerated, not hand-edited (`pnpm gen:contracts`)
- [ ] Nothing here implements something the docs mark deferred to V1.x/V2
- [ ] `docs/` updated if a contract or decision changed
- [ ] I read the whole diff in the Files-changed view before merging

<!-- The last line is required on any PR that touches a controlled artifact, and the CI job
     greps for it. Reading your own diff in a different presentation, after the fact, catches
     what reading it as you wrote it does not. -->
