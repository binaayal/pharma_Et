# ADR-014 — The Ethiopian calendar is implemented twice, and verified once

**Status:** Accepted · **Date:** 2026-09-23
**Depends on:** ADR-010 (codegen), ADR-013 (matrix as contract)
**Related:** FR-10, BR-10.2, AC-10.2

## Context

FR-10 requires all user-facing dates in the Ethiopian calendar, on the Flutter till and on
the React console alike. The conversion is genuinely non-trivial: thirteen months, a leap
day in Pagumē every fourth year, a new year on 11 September that slips to 12 September when
the *following* Gregorian year is a leap year, and an offset of seven or eight years
depending on which side of the new year a date falls.

ADR-010 established that anything both clients depend on is authored once in
`packages/contracts` and generated. That works for types (ADR-010), for enumerated data
(ADR-013) — and not for this. **Generating an algorithm across languages is a transpiler**,
not a code generator, and writing one to avoid duplicating forty lines of integer arithmetic
would be a much larger and much less reliable thing than the duplication it prevents.

The alternative — one implementation called across a boundary — is worse in both directions.
The till cannot call the server: the conversion has to work with no network, which is the
state this product is designed for. And the console calling the till is not a sentence that
means anything.

So the algorithm must exist twice. The question is what stops the two copies diverging.

## Decision

**The algorithm is written twice; the evidence is shared.**

`packages/contracts/src/ethiopian-calendar.ts` holds the TypeScript implementation *and*
`ETHIOPIAN_TEST_VECTORS` — a table of Gregorian/Ethiopian pairs, each with a note saying why
that case is in the table. `pnpm gen:contracts` emits the vectors as Dart
(`apps/mobile/lib/contracts/calendar_vectors.dart`).

Both implementations are tested against that one table, so a divergence fails a test in CI
rather than shipping an expiry alert that is a year out.

**The cases are chosen for where conversion actually breaks**, not for coverage: the new-year
boundary in both directions, the day before it, Pagumē 6 in a leap year, a Gregorian leap
day, and a year where the new year slips to 12 September. Both suites additionally round-trip
**every day of a decade**, which is where an off-by-one that only fires once in four years
gets caught.

**Storage is untouched by any of this.** AC-10.2 is enforced separately and structurally: a
guardian suite asserts every timestamp column is `timestamptz`, that the API serves
`Z`-suffixed ISO-8601, and that **no calendar or locale column exists in the domain schema at
all**. Conversion is presentation-only (BR-10.2), and the schema is where that stops being a
convention.

## Rationale

- Two implementations verified against one table is weaker than one implementation, and
  stronger than two implementations verified separately — which is the realistic alternative
  and the one that fails silently.
- The vectors are more valuable than the code they check. An implementation can be rewritten;
  the table is the accumulated knowledge of which dates are dangerous, and each row carries
  the reason it exists so nobody deletes it as redundant.
- Round-tripping a decade costs milliseconds and catches the whole class of error that
  hand-chosen cases miss — including the leap-placement bug this ADR was written after
  finding.

## Consequences

- A change to the conversion means editing two files and cannot be merged unless both still
  satisfy the vectors. That is the intended friction.
- A **shared** bug — one that is wrong in the vectors themselves — passes both suites. The
  mitigation is that the vectors are anchored to externally verifiable facts (Ethiopian New
  Year 2017 EC = 11 September 2024) rather than to the implementation's own output, and that
  the round-trip test is independent of them.
- If a third client ever needs the calendar, it implements the algorithm again and consumes
  the same vectors. At that point a shared native module starts to look reasonable; two does
  not justify it.

## Alternatives rejected

- **Call the server to convert.** Breaks offline, which is the product.
- **Write a TypeScript-to-Dart transpiler for this module.** Far more machinery and far more
  risk than the forty lines it would save.
- **A third-party Ethiopian-calendar package on each side.** Two different packages with two
  different bugs, neither of which we would find, and a dependency in the path of every date
  the product renders. Rejected on the same grounds as ADR-012's preference for owning the
  small, load-bearing pieces.
- **Store dates in the Ethiopian calendar.** Catastrophic and irreversible: nothing in a row
  records which calendar it was written in, so a misread is off by eight years and takes the
  retention clock (NFR-5.1) with it. AC-10.2 exists to forbid exactly this, and the guardian
  suite now enforces it against the schema rather than against anyone's memory.
