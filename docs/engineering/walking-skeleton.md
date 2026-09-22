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

## 6. What "green" unlocks

Phase 1 (`../06-delivery-plan.md` §2): the full core loop for standard drugs — FR-1, FR-2,
FR-3, FR-4, FR-7 base, FR-8 with cash-up, FR-9 single-writer, FR-10. Each of those bolts onto
a spine that has already been proven to survive a power cut.
