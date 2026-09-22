# ADR-010 — Repository layout, workspace tooling & contract codegen

**Status:** Accepted · **Date:** 2026-09-22
**Depends on:** ADR-001 (stack), ADR-005 (sync seam), ADR-009 (N-1 compatibility)
**Related:** `05-qa-and-test-strategy.md` §6 (anti-drift), `06-delivery-plan.md` §4, §6

## Context

ADR-001 fixes the stack (Flutter · NestJS · PostgreSQL · React dashboard) but not *how the
code is organised*. Three build targets in two languages must be developed, versioned, and
released together, and `05-qa` §6 requires the sync envelope to have a **single source of
truth** from which Dart and TypeScript types are **generated, not hand-written** — because
client/server drift on that contract silently drops or duplicates real transactions.

Two structural questions follow: one repository or several, and where the contract lives.

## Decision

**1. One repository, polyglot, three deployable apps.**

```
apps/api           NestJS backend          → container image
apps/dashboard     React + Vite + TS       → static bundle
apps/mobile        Flutter                 → signed Android (primary) / iOS
packages/contracts Sync + API contract     → generated TS and Dart types
```

**2. pnpm workspaces** for the JavaScript/TypeScript side (`apps/api`, `apps/dashboard`,
`packages/contracts`). Flutter keeps its own pub toolchain under `apps/mobile` and is not a
pnpm workspace member; it consumes generated Dart under `apps/mobile/lib/contracts/`.

**3. `packages/contracts` is the single source of truth for the sync envelope** (`04`§7) and
the shared API DTOs. Types are authored once as **Zod schemas**, from which we derive:
- TypeScript types directly (`z.infer`), consumed by the API and the dashboard;
- **JSON Schema**, emitted as a versioned artifact and used for contract tests;
- **Dart** classes generated into the Flutter app by `scripts/gen-contracts.ts`.

Generated files are **committed** and CI fails if regeneration produces a diff — so a
contract change can never land on one side only.

**4. The contract is versioned independently of the apps** (ADR-009). `packages/contracts`
exports `CONTRACT_VERSION` and retains the previous version's schemas under
`src/versions/` for as long as the N-1 window requires.

**5. The dashboard is React + Vite, not Next.js.** ADR-001 said "React/Next.js";
`03-architecture.md` §7 requires the dashboard to ship as **static assets served alongside
the same NestJS API**. It is an authenticated internal console with no SEO, no SSR need, and
no second server to operate. Vite gives the static bundle that the deployment topology
already assumes, with less runtime to run and patch. This ADR settles the open choice.

## Rationale

- **One repository** keeps an atomic commit across a contract change and both of its
  consumers. With three repositories, the contract can only ever be updated in sequence, and
  the window between those merges is exactly the drift `05-qa` §6 forbids. A single repo also
  gives one PR, one review, one CI run for a change that spans client and server.
- **pnpm** for its strict, content-addressed `node_modules` (a package cannot import a
  dependency it did not declare) and first-class workspace support — the boundary discipline
  the modular monolith wants, enforced by the package manager.
- **Zod as the authoring format** because the API needs *runtime* validation of every synced
  operation anyway. One artifact then serves validation, TypeScript types, JSON Schema for
  contract tests, and Dart codegen — instead of an OpenAPI document that describes the
  contract but does not enforce it at the boundary.
- **Committed generated code** makes drift a visible, reviewable diff and keeps the Flutter
  build free of a Node toolchain dependency.

## Consequences

- CI runs three toolchains (Node, Node+Vite, Flutter) in one pipeline; jobs are gated by
  changed paths so a Dart-only change does not rebuild the backend.
- A contract change touches `packages/contracts` plus generated output on both sides — which
  is exactly the review surface `06-delivery-plan.md` §7 wants for a controlled artifact.
- The repository grows large over time (Flutter + Node). Accepted; shallow clones and
  path-filtered CI keep it workable.
- If a service is ever extracted (`03`§3 keeps the option open), it moves out as a directory
  with its history intact — the module boundaries, not the repo boundary, are what matter.

## Alternatives rejected

- **Three separate repositories** — forces sequenced contract merges and cross-repo PR
  choreography; the drift risk is structural, not a matter of discipline.
- **Nx / Turborepo** — real value at many packages; at four, the configuration surface costs
  more than the task orchestration saves. Reconsider if the workspace grows past ~10 packages.
- **OpenAPI as the source of truth** — good for documentation and external consumers, but it
  does not validate at runtime, so the API would still need a second schema. Generating
  OpenAPI *from* the Zod schemas keeps the single source and still yields a published spec.
- **Hand-written types on both sides** — explicitly rejected by `05-qa` §6.
- **Next.js for the dashboard** — SSR/routing/server runtime for an authenticated internal
  console with no SEO requirement, plus a second deployable to operate. Rejected per §5 above.
