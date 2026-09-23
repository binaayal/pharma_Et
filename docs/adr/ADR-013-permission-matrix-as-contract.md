# ADR-013 — The FR-2 permission matrix is a contract artifact

**Status:** Accepted · **Date:** 2026-09-23
**Depends on:** ADR-003 (isolation), ADR-010 (codegen), ADR-012 (envelope extension)
**Amends:** `06-delivery-plan.md` §7 — adds the permission matrix to the controlled artifacts

## Context

FR-2 specifies a permission matrix: twelve capabilities across three tenant roles, each cell
either denied or granted with a reach (tenant-wide, branch-scoped, or the actor's own
records). AC-2.1 requires that a denial holds **"at both app and API layers"**.

Two layers enforcing one table is two copies of that table, unless something prevents it.
And the copies do not drift randomly — they drift in a particular direction. The client is
edited to show a new button; the server check is added later, or not at all; or the reverse,
and the app offers an action the server refuses. The second case is the common one, and the
user experiences it as the product being broken, with a support conversation that starts
three steps away from the real answer.

The same argument that put the sync envelope in one place (ADR-010, `05-qa` §6) applies
here, with one difference: envelope drift loses transactions, while permission drift either
annoys users or silently over-grants. The second is worse than it sounds in a system whose
entire value proposition to an owner is *knowing what their staff did*.

## Decision

**1. The matrix lives in `packages/contracts/src/permissions.ts`** and is generated into
Dart (`apps/mobile/lib/contracts/permissions.dart`) by `pnpm gen:contracts`, exactly as the
sync envelope is. The API imports it; the app reads the generated table. One source, and CI
fails if the generated output is stale.

**2. A grant is not a boolean.** Each cell is `tenant`, `branch`, `own`, or `denied`.
Collapsing "allowed" into one value is how a branch manager ends up acting across a tenant
they only partly run — both cells read "yes", and the difference between them is exactly
what the SRS's **T** and **B** columns are for.

**3. The guard resolves `denied` and abstains from the rest.** It knows the role; only the
data knows which branch a record belongs to, or whose shift it was. Handlers receive the
grant and check ownership themselves. A guard that guessed at `branch` or `own` would be
worse than one that abstains, because it would *look* like enforcement while being wrong in
cases nobody tests.

**4. The matrix is a controlled artifact** (`06-delivery-plan.md` §7). Changing a cell now
requires an ADR, a guardian-suite update, and a recorded self-review, enforced by the
`controlled-artifact` job. It earns that status on the same grounds as the others: it breaks
quietly, the breakage is expensive, and no ordinary test notices a cell that became more
permissive than it should be.

**5. The client's copy is a correctness boundary, not a security one.** Anyone can call the
API directly, and the server enforces the table independently. The app's job is to not offer
what will be refused — and specifically to **not render** a denied control rather than
disable it, because a disabled button teaches people to hunt for the way to enable it.

## Rationale

- Generating the table is the only mechanism that makes "enforced at both layers" checkable
  rather than aspirational. Everything else is a convention that survives exactly as long as
  the person who wrote it remembers it.
- Keeping the matrix as *data* is what lets `05-qa` §10's "every role × capability cell" be
  a real test rather than a sampling of the cells somebody thought of. The suite iterates the
  table, so a new capability is untested only if it is also undeclared.
- Declaring the Platform-Admin capabilities in the matrix and denying them to every tenant
  role states BR-2.2 positively: an owner is the most privileged person inside a tenant and
  still cannot verify their own payment. Leaving them out would have made that silence.

## Consequences

- Changing a permission is now a controlled-artifact PR. That is heavier than editing a
  guard, and deliberately so — this is the table that decides who can change a price.
- The contract package now carries something that is not part of the wire format. The name
  "contracts" stretches slightly; the alternative was a fourth package for one file, or a
  second copy of the matrix, and both are worse.
- A capability added to the table without a corresponding endpoint is inert but harmless. A
  capability *used* without being in the table fails closed, because `grantFor` returns
  `denied` for anything it does not recognise, on both sides.
- Client and server can still disagree across a release boundary: an app built against an
  older matrix may hide a control the server would now allow. That is the benign direction —
  under-offering, not over-offering — and it resolves on the next app update.

## Alternatives rejected

- **Keep the matrix in the API and let the client hard-code its own rules.** The status quo
  before this ADR, and the thing AC-2.1 is written to prevent.
- **Derive the client's view from an endpoint at login.** Tempting, and it removes the drift.
  But it makes the app's behaviour depend on a network call at exactly the moment this
  product is designed to work without one, and a stale cached response is then a permission
  table with no version anybody can see.
- **A boolean per cell, with scoping handled ad hoc at each call site.** What the code did
  before. It is how the sales-summary endpoint came to be mapped to the wrong capability —
  caught by the matrix tests, which is the argument for having them.
- **Enforce only on the server.** Correct for security, wrong for the product: the app then
  routinely offers actions that fail, and users stop trusting the ones that work.
