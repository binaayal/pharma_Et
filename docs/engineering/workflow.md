# Development Workflow

**Depends on:** `../06-delivery-plan.md` §3, §4, §7, §10 — this document is the operational
form of those sections. Where they disagree, `06` wins.

---

## 1. The loop

```
issue (has FR/NFR id + acceptance criteria + RTM row)
  └─> branch off main
        └─> commit, small and often
              └─> PR  ──> CI gates ──> review(s) ──> squash merge to main
                                                          └─> auto-deploy to staging
```

Nothing reaches `main` except through a PR. `main` is always releasable.

## 2. Before you start: Definition of Ready

An item is not ready to pick up without:

- [ ] A requirement id (`FR-n` / `NFR-n`) — if there isn't one, the requirement is missing, and that is the first thing to fix.
- [ ] Acceptance criteria, taken from `../02-srs.md` (the `AC-n.n` lines), not invented.
- [ ] An RTM row (`../02-srs.md` §6).
- [ ] Known dependencies — **including whether it touches a controlled artifact** (§6).

## 3. Branch protection — what is actually enforced

**Server-side branch protection is not available on this repository.** GitHub restricts both
classic protection and rulesets to Pro, Team or public repositories; on a free private repo
the API answers:

```
403  Upgrade to GitHub Pro or make this repository public to enable this feature.
```

So be clear about what does and does not hold today:

| | Enforced by | Bypassable? |
|---|---|---|
| CI gates on a PR | GitHub Actions | No — the checks run and their result is visible |
| Controlled-artifact requirements | the `controlled-artifact` job (ADR-011) | No, for any change that goes through a PR |
| "no direct pushes to `main`" | **a local `pre-push` hook only** | **Yes** — `--no-verify`, or any clone that has not run `scripts/install-hooks.sh` |

Install the hook once per clone:

```bash
./scripts/install-hooks.sh
```

It refuses a push to `main` and points at the PR flow. It is a **tripwire, not a gate** — it
catches the 11pm "just this once", which is the failure it is meant for. It cannot catch
someone who means it, and it does nothing on a fresh clone.

**To get real enforcement**, one of:

- **make the repository public** — protection and rulesets become free. The code and the
  docs go with it, which is a product decision, not a workflow one; and note that
  `docs/compliance-sign-off.md` and the ADRs would become public reading;
- **GitHub Pro** — a few dollars a month, repository stays private.

Either way the settings to apply are: require a PR, required approvals **0** (ADR-011 — you
cannot approve your own), required checks `CI gate`, `controlled-artifact requirements`,
`dependency audit`, `no secrets in the diff`, linear history, no force pushes, no deletions.
`scripts/protect-main.sh` applies exactly that once the plan permits it.

Until then the discipline is yours to keep, and the hook is the reminder.

## 4. Branches

Short-lived, off `main`, one concern each. Delete after merge.

```
feat/fr-4-psychotropic-validity      new capability, names its requirement
fix/sync-duplicate-ack               bug fix
chore/phase-0-foundations            tooling, CI, scaffolding
docs/adr-011-projection-rebuild      documentation / ADRs
spike/offline-72h-harness            time-boxed investigation, never merged as-is
```

If a branch lives longer than a few days, it is too big — split it. Long-lived branches
accumulate drift, and drift on this codebase means a sync contract that diverges silently.

## 5. Commits

[Conventional Commits](https://www.conventionalcommits.org/), with the requirement id in the
body where one applies:

```
feat(pos): enforce one psychotropic substance per prescription

Blocks a second psychotropic line at sale assembly, locally, so the rule
holds offline. Rejection is explicit, not a warning.

Refs: FR-4, BR-4.2, AC-4.2
Guardian: G6
```

Types: `feat` · `fix` · `refactor` · `test` · `docs` · `chore` · `perf` · `build` · `ci`.
Scopes follow the modules: `api`, `mobile`, `dashboard`, `contracts`, `sync`, `pos`,
`inventory`, `ledger`, `auth`, `rls`, `ci`.

## 6. Pull requests

Use `.github/pull_request_template.md` — it is a checklist, not a formality. A PR states:

1. **What** changed and **which requirement** it serves.
2. **Guardian suites** it touches or relies on.
3. Whether it touches a **controlled artifact** (§6).
4. How it was verified — including, for offline behaviour, on what device.

**Merge requirements** (`../06-delivery-plan.md` §4, as adapted by **ADR-011** for a single
maintainer):

| | Ordinary change | Controlled artifact |
|---|---|---|
| CI gates green | required | required |
| Approvals | 0 — GitHub will not let you approve your own PR | 0, for the same reason |
| Self-review on the PR | expected | **required**, and the CI job greps the PR body for it |
| ADR | if a decision is made | **always** — enforced by CI |
| Contract tests updated | if the contract moved | **always**, incl. N-1 (ADR-009) |
| Guardian suite updated | if behaviour changed | **always** — enforced by CI |
| RTM updated | for requirement work | **always** |

The head-count is gone because it was unsatisfiable, not because the scrutiny was optional.
What replaced it — the `controlled-artifact` job — is stricter in the way that matters: it
cannot be forgotten at the end of a long day.

Linear history. **Merge commits for curated multi-commit PRs**, squash for single-commit
ones (ADR-011 §5: squash exists to collapse review-fixup noise, which a solo PR does not
accumulate). No direct pushes to `main` — ever, including for a one-line hotfix; a hotfix is
a fast PR, not an exception to the rule.

## 7. Controlled artifacts

Four things break catastrophically and quietly, so they carry heavier process
(`../06-delivery-plan.md` §7):

| Artifact | Lives in | Breaks as |
|---|---|---|
| The sync envelope (`../04-system-design.md` §7) | `packages/contracts/` | silently dropped or duplicated real transactions |
| The event / ledger schema (`../04-system-design.md` §5.6) | `apps/api/src/modules/ledger/` | an unauditable, legally exposed record |
| RLS policies (ADR-007) | `apps/api/src/migrations/` | cross-tenant data leakage |
| Compliance rules (FR-4 / FR-6) | `apps/api/src/modules/pos/`, `apps/mobile/lib/domain/` | dispensing that violates the directive |

Touching one of these is not a normal PR. It needs an ADR, both-side contract tests, a
guardian-suite update, a recorded self-review, and an RTM update — before merge, not after.
The `controlled-artifact` workflow fails the build if the ADR, the guardian update or the
self-review line is missing (ADR-011).

## 8. Reviewing

You are the reviewer. Open the **Files changed** tab and read the diff there before merging
— not in your editor, where you already know what you meant. These questions, in this order:

1. **Does it cross a tenant boundary?** Any new query — does it run on the scoped
   `EntityManager`? Is there a test with a second tenant that proves it?
2. **Can it lose or duplicate a transaction?** Is every write idempotent under replay?
3. **Does it mutate the ledger?** An `UPDATE` or `DELETE` on `event` is an automatic reject.
4. **Is money integer santim end to end**, including in the Dart code and in the JSON?
5. **Does it quietly build something the docs deferred?**
6. Then the ordinary things: naming, tests, readability.

Review the diff against the requirement, not against your preference. If the requirement is
wrong, say so on the issue — don't negotiate it in the PR.

Leave the findings as PR comments even when you are the only reader. The comment is the
record that the pass happened, and it is what an auditor or a future colleague can check.

## 9. Releases

- **SemVer per app**, cut from `main` by **tag**, never from a release branch
  (`../06-delivery-plan.md` §4, §10): `api-v1.2.0`, `dashboard-v1.2.0`, `mobile-v1.2.0`.
- **The sync contract versions independently** and keeps an N-1 window ≥ the offline ceiling
  plus margin (ADR-009). The server never assumes a client has updated.
- Every tag carries a changelog entry generated from Conventional Commits.
- Production deploy is gated on manual approval after staging verification
  (`../06-delivery-plan.md` §6.2).

## 10. Incidents

An S1 — data loss, cross-tenant leakage, ledger corruption, money error — stops the line
(`../05-qa-and-test-strategy.md` §14): roll back first, diagnose second. Every S1 that
reaches production is an **escaped defect** and closes with a new guardian assertion that
would have caught it. That is how the guardian suites grow: from real failures, not from
speculation.
