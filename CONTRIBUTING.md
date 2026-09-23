# Contributing

Start with [`docs/engineering/`](docs/engineering/README.md) — repo layout, local setup, and
the daily commands. This file is the short version of the rules.

## The loop

```
issue (FR/NFR id + acceptance criteria + RTM row)
  → short-lived branch off main
    → PR → CI gates → review(s) → squash merge
```

No direct pushes to `main`, ever — including for a one-line hotfix. A hotfix is a fast PR,
not an exception.

**One maintainer.** Required approvals is zero, because GitHub will not let you approve your
own PR and a rule you have to switch off to ship is worse than no rule. The scrutiny did not
go away — it moved into CI. See [ADR-011](docs/adr/ADR-011-solo-maintainer-change-control.md).

## Before you open a PR

```bash
pnpm lint && pnpm typecheck && pnpm test
pnpm --filter @pharmaet/api test:guardian      # the merge gate
cd apps/mobile && flutter analyze && flutter test
pnpm gen:contracts && git diff --exit-code     # contract must not be stale
```

## Branch and commit names

Branches: `feat/fr-4-psychotropic-validity`, `fix/sync-duplicate-ack`,
`chore/phase-0-foundations`, `docs/adr-011-projection-rebuild`, `spike/offline-72h-harness`.

Commits follow [Conventional Commits](https://www.conventionalcommits.org/) and name their
requirement:

```
feat(pos): enforce one psychotropic substance per prescription

Blocks a second psychotropic line at sale assembly, locally, so the rule holds
offline. Rejection is explicit, not a warning.

Refs: FR-4, BR-4.2, AC-4.2
Guardian: G6
```

## The rules that will get a PR rejected

1. **A query that can cross a tenant boundary.** Everything goes through
   `ScopedDbService.runInScope`. There is a CI test that fails if another path exists.
2. **Hand-edited generated contract code**, or a contract change on only one side.
3. **Floating point anywhere near money.** Integer santim, end to end, in both languages.
4. **A hard `DELETE` on domain data**, or an `UPDATE` on the `event` table.
5. **Building something the docs marked deferred** — including "while I was in there"
   conflict-resolution code. ADR-002 is explicit: no conflict code in V1.
6. **Changing a controlled artifact without an ADR** (docs/06 §7).
7. **Re-running a red guardian test.** A flaky guardian test is itself a blocking defect.

## Controlled artifacts

The sync envelope, the event/ledger schema, RLS policies, and the compliance rules. These
break catastrophically and quietly, so they need an ADR, both-side contract tests including
N-1, a guardian-suite update, a recorded self-review, and an RTM entry.

The **`controlled-artifact`** workflow enforces this: if the diff enters one of those paths
and the PR has no ADR, no guardian-suite change, or no ticked self-review line, the build
fails. See [`docs/engineering/workflow.md`](docs/engineering/workflow.md) §6 and ADR-011.

## The ADRs are binding

If a task appears to require violating one, **stop and flag it** — do not quietly work
around it. Changing a decision means a new ADR that supersedes the old one.
