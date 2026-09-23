# 02 — Software Requirements Specification (SRS)

**Project:** Pharmacy System · **Release:** V1
**Status:** ✅ Draft · owner: Bina
**Depends on:** `01-vision-and-scope.md`, ADR-001–004
**Feeds:** `03-architecture.md`, `04-system-design.md`, `05-qa-and-test-strategy.md`

> This SRS specifies **only V1 in-scope** requirements (Vision & Scope §2.1). Deferred and
> out-of-scope items are noted where they touch an in-scope requirement, but not specified.
> Every requirement has a stable ID. IDs are never reused or renumbered — deprecate instead.

---

## 1. Introduction

### 1.1 Purpose
Define the functional and non-functional requirements for V1 of the Pharmacy System in
enough detail to design, build, and test against — and to serve as the binding contract
for engineers and Claude Code.

### 1.2 Scope
See `01-vision-and-scope.md`. In one line: an offline-first, multi-tenant SaaS that runs
the independent Ethiopian pharmacy's daily managerial loop — inventory, dispensing, cash
control, and controlled-substance compliance — across one or many branches, plus a web
admin dashboard for platform operations.

### 1.3 Definitions
| Term | Meaning |
|------|---------|
| Tenant | A pharmacy business (one owner). Isolation boundary (ADR-003). |
| Branch | A physical store belonging to a tenant. |
| Terminal | A single device running the mobile app at a branch. V1 assumes **one writer terminal per branch** (ADR-002). |
| Core loop | receive stock → sell/dispense → decrement → cash-up → owner visibility. |
| Standard drug | Non-controlled item; mutable stock, negative-stock policy. |
| Controlled substance | Regulated/psychotropic item; append-only ledger (ADR-004). |
| Ledger | Append-only, event-sourced record for controlled substances. |
| Cash-up | Per-shift reconciliation of counted cash vs. system-expected cash. |
| Outbox | Local queue of operations awaiting sync (ADR-002). |

### 1.4 References
EFDA directive No. 1121/2025 (`[ASSUMPTION]` A-1 — pending compliance verification);
ADR-001–004; Vision & Scope §7 (assumptions & risks).

---

## 2. Overall description

### 2.1 Product perspective
Flutter mobile clients (Android primary, iOS same codebase) and a web admin dashboard,
all on one NestJS + PostgreSQL backend (ADR-001). Clients are **offline-first**: all
core-loop writes hit local SQLite first and sync via an append-only outbox; the server is
the source of truth (ADR-002). Tenant isolation is row-level with Postgres RLS + an
application scoping guard (ADR-003).

### 2.2 User classes (actors)
| Actor | Description |
|-------|-------------|
| **Platform Admin** | Us. Operates the SaaS above tenant scope: onboarding, payment verification, subscription control. |
| **Owner** | Buys and owns a tenant. Full authority across all their branches. |
| **Branch Manager** | Runs one branch; branch-scoped authority. |
| **Pharmacist / Cashier** | Operates POS and dispensing at a branch. |

### 2.3 Operating environment & constraints
Intermittent power and connectivity (drives NFR-1); no payment-gateway integration in V1
(manual screenshot verification); Amharic/English + Ethiopian calendar (FR-10); regulated
controlled-substance handling (FR-4, FR-6, ADR-004).

### 2.4 Assumptions & dependencies
Inherited from Vision & Scope §7 (A-1 regulatory verification is a **blocker before this
SRS is frozen**; A-3 single-terminal prevalence validates the FR-9 single-writer scope).

---

## 3. Functional requirements

Priority: **M** = must (V1), **S** = should (V1 if capacity allows), **D** = deferred (not V1, listed for boundary clarity).

---

### FR-1 — Tenant & Branch Management · Priority: M
**Actors:** Platform Admin, Owner.
**Preconditions:** For tenant creation, Platform Admin authenticated on the web dashboard.

**Main flow (tenant onboarding):**
1. Platform Admin creates a tenant (business name, owner contact, subscription state = *pending*).
2. Owner account is provisioned; Owner sets credentials.
3. Owner creates one or more branches (name, address, contact).
4. Owner assigns staff to branches (FR-2).

**Business rules:**
- BR-1.1 A tenant has ≥ 1 branch. A single-pharmacy owner is a tenant with exactly one branch — no separate concept.
- BR-1.2 Every domain record carries `tenant_id`; branch-scoped records also carry `branch_id` (ADR-003).
- BR-1.3 A tenant in *suspended* subscription state is read-only for its users except where noted (see FR-2 / billing).

**Acceptance criteria:**
- AC-1.1 *Given* a new tenant with no branch, *when* the Owner logs in, *then* they are required to create a branch before any inventory/POS action.
- AC-1.2 *Given* two tenants, *when* Owner A queries any data, *then* no row belonging to tenant B is ever returned (verified against RLS, not only app code).

---

### FR-2 — Authentication & Authorization (RBAC) · Priority: M
**Actors:** all.
**Preconditions:** valid account; for offline login, a prior successful online login on that terminal.

**Main flow:**
1. User authenticates (username/PIN or password; PIN acceptable for fast counter login).
2. System resolves the user's role, tenant, and branch scope.
3. Every subsequent action is authorized against the permission matrix below.
4. Offline: the terminal validates against locally cached credentials/roles from last sync.

**Permission matrix** (✓ = allowed; **B** = branch-scoped only; **T** = tenant-wide; — = denied):

| Capability | Platform Admin | Owner | Branch Manager | Pharmacist/Cashier |
|---|---|---|---|---|
| Manage tenants & subscriptions | ✓ | — | — | — |
| Verify payment screenshots | ✓ | — | — | — |
| Manage branches | — | T | — | — |
| Manage staff & role assignment | — | T | B | — |
| Manage products & pricing | — | T | B | — |
| Receive goods (FR-7) | — | ✓ | B | B |
| Sell / dispense standard drugs (FR-4) | — | ✓ | B | B |
| Dispense controlled substances (FR-4/6) | — | ✓ | B | B |
| Perform cash-up (FR-8) | — | ✓ | B | B (own shift) |
| View branch reports | — | T | B | own shift |
| View tenant-wide reports | — | T | — | — |
| Configure tenant settings | — | T | — | — |

**Business rules:**
- BR-2.1 Scope is enforced at DB (RLS) **and** application layers (ADR-003). No unscoped query is permitted (QA gate).
- BR-2.2 Platform Admin has **no** default access to tenant sales/clinical data; support access is explicit, least-privilege, and audited (FR-6 audit infra).
- BR-2.3 Offline login is permitted only on a terminal with cached credentials no older than the supported offline window (NFR-1); beyond it, re-auth online is required for privileged actions but **not** to complete an in-progress sale.

  *Implementation note (P3).* "Privileged" is read as **everything the FR-2 matrix grants
  beyond the trading loop**. Two capabilities survive an expired window: `sale.create`,
  which BR-2.3 names, and `cashup.perform`, which it does not. Cash-up is included on
  BR-2.3's own reasoning rather than as an extension of it — a shift opened before the
  window closed has cash in a drawer, and refusing to close it would leave that drawer
  unreconciled overnight, which is precisely the loss FR-8 exists to prevent. The set is
  pinned by a test, so widening it has to be a deliberate and reviewable act
  (`mobile/lib/auth/offline_window.dart`).

**Acceptance criteria:**
- AC-2.1 *Given* a Cashier, *when* they attempt to change a product price, *then* the action is denied at both app and API layers.
- AC-2.2 *Given* an offline terminal within the supported window, *when* a Cashier logs in with cached PIN, *then* login succeeds and POS is usable.

---

### FR-3 — Inventory Management · Priority: M
**Actors:** Owner, Branch Manager, Pharmacist.
**Preconditions:** branch exists; products defined.

**Main flow:**
1. Products are defined with attributes incl. controlled-substance flag, unit, price.
2. Stock enters via goods receipt (FR-7) as **batch/lot** records with expiry date.
3. Stock decrements on sale/dispense (FR-4).
4. Stock is queryable per product, showing on-hand, batches, and nearest expiry.

**Business rules:**
- BR-3.1 Stock is tracked at **batch/lot** granularity with expiry (enables FEFO and expiry alerts).
- BR-3.2 **Standard drugs:** mutable stock with a **negative-stock (oversell-and-reconcile)** policy — a sale is never blocked by a stock count; oversell is recorded and flagged for physical reconciliation. Rationale: ADR-002 (conservation-law; offline cannot prevent oversell).
- BR-3.3 **Controlled substances:** stock is a **projection over the append-only ledger** (ADR-004); not a mutable counter; adjustments are compensating events.
- BR-3.4 Near-expiry and expired stock are surfaced to Owner/Branch Manager (expiry alerting).
- BR-3.5 All stock records are soft-deleted, never hard-deleted (retention, NFR-5).

**Acceptance criteria:**
- AC-3.1 *Given* zero on-hand of a standard drug, *when* a Cashier sells one, *then* the sale completes, on-hand becomes −1, and an oversell flag is raised.
- AC-3.2 *Given* two batches with different expiry, *when* stock is dispensed, *then* the system proposes the **first-to-expire** batch (FEFO).
- AC-3.3 *Given* a controlled substance, *when* current stock is displayed, *then* it equals the sum of its ledger events (no independent mutable counter exists).

---

### FR-4 — Point of Sale / Dispensing · Priority: M
**Actors:** Pharmacist/Cashier (Owner, Branch Manager may also).
**Preconditions:** authenticated; branch open; offline-capable.

**Main flow (standard sale):**
1. Cashier builds a sale (scan/select items, quantity).
2. System applies pricing; computes total.
3. Cashier records payment (cash in V1; other tender types recorded, not integrated).
4. Sale is committed to **local SQLite** and enqueued in the outbox; receipt available.
5. Stock decrements (BR-3.2).

**Alternate flow (controlled/psychotropic dispensing):**
- 4a. System enforces psychotropic rules (`[ASSUMPTION]` A-1, verify): **dedicated prescription paper** recorded; **one psychotropic substance per prescription**; **validity 15 days** for psychotropics vs. **30 days** standard.
- 4b. The dispense is written as an **immutable ledger event** (FR-6, ADR-004), not a mutable stock decrement.

**Exception flows:**
- E-4.1 Offline: steps 1–5 function entirely against local state; nothing blocks on network.
- E-4.2 Expired-only stock available: system warns and requires explicit override by an authorized role before dispensing.

**Business rules:**
- BR-4.1 A sale, once committed locally, is durable and will sync; it is never silently dropped.
- BR-4.2 Psychotropic rule violations (e.g., two psychotropics on one prescription) are **blocked**, not warned.
- BR-4.3 Every dispense records the acting user, timestamp (UTC), branch, and terminal.

**Acceptance criteria:**
- AC-4.1 *Given* an offline terminal, *when* a Cashier completes a cash sale, *then* a receipt is produced and the sale is queued for sync with zero data loss on later reconnect.
- AC-4.2 *Given* a psychotropic prescription, *when* the Cashier adds a second psychotropic substance, *then* the system blocks it with an explanatory message.
- AC-4.3 *Given* a psychotropic prescription older than 15 days, *when* dispensing is attempted, *then* it is rejected as expired.

---

### FR-6 — Controlled Substance Compliance · Priority: M
**Actors:** Pharmacist (dispense), Owner/Branch Manager (audit view), Platform Admin (support, audited).
**Preconditions:** product flagged controlled.

**Main flow:**
1. Every controlled-substance action (receipt, dispense, adjustment) is written as an **append-only, immutable event** (ADR-004).
2. Events carry actor, timestamp (UTC), branch, terminal, quantity, and prescription reference where applicable.
3. Current stock is a projection over events (BR-3.3).
4. Corrections are **compensating events** referencing the original; nothing is edited or deleted.
5. The same event infrastructure powers a **general action audit log** (who-did-what) beyond controlled substances.

**Business rules:**
- BR-6.1 Ledger events are never updated or physically deleted; deletes are tombstone events (sync invariant, ADR-002/004).
- BR-6.2 Retention: minimum per EFDA (stated 5 years, `[ASSUMPTION]` A-1); system holds **7 years** (NFR-5).
- BR-6.3 The ledger must be exportable for audit in a human-readable form (base export; advanced export is FR-8a, deferred).

**Acceptance criteria:**
- AC-6.1 *Given* a dispensed controlled substance, *when* a user attempts to edit or delete that record, *then* the operation is impossible via any interface; only a compensating event can be added.
- AC-6.2 *Given* a range of dates, *when* an Owner requests the controlled-substance ledger, *then* a complete, ordered, immutable history is produced.

---

### FR-7 — Purchasing & Goods Receipt (base) · Priority: M
**Actors:** Owner, Branch Manager, Pharmacist.
> Extensions **FR-7a usage-based ordering** and **FR-7b multi-wholesaler ordering** are **D — deferred** (V1.x/V2). Not specified here.

**Main flow:**
1. A purchase/receipt is recorded against a supplier (free-form supplier in V1).
2. Received items create batch/lot stock with expiry (FR-3).
3. Receipt updates on-hand (standard) or appends receipt events (controlled).

**Acceptance criteria:**
- AC-7.1 *Given* a goods receipt of a standard drug with a batch and expiry, *when* committed, *then* on-hand increases and the batch/expiry is queryable.
- AC-7.2 *Given* a goods receipt of a controlled substance, *when* committed, *then* a receipt **event** is appended to its ledger.

---

### FR-8 — Reporting & Analytics (base) · Priority: M
**Actors:** Owner (tenant-wide), Branch Manager (branch), Cashier (own shift).
> **FR-8a advanced reporting / custom search / export** is **D — deferred**.

**Base reports (V1):**
1. **Per-shift cash reconciliation (cash-up / Z-report)** — counted cash vs. system-expected, per staff member, per shift. *Primary anti-shrinkage control; folded into V1 per Vision §2.1.1.*
2. Daily sales summary (per branch; consolidated for Owner).
3. Current stock & near-expiry report.
4. Controlled-substance ledger report (FR-6).

**Business rules:**
- BR-8.1 Reports reflect **synced** data; where a terminal is offline, reports note data currency ("as of last sync at …").
- BR-8.2 Cash-up compares expected cash (from committed sales) against counted cash; variance is recorded and attributed to the staff member and shift.

**Acceptance criteria:**
- AC-8.1 *Given* a completed shift, *when* the Cashier performs cash-up, *then* the system shows expected vs. counted cash and records any variance against that user and shift.
- AC-8.2 *Given* multiple branches, *when* the Owner opens the sales summary, *then* consolidated and per-branch figures are both available.

---

### FR-9 — Offline Sync Engine (single-writer) · Priority: M
**Actors:** system (background), all users implicitly.
> **Multi-writer tier + conflict resolution (full FR-9 + NFR-2)** is **D — deferred to V2** (ADR-002).

**Main flow:**
1. Every core-loop write commits to **local SQLite** and appends to the **outbox**.
2. On connectivity, the client pushes outbox operations to the server **in order**; the server (source of truth) applies them and returns acknowledgements.
3. The client pulls server-side deltas (reference data: catalog, pricing, config, roles) since last sync.
4. Acknowledged operations are cleared from the outbox.

**Business rules:**
- BR-9.1 V1 assumes **one writer terminal per branch**; no write conflicts are possible, so no conflict-resolution policy exists in V1.
- BR-9.2 Sync is **idempotent**: replaying an already-applied operation has no additional effect (operation IDs).
- BR-9.3 Deletes propagate as **tombstones**, never physical removals (ADR-002/004 invariant).
- BR-9.4 Reference-data staleness up to the supported offline window (NFR-1) is accepted; the client shows data currency.

**Acceptance criteria:**
- AC-9.1 *Given* 200 offline transactions, *when* the terminal reconnects, *then* all 200 sync exactly once, in order, with zero loss or duplication.
- AC-9.2 *Given* a transient network failure mid-sync, *when* sync retries, *then* no operation is applied twice (idempotency).

---

### FR-10 — Localization · Priority: M
**Actors:** all.

**Business rules:**
- BR-10.1 UI supports **Amharic and English**, switchable per user.
- BR-10.2 All user-facing dates render in the **Ethiopian calendar**; storage is **UTC ISO-8601**; conversion is presentation-only.
- BR-10.3 Currency is **ETB**, formatted per locale.

**Acceptance criteria:**
- AC-10.1 *Given* a user set to Amharic, *when* they view any core screen, *then* labels and dates render in Amharic and the Ethiopian calendar.
- AC-10.2 *Given* any stored timestamp, *when* inspected in the database, *then* it is UTC ISO-8601 regardless of display locale.

---

## 4. Non-functional requirements

### NFR-1 — Offline capability & availability · Priority: M
- **NFR-1.1 Guaranteed offline window: 72 hours.** All core-loop functions (login within cache, sell/dispense, receive, cash-up) operate with **no degradation** for up to 72 continuous hours offline. This is the tested guarantee.
- **NFR-1.2 Degraded ceiling: up to 7 days.** From 72h to 7 days the app continues to permit selling (Principle #1) under escalating "sync required" warnings; reference-data staleness is accepted; non-essential admin actions may be restricted. Beyond 7 days is best-effort/unsupported — but the app **never hard-blocks a core sale**.
- **NFR-1.3 Zero data loss:** any locally committed operation survives app restart, device reboot, and prolonged offline, and syncs exactly once on reconnect (ties to AC-9.1).
- **NFR-1.4 Backend availability: 99.5%** for V1. Justification: offline-first means backend downtime does not stop the counter; 99.5% is honestly operable by the team and sufficient given the architecture. Revisit upward as scale grows.

### NFR-2 — (Reserved) Multi-writer conflict resolution · Priority: D
Deferred to V2 (ADR-002). ID reserved so downstream traceability stays stable.

### NFR-3 — Scalability & performance · Priority: M
- **NFR-3.1 Tenant scale:** support **1,000 tenants** on shared Postgres (ADR-003) without redesign.
- **NFR-3.2 Local op latency:** core-loop actions (add item, commit sale) complete against local SQLite in **< 100 ms**, independent of network — this is the offline-first payoff and is non-negotiable for counter UX.
- **NFR-3.3 Sync latency:** a terminal syncing after up to 72h offline completes a full push/pull in **< 10 s** on a typical mobile connection for a normal day's transaction volume.
- **NFR-3.4 API latency:** server p95 **< 500 ms** for sync endpoints and **< 1 s** for dashboard reads under target load. Heavy reports may run asynchronously.

### NFR-4 — Security & data protection · Priority: M
- **NFR-4.1** Tenant isolation enforced at DB (RLS) and app layers; a single missed scope in code must not cause cross-tenant leakage (ADR-003).
- **NFR-4.2** Credentials stored hashed; local cached credentials on-device protected (secure storage); PIN login rate-limited.
- **NFR-4.3** Transport encrypted (TLS) for all client-server traffic.
- **NFR-4.4** Platform Admin support access to tenant data is least-privilege and audited (BR-2.2).

### NFR-5 — Data retention · Priority: M
- **NFR-5.1 Controlled-substance ledger:** retained **7 years** minimum (≥ EFDA stated 5, `[ASSUMPTION]` A-1); never hard-deleted, including across tenant offboarding within the window.
- **NFR-5.2 Sales/financial records:** soft-delete only; retention planned at **10 years** to align with Ethiopian business/tax record-keeping (`[ASSUMPTION]` — verify with accounting/tax before freeze).
- **NFR-5.3 All domain data:** soft-delete, never hard-delete; sync deletes are tombstones (ADR-002/004).

### NFR-6 — Localization & usability · Priority: M
Amharic/English + Ethiopian calendar (FR-10); counter workflows optimized for speed (PIN login, minimal taps to complete a sale) since throughput at the counter drives adoption.

### NFR-7 — Maintainability & observability · Priority: S
- Structured logging and sync telemetry (queue depth, sync failures, oversell counts) surfaced to the platform team; consistent NestJS module conventions for a multi-engineer team.

---

## 5. Data retention & compliance summary

| Data class | Model | Delete policy | Retention |
|---|---|---|---|
| Controlled-substance ledger | Append-only event-sourced | Tombstone only (no physical delete/edit) | 7 years (≥ EFDA A-1) |
| Sales / financial records | Mutable + soft-delete | Soft-delete | ~10 years (verify) |
| Standard inventory | Mutable + soft-delete | Soft-delete | Business-defined |
| General action audit log | Append-only events | Tombstone only | ≥ 7 years |
| Reference data (catalog, pricing) | Mutable, versioned | Soft-delete | Life of tenant |

---

## 6. Requirements traceability matrix (skeleton)

Filled as design and tests land. Every M-priority FR/NFR must trace to a design element and ≥ 1 test before it is "done." Controlled-substance requirements (FR-4 psychotropic rules, FR-6, NFR-5.1) are the highest-priority traceability targets.

*Last updated: 2026-09-23, after FR-8 cash-up landed (Phase 1, slice 1).*

Status legend: **Skeleton** — the Phase 0 slice of this requirement is implemented and
tested · **Open** — not yet built · **Gated** — blocked on a stated gate.

| Req ID | Design ref (`04-system-design.md`) | Implementation | Test ref | Status |
|---|---|---|---|---|
| FR-1 tenant/branch + **onboarding, billing, subscriptions** | §5.1, §5.8 | `api/src/modules/billing/`, `api/src/common/auth/{subscription.guard,platform-admin.guard}.ts`, `dashboard/src/pages/PlatformPage.tsx` | `g1-tenant-isolation.spec.ts`, `g1-subscription-suspension.spec.ts` (15) | **Done** — Platform Admin as a separate identity (BR-2.2), manual screenshot verification (Vision §4), and BR-1.3 suspension as interpreted by ADR-016 |
| FR-2 (+ matrix) | §8, §5.1 | **matrix: `packages/contracts/src/permissions.ts`** (generated into Dart) · enforcement: `api/src/common/auth/{capability.guard,branch-scope}.ts`, `api/src/modules/admin/` · client: `mobile/lib/core/permissions.dart` | `g1-permission-matrix.spec.ts` (21), `permissions_test.dart` (11), `g1-report-scoping.spec.ts` (17) | **Done** — every role × capability cell tested at both layers (`05-qa` §10); AC-2.1 verified on both. Platform-Admin capabilities are declared and denied to every tenant role; their own surface is FR-1 billing, still open. |
| FR-3 inventory (FEFO, negative stock, **reconciliation**) | §5.3, §10 | `api/src/modules/inventory/`, `api/src/modules/reporting/stock-report.service.ts`, `mobile/lib/data/{catalog,inventory}_repository.dart`, `mobile/lib/ui/reconcile_screen.dart` | `g5-oversell-detected.spec.ts`, `g5-stock-reconciliation.spec.ts` (12), `g5_reconciliation_test.dart` (13), `fefo_test.dart` | **Done** — FEFO, negative stock, BR-3.4 expiry alerting, and BR-3.2's promised **physical reconciliation** (contract v1.2.0). E-4.2 expired-stock override still open. |
| FR-4 POS (standard sale) | §5.4 | `mobile/lib/data/sale_repository.dart`, `api/src/modules/sync/sync.service.ts` | `mobile/test/guardian/g7_offline_durability_test.dart` | Skeleton |
| FR-4 psychotropic rules | §6.4 | — | — | **Gated on A-1.** Not built, not partially built, not behind a flag — the rules' shape is itself the regulatory answer (ADR-015). |
| FR-6 — event store + **general audit log** | §5.6, §6 | `apps/api/src/migrations/EventStore`, `apps/api/src/modules/audit/`, `dashboard/src/pages/AuditPage.tsx` | `g3-ledger-immutability.spec.ts` (13) | **Done** for the non-regulated half (Vision §2.1.1). Append-only enforced by the database — UPDATE, DELETE and TRUNCATE all refused, including for the owner role. |
| FR-6 — controlled-substance ledger | §5.6, §6 | — | — | **Gated on A-1.** No `controlled.*` event type exists and the `controlled_stock` stream has never been written to; a guardian assertion holds that true (ADR-015). |
| FR-7 goods receipt (base) | §5.5 | `api/src/modules/sync/sync.service.ts` (`applyGoodsReceipt`), `inventory.service.ts` (`applyReceipt`), **`mobile/lib/ui/receive_screen.dart`** | `g7-offline-resilience.spec.ts`, `g5_reconciliation_test.dart` | **Done** — the counter can now record a delivery offline, and the shelf is credited immediately. |
| FR-8 reporting + cash-up | §5.4, §9 | cash-up: `api/src/modules/cashup/`, `mobile/lib/{data/shift_repository.dart,ui/cash_up_screen.dart}`, `dashboard/src/pages/CashUpPage.tsx` · reports: `api/src/modules/reporting/{sales-summary,stock-report}.service.ts`, `dashboard/src/pages/{SalesSummaryPage,StockPage}.tsx` | `g4-cash-up.spec.ts` (12), `g4_cash_up_test.dart` (10), `g1-report-scoping.spec.ts` (17) | **Done** — AC-8.1 cash-up, AC-8.2 consolidated + per-branch summary, BR-3.4 expiry alerting. Controlled-substance ledger report awaits Phase 2. |
| FR-9 single-writer sync | §7, §10 | `api/src/modules/sync/`, `mobile/lib/{sync,data/outbox.dart}` | `api/test/guardian/g2-sync-integrity.spec.ts`, `mobile/test/guardian/g2_sync_integrity_test.dart` | Skeleton |
| FR-10 localization | §3 | calendar: `packages/contracts/src/ethiopian-calendar.ts` + `mobile/lib/core/ethiopian_date.dart` (two implementations, one shared vector table) · strings: `mobile/lib/l10n/` · console toggle: `dashboard/src/lib/format.ts` | `ethiopian_date_test.dart` (19), `strings_test.dart` (7), `calendar.spec.ts` (16), `g4-utc-storage.spec.ts` (5) | **Done** — AC-10.1 Amharic + Ethiopian calendar, AC-10.2 UTC storage asserted at the schema level |
| NFR-1 offline window | §7, §8 | `mobile/lib/data/local_db.dart`, `outbox.dart`, `auth/offline_window.dart` | `g7_offline_durability_test.dart`, `g7_offline_window_test.dart` (6), `g7-offline-resilience.spec.ts`; field UAT is the release gate | **Done** — durability and the authority ceiling are both enforced; the 72h backlog replays in 3.4 s |
| NFR-3.2 local op < 100 ms | §7 | single local transaction, no network on the sale path | `g7_local_latency_test.dart` (percentile regression guard, CI) + `integration_test/nfr3_local_latency_test.dart` (**on-device**, `scripts/device-matrix.sh`) | Partial — harness built and CI guard tight; the device figure needs a handset (`engineering/device-matrix.md`, GA gate) |
| NFR-3.3 sync < 10s after 72h | §7 | `api/src/modules/sync/`, 2 MB body limit derived from the contract cap | `test/perf/nfr3.perf-spec.ts` | **Met** — 3.4 s for 186 ops |
| NFR-3.4 API p95 | §7, §9 | one query per report; lateral aggregates, no N+1 | `test/perf/nfr3.perf-spec.ts` | **Met** — sync 33 ms / 500, dashboard ≤ 36 ms / 1000 |
| NFR-4.1 tenant isolation | §8, ADR-003/007 | `api/src/common/db/scoped-db.service.ts`, RLS policies in `InitialSchema`, `common/auth/jwt-auth.guard.ts` | `g1` suite + `g1-cross-tenant-route-sweep.spec.ts` (50) + `no-unscoped-access.spec.ts` | **Done** — every route the app serves is attempted across the boundary, and a route nobody has classified fails the sweep |
| NFR-4.2 credentials + rate limiting | §8, ADR-017 | `api/src/modules/auth/login-throttle.service.ts`, `migrations/LoginAttempts`, `mobile/lib/auth/{session,offline_window}.dart` | `g1-login-throttling.spec.ts` (7), `g7_offline_window_test.dart` (6) | **Done** — throttled, never locked out; the offline ceiling now actually closes (BR-2.3) |
| NFR-4.3 transport + response headers | §8 | TLS terminates at the platform edge; `apps/api/src/main.ts` sets the response headers | manual `curl -I`; asserted by `scripts/smoke.sh` | **Done** for headers. TLS is a deployment property and is verified at staging, not in CI |
| NFR-4.4 platform admin least-privilege | §8, BR-2.2 | `common/auth/platform-admin.guard.ts`, `modules/billing/platform-auth.service.ts` | `g1-cross-tenant-route-sweep.spec.ts` — both directions | **Done** — a platform token is refused by every tenant route and a tenant token by every platform route |
| NFR-5 retention | §5.6, §5.8 | no `DELETE` grant to the app role; `deleted_at` on every table | schema-level; ledger retention is Phase 2 | Partial |

**FR-1 complete.** Tenant onboarding, the manual payment loop and subscription control are
built. The Platform Admin is a separate identity with its own login and a distinct token
type — there is no token that is both, so BR-2.2's "no default access to tenant data" is
structural rather than careful. What a suspension actually blocks is **ADR-016**: management
writes only, never a queued sale, a report, or the payment proof that ends it.

**Phase 2 (partial, ADR-015).** The append-only event store and the general action audit log
are built: who changed a price, added staff, or deactivated an account, recorded inside the
transaction that did it. Immutability is enforced by the database rather than by convention.
That half is product capability (Vision §2.1.1), asserts no regulatory fact, and gives the
controlled-substance ledger infrastructure that has already carried real traffic.

**The regulated half remains gated on A-1** and is not begun. G3 is therefore a *provisional*
compliance suite in the sense of `05-qa` §8: it asserts the mechanism, not the numbers.

**Phase 1 progress.** FR-8 is complete for V1's base report set: per-shift cash-up
(AC-8.1), consolidated and per-branch sales summary (AC-8.2), and stock with expiry
alerting (BR-3.4). Branch scoping — the **T** vs **B** distinction the FR-2 matrix draws,
which RLS cannot express — is enforced at every report and tested per role. 39 guardian
assertions cover this requirement across both halves.

FR-10 is complete: Amharic and English switchable per user, dates in the Ethiopian
calendar, and AC-10.2 enforced by a guardian suite that checks every timestamp column is
`timestamptz` and that no calendar or locale column exists in the domain schema at all.
The conversion is implemented twice — TypeScript and Dart — because codegen translates data
and not arithmetic; what is shared is the **evidence**, a generated vector table both
implementations are verified against.

FR-2 is now complete for tenant roles. The matrix lives in `packages/contracts` and is
**generated into Dart**, so the app and the API read the same table — AC-2.1 requires the
denial at both layers, and two copies of a permission table drift in the direction where
the app offers what the server refuses. Branch reach (T vs B vs own) is enforced on every
read and write.

**Phase 1's requirement set is complete** for everything not gated on A-1. What remains
before the phase can close is exit-gate work rather than requirements: full guardian suites
green (they are), core e2e journeys, and NFR-3 performance measured on staging and on
low-end Android — which needs the staging environment and the device lab. The
controlled-substance ledger and the Platform-Admin surface stay out until A-1 and Phase 2
respectively.

**Not yet traced, and deliberately so:** FR-5 (inter-branch transfer, V1.x), FR-7a/7b and
FR-8a (deferred), NFR-2 (V2 multi-writer). G3 (ledger immutability) and G6 (psychotropic
rules) have no suites yet because the code they would guard does not exist — both arrive
with Phase 2, behind A-1.

---

## 7. Open items carried into design
- O-1 **Resolved:** offline window = 72h guaranteed / 7-day degraded ceiling (NFR-1).
- A-1 **Blocker:** EFDA retention & psychotropic-rule verification before SRS freeze.
- NFR-5.2 sales/financial retention period — verify with tax/accounting.
- O-2 customer credit ledger — post-pilot decision (out of V1).
