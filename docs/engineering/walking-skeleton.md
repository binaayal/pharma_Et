# Phase 0 — The Walking Skeleton

**Defined by:** `../03-architecture.md` §9 · `../04-system-design.md` §13 ·
`../05-qa-and-test-strategy.md` §17 · `../06-delivery-plan.md` §2

---

## 1. What it is

A **thin vertical slice through the real architecture** — not a prototype to throw away.
One tenant, one branch, one terminal:

```
receive stock → sell a standard drug → stock decrements → go offline →
sell again → reconnect → sync → the sale appears on the dashboard
```

Every layer it touches is the production layer: real Flutter with real SQLite and a real
outbox, the real sync envelope, the real NestJS `SyncService`, the real tenant scope guard,
real PostgreSQL with real RLS policies.

## 2. Why this first

The dominant technical risk in this system is the offline sync of conservation-law inventory
(`../01-vision-and-scope.md` R-1, ADR-002). Building breadth on an unproven sync spine means
discovering the spine is wrong after ten features depend on it. So: prove the spine, then add
breadth. This is the whole reason the delivery model is risk-first rather than waterfall
(`../06-delivery-plan.md` §1).

## 3. In scope

| Layer | Built | Deliberately not built |
|---|---|---|
| Data model | `tenant`, `branch`, `app_user`, `product`, `stock_batch`, `sale`, `sale_line`, `applied_op`, `tenant_change_seq` | The event store, projections, subscriptions, cash-up, purchasing beyond a minimal receipt |
| API | `POST /auth/login`, `POST /sync/push`, `GET /sync/pull`, a minimal read for the dashboard | Everything else in `../04-system-design.md` §9 |
| Isolation | Request-scoped `EntityManager`, `SET LOCAL`, RLS policies on every table | Fine-grained permission matrix beyond owner/cashier |
| Mobile | Local SQLite, outbox, one POS screen, sync client | Amharic/Ethiopian calendar, controlled dispensing, reports |
| Dashboard | Login, a list of synced sales | Tenant onboarding, payment verification, subscriptions |

**No controlled-substance ledger. No conflict resolution.** The ledger arrives in Phase 2
behind the A-1 gate; conflict resolution is V2 and ADR-002 forbids writing it now.

## 4. The exit gate

The skeleton is done when these four guardian suites are green in CI
(`../05-qa-and-test-strategy.md` §17) — not when the demo works:

| Suite | Assertion in skeleton terms |
|---|---|
| **G1 — Tenant isolation** | With two seeded tenants, no endpoint and no repository returns the other tenant's rows; a deliberately unscoped query is blocked **by RLS**, not by application code. |
| **G2 — Sync integrity** | N operations created offline sync **exactly once**, in `terminal_seq` order, with zero loss and zero duplication — including when the push is interrupted mid-batch and retried. Replaying any `op_id` is a no-op. |
| **G4 — Money integrity** | Every money value is integer santim end to end (Dart → JSON → Postgres `bigint`); `sale.total == Σ line_total`. |
| **G7 — Offline resilience** | A locally committed sale survives app kill and device reboot and still syncs afterwards. No core sale is ever hard-blocked. |

Plus the standing gates: CI/CD green, staging auto-deploying and reachable
(`../06-delivery-plan.md` §2).

## 5. How to verify it by hand

```bash
./scripts/dev-db.sh up
pnpm --filter @pharmaet/api migration:run
pnpm --filter @pharmaet/api seed
pnpm dev
cd apps/mobile && flutter run
```

1. Log in on the mobile app as the seeded cashier.
2. Sell an item. Confirm it appears immediately — the commit is local, so it must not wait on
   the network (`../02-srs.md` NFR-3.2: < 100 ms).
3. Put the device in airplane mode. Sell three more. Everything still works.
4. Force-stop the app. Reopen it. **The three sales are still there** — this is G7.
5. Restore connectivity. The sync chip settles to synced.
6. Open the dashboard: all four sales are present, exactly once.
7. Log in as the *other* tenant's owner. You see none of them — this is G1.

If step 4 or step 7 fails, the spine is not proven and no breadth work starts.

## 6. Where it stands today

*As of 2026-09-23.*

| Gate | State |
|---|---|
| **G1 — tenant isolation** | ✅ 5 assertions, including RLS denying a deliberately unscoped query and refusing a cross-tenant write |
| **G2 — sync integrity** | ✅ server (8) and client (8): exactly-once, partial acks, ordering, per-op isolation |
| **G4 — money integrity** | ✅ server (7) and device (9): integer santim end to end, totals reconcile, database constraint as the last line of defence |
| **G7 — offline resilience** | ✅ server (5) and device (6): 60 offline sales and the sequence counter survive a real close-and-reopen of the database file |
| **no-unscoped-access** | ✅ static check over `apps/api/src` |
| **End-to-end slice** | ✅ real Flutter stack → API → PostgreSQL: pull → 3 offline sales → reconnect → sync → 0 pending; a second sync sends nothing |
| **CI gates** | ✅ 8 checks on every PR, path-filtered, with a gate that fails on a skipped-because-broken run |
| **CD promotion path** | ✅ image published to GHCR, stood up against real Postgres, migrated, smoke-tested over HTTP, then deployed — all on merge |
| **Staging reachable** | ⛔ needs `FLY_API_TOKEN` + a Neon `DATABASE_URL` (`staging.md` §3). The dashboard ships inside the API image, so it arrives with it. |

Totals: 37 API guardian/gate tests, 28 mobile tests, 13 contract tests, 3 dashboard tests,
12 HTTP smoke assertions. The manual walkthrough in §5 was run and passed; so was the exact
CD sequence, locally, against the built image.

**Two of the three exit-gate items are met** (`../06-delivery-plan.md` §2): the guardian
suites are green and CI/CD auto-promotes on merge, having verified the image end to end
first. The third — staging reachable — is one secret away and needs an account.

Phase 1 waits for it. Not out of ceremony: the gate exists so that breadth lands on a spine
somebody has watched run somewhere real, and CI is not somewhere real.

## 7. What "green" unlocks

Phase 1 (`../06-delivery-plan.md` §2): the full core loop for standard drugs — FR-1, FR-2,
FR-3, FR-4, FR-7 base, FR-8 with cash-up, FR-9 single-writer, FR-10. Each of those bolts onto
a spine that has already been proven to survive a power cut.

The first three, in the order the docs argue for:

1. ~~**Per-shift cash reconciliation (FR-8, cash-up/Z-report).**~~ ✅ **Done.** Contract
   v1.1.0 (ADR-012), offline shift lifecycle, server-side recomputation kept beside the
   terminal's figure, and the owner's console view. 22 guardian assertions.
1b. ~~**The rest of FR-8's base reports.**~~ ✅ **Done.** Consolidated and per-branch sales
   summary (AC-8.2) and stock with expiry alerting (BR-3.4), both branch-scoped by role.
   17 further assertions.
2. ~~**The full FR-2 permission matrix**~~ ✅ **Done.** The matrix lives in
   `packages/contracts/src/permissions.ts` and is generated into Dart, so the app and the
   API read one table (AC-2.1 requires the denial at both layers). Branch, staff, catalog
   and pricing endpoints added; every cell tested at both layers. 32 assertions.
3. ~~**FR-10 localization**~~ ✅ **Done.** Amharic and English switchable per user, dates in
   the Ethiopian calendar on both clients. The conversion is implemented twice and verified
   against one generated vector table, because two hand-ported calendars diverge silently.
   AC-10.2 is asserted at the schema level: every timestamp column is `timestamptz`, and no
   calendar or locale column exists in the domain at all.

**Phase 1 is closed** (2026-09-23). Exit gate met: guardian suites full, six core e2e
journeys green, NFR-3 budgets measured against the production-like container stack. The
device matrix and hosted-staging latency move to the GA checklist, where they always
belonged.

**Phase 2 stays shut** until `[ASSUMPTION]` A-1 is verified and recorded in
`../compliance-sign-off.md`. No ledger, no psychotropic rules, no audit events before then —
not even partially, not even "while I'm in there".
