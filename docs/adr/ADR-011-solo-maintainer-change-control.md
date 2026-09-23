# ADR-011 — Change control for a single maintainer

**Status:** Accepted · **Date:** 2026-09-23
**Supersedes (in part):** the review-count rules in `06-delivery-plan.md` §4 and §7
**Related:** ADR-008 (guardian suites are the CI gate), ADR-010 (repo layout)

## Context

`06-delivery-plan.md` was written for a multi-engineer team. Its change control rests on
counting humans: **≥ 1 review** for ordinary work, **2 reviews** for a controlled artifact,
one of them from a **compliance owner** who is somebody other than the author.

The project is now built by a single maintainer. That makes those rules unsatisfiable, and
GitHub makes it literal: **you cannot approve your own pull request.** A required-approval
rule would block every merge, so the only way to ship would be to turn the protection off —
and a rule that has to be disabled to work teaches everyone that the rules are decorative.
The rules that *can* be enforced lose their authority along with it.

The intent behind §7 is not "two people looked at it". It is: **nothing load-bearing changes
without deliberate, documented scrutiny, and the evidence survives.** That intent is
achievable alone. The head-count is not.

## Decision

Replace the head-count gates with **mechanical gates plus recorded self-review**, keeping
every other part of §7 exactly as written.

**1. Branch protection stays on, with required approvals set to zero.**
No direct pushes to `main`; every change goes through a PR; every CI check is required.
Zero approvals is not a weakening — it is the only setting under which a solo maintainer can
merge at all, and the checks are what actually gate the merge.

**2. A controlled-artifact change is gated by CI, not by a reviewer.**
When a PR's diff touches the sync envelope, the event/ledger schema, RLS policies, or the
compliance rules, the `controlled-artifact` job **fails the build** unless the same PR also
contains:

- a new or modified file under `docs/adr/`;
- a modified guardian suite;
- a PR body with the controlled-artifact checklist completed.

This is the substitute for the second reviewer, and it is a better one in the only respect
that matters here: it cannot be forgotten, waved through at the end of a long day, or
granted by someone who did not read the diff.

**3. The compliance owner role survives; its sign-off moves out of GitHub.**
It is the same person, so an approval click would prove nothing. A-1 verification and every
ledger or psychotropic sign-off is recorded as a **dated, signed entry in the docs** — the
artifact an auditor would ask for. A GitHub approval was never that artifact.

**4. Self-review is a required step, and it happens on the PR.**
Open the Files-changed view and read the whole diff there before merging, against the
reviewer questions in `engineering/workflow.md` §7. Reading a diff in a different
presentation, after the fact, catches things that reading it as you wrote it does not.

**5. Rebase merge for curated multi-commit PRs; squash for noisy ones.**
§4 mandates squash merge and linear history. Squash exists to collapse the noise of review
fixups — "address comments", "fix typo", "rebase" — which a solo PR does not accumulate. The
commits here are written to be read one at a time, so squashing them destroys the record for
no gain.

**Rebase merge** gives both: every curated commit lands as its own commit, and history stays
linear. A merge commit would preserve the commits too, but it is not linear and GitHub's
required-linear-history rule rejects it outright — so "merge commits" would be a rule that
the branch protection immediately contradicts, which is exactly the failure this ADR exists
to avoid.

Squash still applies when a PR genuinely is a single idea arrived at messily.

## Consequences

- Change control becomes **stricter in practice**, not looser: the controlled-artifact
  requirements were previously enforced by a reviewer remembering them, and are now enforced
  by a job that fails.
- The `CODEOWNERS` file no longer routes reviews to a second person. It stays as a map of
  which paths are load-bearing, which is the useful half.
- A missing ADR blocks a merge. That is intended, and it is the most likely way this ADR
  will feel annoying — on a day when the change seems too small to deserve one. The answer
  is to write four lines in an ADR, not to route around the gate.
- The compliance evidence trail is now a documentation practice rather than a side effect of
  the review tool. It has to be done on purpose. A dated sign-off log is the mechanism.

## When this expires

**The moment a second engineer joins.** This ADR is superseded, `06-delivery-plan.md` §4 and
§7 return unchanged, required approvals goes to 1 (2 for controlled artifacts), and the
CI gate stays — a mechanical check and a human reviewer catch different things, and there is
no reason to give up the first once the second exists.

## Alternatives rejected

- **Keep the two-review rule and ignore it.** The most likely outcome by default, and the
  worst: the written process and the real process diverge, and the documentation stops being
  something anyone can trust — which, for a suite that says "documentation is executable
  intent", is a deeper loss than the review itself.
- **Drop change control until the team grows.** The controlled artifacts are exactly the
  things that break quietly and expensively. Fewer people means less chance of catching such
  a break by accident, so the mechanical gates matter *more* alone, not less.
- **A bot that auto-approves.** Theatre. It produces an approval record that attests to
  nothing, which is worse than an honest zero.
- **Require a cool-off period before merging a controlled change.** Appealing, but
  unenforceable without turning the calendar into a gate, and easy to wait out without
  re-reading anything.
