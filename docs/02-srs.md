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

### FR-11 — Sell units (break-bulk) · Priority: M · V2
**Actors:** Owner, Branch Manager (define packs); Pharmacist/Cashier (sell, receive).
**Preconditions:** product defined (FR-3). Scope and order: `07-v2-sellability-plan.md`; design: ADR-030.

**Main flow:**
1. A product keeps one **base unit** — the smallest thing sold (tablet, capsule, bottle) — and its price.
2. The Owner defines **packs** on the product: a name, how many base units it holds, and its own price (strip of 10, box of 100).
3. At receipt (FR-7), a delivery is counted in a pack or the base unit; cost is per unit counted.
4. At sale (FR-4), a line is rung up in a pack or the base unit; the cashier picks the unit, the system applies that unit's price.
5. Stock decrements and credits in base units.

**Exception flows:**
- E-11.1 Offline: steps 3–5 work entirely against the packs the terminal last pulled.
- E-11.2 A terminal sells in a pack the Owner has since changed or removed: the sale stands at the size and price it was rung up at.

**Business rules:**
- BR-11.1 **Stock is counted in the base unit only.** A product has one on-hand figure per batch, whatever units it is bought and sold in.
- BR-11.2 **A pack has its own price**, set by the Owner; it is never computed from the base price, and the base price is never computed from it.
- BR-11.3 A line's money is exact in the unit sold: `line total = quantity × that unit's price`, in integer santim (G4).
- BR-11.4 A line moves stock by `quantity × pack size`.
- BR-11.5 Defining or changing packs is a price change: it requires `catalog.manage` (AC-2.1) and is recorded in the audit log with the packs before and after.
- BR-11.6 A sale by the pack is never blocked by a stock count (BR-3.2 applies in base units).
- BR-11.7 Controlled substances are counted in the base unit only; they have no packs.
- BR-11.8 A committed line keeps the pack size, name and price it was sold at; later changes to the product do not alter it.

**Acceptance criteria:**
- AC-11.1 *Given* a product with a box of 30 priced 100.00, *when* a Cashier sells 2 boxes, *then* the line total is exactly 200.00 and on-hand falls by 60.
- AC-11.2 *Given* 10 on hand, *when* a Cashier sells 1 box of 30, *then* the sale completes, on-hand becomes −20, and an oversell is flagged.
- AC-11.3 *Given* a delivery of 5 boxes of 30 at 90.00 a box, *when* it is received, *then* on-hand rises by 150 and the receipt line reads 5 at 90.00.
- AC-11.4 *Given* a Cashier, *when* they attempt to define or change a pack, *then* the action is denied at both app and API layers.
- AC-11.5 *Given* a terminal on the previous contract version, *when* it syncs sales and receipts, *then* they apply unchanged and move stock by their quantity.
- AC-11.6 *Given* an offline terminal, *when* a Cashier sells by the pack, *then* the sale commits locally and syncs later with zero data loss.
- AC-11.7 *Given* a sale by the box, *when* the Owner later changes that pack's size or price, *then* the recorded sale is unchanged.

---

### FR-12 — Pre-loaded medicines catalogue · Priority: M · V2
**Actors:** Owner, Branch Manager.
**Preconditions:** `catalog.manage` (FR-2). Scope and order: `07-v2-sellability-plan.md`.

**Main flow:**
1. The app ships with a list of medicines — generic name, strength and dosage form — taken from EFDA's published Ethiopian Essential Medicines List.
2. When adding a product (FR-3), the Owner types a few letters; the app suggests matching medicines.
3. Picking one fills the product's name and base unit. The Owner sets the price (and any packs, FR-11) and saves.
4. The Owner may save and continue straight to the next product.

**Main flow (ticking from the list):**
1. From Stock, the Owner chooses "Pick from the medicines list" — offered first when adding a product, and shown outright while the shop has no products.
2. The whole list is shown, searchable. The Owner ticks each medicine the shop sells.
3. The Owner types a price for each ticked medicine and confirms; each becomes a product.

**Exception flows:**
- E-12.3 The connection fails partway through adding: the medicines already added are products; those not yet added stay on screen with their prices, to be sent again.
- E-12.1 The medicine is not on the list: the Owner types the name in full, as before.
- E-12.2 The list cannot be read: the form works without suggestions.

**Business rules:**
- BR-12.1 The list is **a source of suggestions, not the pharmacy's catalogue.** Nothing becomes a product until the Owner adds it with a price. *(Reading recorded here: the backlog says "ship them in the app… owner stops typing". Seeding every tenant with ~1,300 priceless products was rejected — a product with no price can be rung up at zero, and a stock list of medicines the shop does not carry buries the ones it does.)*
- BR-12.2 The list is bundled with the app and works with no network.
- BR-12.3 The list carries **no price, no pack size and no controlled-substance flag.** Picking from it never marks a product controlled; that remains gated on A-1 (ADR-024).
- BR-12.4 A medicine already in the pharmacy's catalogue under the same name is not suggested again.
- BR-12.5 The list states the edition it was built from, and is regenerated from the stored source document — never edited by hand.
- BR-12.6 **The list can be opened and browsed without typing a name.** *(Added after the owner reported, on a phone, never having seen it: as first built it appeared only as suggestions under a name already being typed.)*
- BR-12.7 Several medicines may be ticked and added in one go. Each needs its own price before any is added; none is added with a price the Owner did not type.
- BR-12.8 A medicine already in the pharmacy's catalogue is shown as such in the list and cannot be ticked.
- BR-12.9 Adding a batch is safe to repeat after a failure: a medicine the server accepted is removed from the batch and is not sent again.

**Acceptance criteria:**
- AC-12.1 *Given* an Owner adding a product, *when* they type `amox 500`, *then* "Amoxicillin 500mg capsule" is offered, and picking it fills the name and the unit `capsule`.
- AC-12.2 *Given* a picked medicine, *when* no price has been entered, *then* the product cannot be saved.
- AC-12.3 *Given* a device with no network, *when* the Owner opens the form, *then* suggestions still appear.
- AC-12.4 *Given* a name that is not on the list, *when* the Owner types it and a price, *then* the product is saved as typed.
- AC-12.5 *Given* any medicine picked from the list, *when* it is saved, *then* it is created as a standard (non-controlled) product.
- AC-12.6 *Given* an Owner on Stock, *when* they tap add, *then* the medicines list is offered before the blank form; *given* a shop with no products, *then* it is offered on the screen itself.
- AC-12.7 *Given* the list is open and nothing is typed, *then* every medicine on it can be reached by scrolling.
- AC-12.8 *Given* three ticked medicines, *when* one has no price, *then* none can be added; *when* all three are priced and confirmed, *then* three products exist with the list's names and units and the typed prices.
- AC-12.9 *Given* the connection fails after the first of three, *when* the Owner confirms again, *then* exactly the other two are added.

---

### FR-13 — Barcode scanning · Priority: M · V2
**Actors:** Pharmacist/Cashier (scan to sell, scan to receive); Owner, Branch Manager (link barcodes).
**Preconditions:** a phone with a camera; products defined (FR-3). Design: ADR-031.

**Main flow (sale):**
1. The Cashier taps scan and points the camera at a box.
2. The system finds the product that carries that barcode, on the device, and adds it to the sale exactly as selecting it would (FR-4).
3. The scanner stays open for the next box.

**Alternate flows:**
- 13a. **Linking.** An Owner or Branch Manager opens a product and scans a box; the barcode is recorded against the product and reaches every terminal on its next sync. A barcode may be unlinked.
- 13b. **Receiving.** At goods receipt (FR-7), scanning a box selects its product; where the code is a GS1 DataMatrix, its batch number and expiry date are entered into the receipt line for the user to confirm.

**Exception flows:**
- E-13.1 Unknown barcode: the system says so and adds nothing. The product can still be found by name.
- E-13.2 No camera, or permission refused: the system says so; every screen that offers a scan still accepts typing.
- E-13.3 Offline: scanning to sell and to receive work against the links the terminal last pulled. Linking needs a network.

**Business rules:**
- BR-13.1 A scan is matched **on the device**; the network is never on the path of a sale (NFR-1).
- BR-13.2 A barcode is stored and compared in **one canonical form**: a GTIN as 14 digits, so the EAN-13 on a box and the GTIN in its DataMatrix are the same barcode.
- BR-13.3 Within a pharmacy, **a barcode identifies exactly one product.** Linking one that another product carries is refused, naming that product.
- BR-13.4 An unknown barcode never resolves to a similar one.
- BR-13.5 Linking and unlinking require `catalog.manage` (AC-2.1) and are recorded in the audit log.
- BR-13.6 A scanned sale obeys every rule of a selected one: FEFO (AC-3.2), expired-stock warning (E-4.2), and the refusal of controlled substances while dispensing is switched off (ADR-024).
- BR-13.7 A batch number and expiry read from a code are **proposed, not saved**: the user sees them before the receipt line is added. An unreadable field is left empty, never guessed.
- BR-13.8 Camera frames are processed on the device and are not stored or transmitted.

**Acceptance criteria:**
- AC-13.1 *Given* a product linked by scanning the EAN-13 on its box, *when* a Cashier scans that box, *then* the product is added to the sale at its price.
- AC-13.2 *Given* the same product, *when* the GS1 DataMatrix on the box is scanned instead, *then* the same product is added.
- AC-13.3 *Given* an offline terminal, *when* a Cashier scans a linked box, *then* the product is added.
- AC-13.4 *Given* a barcode linked to product A, *when* an Owner tries to link it to product B, *then* it is refused with A's name and B is unchanged.
- AC-13.5 *Given* a barcode no product carries, *when* it is scanned at the till, *then* nothing is added and the Cashier is told.
- AC-13.6 *Given* a Cashier, *when* they open a product, *then* they are offered no way to link or unlink a barcode, and the API denies the attempt.
- AC-13.7 *Given* a delivery box with a GS1 DataMatrix, *when* it is scanned at goods receipt, *then* the product, batch number and expiry are filled in and the line is not saved until the user adds it.
- AC-13.8 *Given* two pharmacies, *when* each links the same barcode, *then* both succeed and neither can see the other's link.
- AC-13.9 *Given* a terminal on the previous contract version, *when* it syncs, *then* it pulls its catalogue unchanged.

---

### FR-14 — Receipts on paper and on the phone · Priority: M · V2
**Actors:** Pharmacist/Cashier.
**Preconditions:** a sale has just been committed (FR-4). Design: ADR-032.

**Main flow:**
1. After a sale, the receipt screen offers **Share** and **Print**.
2. Share hands the receipt, as text, to the phone's share sheet (SMS, Telegram, and so on).
3. Print lays the receipt out as a page and hands it to the phone's print system.

**Exception flows:**
- E-14.1 Sharing or printing fails: the user is told the receipt could not be sent and that the sale is saved; the next sale is not held up.
- E-14.2 No printer is available: the phone's print system offers saving as PDF.

**Business rules:**
- BR-14.1 A receipt states exactly what the sale recorded: each line in the unit it was sold in (FR-11), the committed totals, the tender, and for cash the amount received and the change. No figure is recomputed for display (G4).
- BR-14.2 The shared text and the printed page are rendered from one description of the sale and cannot differ in content.
- BR-14.3 A receipt is in the language the terminal is set to, with the date in the Ethiopian calendar and the Gregorian date beside it (FR-10).
- BR-14.4 Producing a receipt needs no network of the app's own.
- BR-14.5 A receipt failing never affects the sale it describes (BR-4.1).
- BR-14.6 A receipt names the shop, the sale reference and the cashier's first name. It carries nothing about the customer, and makes **no claim to be a fiscal document** — see ADR-032 §6.
- BR-14.7 *(Scope.)* Direct Bluetooth thermal printing is **not** part of this requirement as built; it is a separate item (ADR-032 §4).

**Acceptance criteria:**
- AC-14.1 *Given* a completed sale of 2 boxes at 100.00 and 10 tablets at 5.00, *when* the Cashier shares the receipt, *then* the text shows both lines with their arithmetic and a total of 250.00 ETB.
- AC-14.2 *Given* a cash sale, *when* the receipt is produced, *then* it shows the cash received and the change; *given* a non-cash sale, *then* it shows neither.
- AC-14.3 *Given* a terminal set to Amharic, *when* the receipt is printed, *then* its labels are in Amharic and legible (not substitute boxes).
- AC-14.4 *Given* a receipt longer than one sheet, *when* it is printed on cut paper, *then* it continues on a further sheet.
- AC-14.5 *Given* sharing fails, *when* the Cashier is told, *then* the message says the sale is saved and a new sale can be started at once.
- AC-14.6 *Given* an offline terminal, *when* a sale completes, *then* the receipt can be shared and printed.

---

### FR-15 — On-device backup and restore · Priority: M · V2
**Actors:** Owner, Branch Manager.
**Preconditions:** signed in on the terminal. Design: ADR-033.

**Main flow (backup):**
1. The user opens Backup & restore, which shows how many operations exist only on this terminal and when a backup was last made.
2. The user chooses a passphrase, entered twice.
3. The system writes one encrypted file and hands it to the device's share sheet, for the user to keep somewhere other than the terminal.

**Main flow (restore):**
1. The user picks a backup file.
2. The system shows which branch it is a backup of, when it was made, and how many unsynced operations it holds, then asks for the passphrase.
3. The system adds to the terminal whatever the file holds that the terminal lacks, and queues the unsynced operations for the next sync.

**Exception flows:**
- E-15.1 Wrong passphrase, or a file altered since it was made: refused; nothing on the terminal changes.
- E-15.2 A file from another pharmacy or another branch: refused before a passphrase is asked for, naming the branch.
- E-15.3 Not a backup, damaged, or made by a newer version: refused, each with its own message.

**Business rules:**
- BR-15.1 A backup contains every operation not yet acknowledged by the server, together with the records they describe, as they were at one instant.
- BR-15.2 A backup is encrypted with a passphrase of at least eight characters. Nothing in it that identifies a sale, a product or a member of staff is readable without the passphrase. **There is no recovery of a forgotten passphrase.**
- BR-15.3 **A restore only adds.** It never removes, replaces or alters anything already on the terminal, including the terminal's own unsynced operations.
- BR-15.4 A restore is idempotent: restoring the same file again adds nothing, and an operation the server has already applied is not applied twice (AC-9.2).
- BR-15.5 Restored operations keep their relative order.
- BR-15.6 A restore never changes reference data (catalogue, prices, stock mirrored from the server).
- BR-15.7 A backup can be restored only on a terminal signed in to the same pharmacy and the same branch.
- BR-15.8 A restore either completes or leaves the terminal exactly as it was.
- BR-15.9 Backup and restore remain available past the offline ceiling (BR-2.3).
- BR-15.10 Backup and restore need no network.

**Acceptance criteria:**
- AC-15.1 *Given* a terminal with five unsynced sales, *when* it is backed up and the file restored on a fresh terminal, *then* the five are queued there in the same order and sync exactly once.
- AC-15.2 *Given* a terminal with three unsynced sales of its own, *when* a backup holding two others is restored on it, *then* all five are queued and its own three are unchanged.
- AC-15.3 *Given* a restored file, *when* it is restored again, *then* nothing is added.
- AC-15.4 *Given* a wrong passphrase, *when* a restore is attempted, *then* it is refused and the terminal is unchanged.
- AC-15.5 *Given* a backup file, *when* its bytes are inspected, *then* no product name, sale identifier or staff identifier appears in them.
- AC-15.6 *Given* a backup of branch A, *when* a restore is attempted on a terminal in branch B, *then* it is refused, naming A.
- AC-15.7 *Given* a Cashier, *when* they open Settings, *then* Backup & restore is not offered.
- AC-15.8 *Given* an Owner on a terminal past the offline ceiling, *when* they open Settings, *then* Backup & restore is offered.

---

### FR-16 — Customer credit ledger (ዕዳ) · Priority: M · V2
**Actors:** Pharmacist/Cashier, Branch Manager, Owner.
**Preconditions:** authenticated; offline-capable. Design: ADR-034.

**Main flow (selling on credit):**
1. At payment, the Cashier chooses **On credit** and picks the customer who will owe — or opens a new account for them.
2. The Cashier enters what, if anything, is paid now. The rest goes on the customer's account.
3. The sale commits locally and is queued, like any sale (FR-4). Stock decrements as usual.

**Main flow (collecting):**
1. The user opens Customers & credit: every customer, what each owes, and the total.
2. The user opens a customer and records a payment — the amount and whether it was cash.
3. The customer's balance falls by that amount.

**Exception flows:**
- E-16.1 Offline: opening an account, selling on credit and taking a repayment all work against local state.
- E-16.2 A repayment of more than is owed is accepted; the customer is shown as paid ahead.
- E-16.3 Cash is taken against a debt with no till open: recorded, with a warning that no cash-up will expect it.

**Business rules:**
- BR-16.1 A sale on credit names the customer who owes it. Credit owed by nobody is refused, on the device and at the API.
- BR-16.2 For a sale with credit, what was paid now plus what is owed equals the sale total, in integer santim (G4).
- BR-16.3 **What a customer owes is exactly their credit purchases less their repayments.** The stored balance is recomputable from those records and must equal them.
- BR-16.4 A credit sale or a repayment is applied exactly once, however often it is sent (AC-9.2).
- BR-16.5 A customer and their balance belong to the pharmacy, across all its branches, and to no other pharmacy.
- BR-16.6 A terminal shows the server's balance plus its own unsynced credit sales and repayments. Receiving a newer server balance never removes an unsynced entry, and an acknowledged entry is never counted twice.
- BR-16.7 **Cash received against a debt during a shift is part of that shift's expected cash; the credit part of a sale is not** (BR-8.2).
- BR-16.8 Credit is reported apart from cash and from other tender; it is never presented as money received.
- BR-16.9 A customer record holds a name and, optionally, a phone number and a note. It holds nothing about health or treatment, and a sale is linked to a customer only when part of it is owed.
- BR-16.10 A sale is never refused because a customer already owes, and there is no credit limit. *(Reading recorded here: the backlog asks to "track and recover debt", not to police it. A limit that blocks is a lost sale; if one is wanted later it should warn, as an oversell does.)*
- BR-16.11 Anyone permitted to sell may sell on credit and record a repayment; each is recorded with the user who did it. *(Reading recorded here: no new capability, so the FR-2 matrix is unchanged.)*
- BR-16.12 A terminal creates customers; it does not edit them.

**Acceptance criteria:**
- AC-16.1 *Given* a sale of 45.00 with 20.00 paid now, *when* it is completed on credit for a customer, *then* the customer owes 25.00 more and the sale's payments total 45.00.
- AC-16.2 *Given* a customer owing 45.00, *when* a repayment of 20.00 is recorded, *then* they owe 25.00; *when* 50.00 is recorded instead, *then* they are 5.00 ahead.
- AC-16.3 *Given* an offline terminal, *when* a new customer is created and sold to on credit, *then* both are queued in that order and both apply on reconnect.
- AC-16.4 *Given* a credit sale and a repayment, *when* either is pushed twice, *then* the balance moves once.
- AC-16.5 *Given* two terminals syncing credit sales for one customer at the same moment, *when* both complete, *then* the balance equals the sum of both and no sale is rejected.
- AC-16.6 *Given* a shift with a cash sale, a part-credit sale and a cash repayment, *when* the till is counted, *then* expected cash is the float plus the cash from both sales plus the repayment, on the terminal and on the server alike.
- AC-16.7 *Given* a server balance and unsynced local entries, *when* a newer server balance is pulled, *then* the local entries are still included; *when* they are acknowledged and pulled, *then* they are included once.
- AC-16.8 *Given* two pharmacies, *when* one attempts to sell on credit to, or record a repayment against, the other's customer, *then* it is rejected and the customer's balance is unchanged.
- AC-16.9 *Given* a sales summary, *when* a sale was partly on credit, *then* the credit part is reported separately and cash + other tender + credit equals gross.
- AC-16.10 *Given* a terminal on the previous contract version, *when* it syncs cash sales, *then* they apply unchanged.

---

### FR-17 — Audit trail and end-of-day summary on the owner's phone · Priority: M · V2
**Actors:** Owner; Branch Manager (summary only, own branch).
**Preconditions:** authenticated; online. Design: ADR-035.

**Main flow (summary):**
1. The user opens Today's summary. The system shows, for the shop's own day: sales with cash, other tender and credit apart; each till with who ran it and whether it balanced; what is owed and what was repaid; what is running low, expiring or oversold; and how many price changes, write-offs and expired sales occurred.
2. The user may switch to yesterday, and may share the summary as text.

**Main flow (audit trail):**
1. The Owner opens the Activity log: who did what, newest first, as sentences.
2. The Owner may narrow it to prices, stock or staff, or to entries marked as worth a second look.

**Exception flows:**
- E-17.1 Offline: each screen says it needs a connection; neither shows an empty result as though it were the answer.

**Business rules:**
- BR-17.1 Every figure in the summary equals the figure the corresponding report shows for the same period and scope.
- BR-17.2 **A cash shortage is never offset by an overage.** Shortfalls and overages are totalled separately, and each till is listed with its own variance.
- BR-17.3 A till opened in the period and not counted is reported as open.
- BR-17.4 Credit sold is shown apart from money received (BR-16.8).
- BR-17.5 The summary is scoped as the sales summary is: tenant-wide for the Owner, own branches for a Branch Manager, refused to a Cashier.
- BR-17.6 The audit trail is readable by the Owner only, and is read-only (BR-6.x immutability applies).
- BR-17.7 An audit entry names the medicine or the person concerned; it never displays an internal identifier.
- BR-17.8 An audit event type the client does not recognise is still listed.
- BR-17.9 Both screens state how current their data is (BR-8.1).
- BR-17.10 *(Scope.)* The summary is **opened and shared by the user; it is not delivered unprompted.** Push, SMS or bot delivery is not part of this requirement as built (ADR-035 §3).

**Acceptance criteria:**
- AC-17.1 *Given* a day with one till 5.00 short and another 3.00 over, *when* the Owner opens the summary, *then* it reports a shortage of 5.00 and an overage of 3.00, and does not report 2.00.
- AC-17.2 *Given* a day's sales, *when* the summary and the sales summary are requested for the same period, *then* their sales figures are equal.
- AC-17.3 *Given* a till opened and not counted, *when* the summary is opened, *then* it is listed as still open.
- AC-17.4 *Given* a Branch Manager, *when* they open the summary, *then* it covers their own branch only; *given* a Cashier, *then* it is refused.
- AC-17.5 *Given* a price was lowered and another raised, *when* the Owner filters the Activity log to entries worth a second look, *then* only the lowered one is shown.
- AC-17.6 *Given* a stock write-off of a product, *when* the Owner reads its entry, *then* it names the product, the quantity, the reason and who did it.
- AC-17.7 *Given* no connection, *when* either screen is opened, *then* it says a connection is needed.
- AC-17.8 *Given* two pharmacies, *when* one requests its summary, *then* nothing of the other's appears.

---

### FR-18 — Suppliers and what is owed to them · Priority: S · V2
**Actors:** anyone who may receive goods (suppliers, deliveries); Owner, Branch Manager (payments).
**Preconditions:** authenticated. Design: ADR-038. The near-expiry return list by supplier is BR-8a.5 (ADR-036).

**Main flow (a delivery):**
1. On goods receipt the user types or taps the supplier. A name not seen before opens a supplier.
2. The user states whether the delivery is paid on delivery or not paid yet, and if not, how much was paid now.
3. The receipt is committed: stock is credited (FR-7), and the unpaid part is added to what that supplier is owed.

**Main flow (a payment):**
1. The Owner or Branch Manager opens Suppliers: the total owed, and each supplier with what is owed, most first.
2. They open a supplier and record a payment: the amount, and where the money came from — cash from the open till, cash not from the till, or bank/cheque/Telebirr.
3. What is owed falls by that amount.

**Exception flows:**
- E-18.1 Offline: suppliers, deliveries and payments are recorded locally and queued (FR-9).
- E-18.2 No till open: "cash from the open till" is not offered.

**Business rules:**
- BR-18.1 What is owed to a supplier equals what its deliveries left owing less what has been paid to it, exactly, in santim.
- BR-18.2 A delivery cannot leave more owing than it cost, and a delivery left owing names its supplier.
- BR-18.3 Stock from a delivery is available whether or not the delivery has been paid for.
- BR-18.4 A supplier name is matched ignoring case and surrounding spaces; an existing supplier is reused, not duplicated.
- BR-18.5 **Cash paid to a supplier out of an open till is subtracted from that till's expected cash, and shown on the cash-up as its own line.** Cash from elsewhere, and any other tender, affects no cash-up (BR-8.2).
- BR-18.6 Where a till is open, the source of a payment has no default; it is chosen.
- BR-18.7 A payment may exceed what is owed; the supplier is then shown as paid ahead. A supplier paid ahead does not reduce the total owed to others.
- BR-18.8 The figure shown is the server's figure plus what this terminal has recorded and not yet synced, and says when part of it is unsynced.
- BR-18.9 Recording a payment to a supplier is offered to the Owner and Branch Manager only. *(Enforced on the terminal; see ADR-038 §7.)*
- BR-18.10 A supplier and what it is owed are visible only within its tenant.
- BR-18.11 A receipt from a terminal that predates suppliers is a paid delivery with a supplier name and no account.
- BR-18.12 *(Scope.)* Stored purchase orders, invoices with due dates, and expenses other than supplier payments are not part of this requirement as built.

**Acceptance criteria:**
- AC-18.1 *Given* a delivery costing 450.00 marked not paid, *when* it is committed, *then* the supplier is owed 450.00 more and the stock is on the shelf.
- AC-18.2 *Given* the same delivery with 150.00 paid now, *then* the supplier is owed 300.00 more.
- AC-18.3 *Given* a supplier "EPSS" exists, *when* a delivery is received from "epss", *then* it is recorded against the existing supplier.
- AC-18.4 *Given* 450.00 owed, *when* 200.00 is paid, *then* 250.00 is owed; *when* 500.00 is paid instead, *then* the supplier is 50.00 paid ahead.
- AC-18.5 *Given* a till with a 200.00 float and 20.00 of cash sales, *when* 50.00 is paid to a supplier from that till, *then* the cash-up expects 170.00 and lists 50.00 paid to suppliers.
- AC-18.6 *Given* a payment by bank, or in cash not from the till, *then* no cash-up changes.
- AC-18.7 *Given* a till is open, *when* the payment sheet is opened, *then* it cannot be recorded until a source is chosen.
- AC-18.8 *Given* a Cashier, *when* they open a supplier, *then* they see what is owed and are not offered payment.
- AC-18.9 *Given* a delivery and a payment recorded offline, *when* the terminal syncs and pulls, *then* the figure is unchanged and no part of it is counted twice.
- AC-18.10 *Given* the same push is sent twice, *then* the debt, the stock and the payment are each counted once.
- AC-18.11 *Given* two pharmacies, *when* one syncs, *then* it receives none of the other's suppliers and cannot record against them.
- AC-18.12 *Given* a receipt with no supplier account, *when* it is synced, *then* its payload is identical to one from before suppliers existed.

### FR-19 — Retail and wholesale prices · Priority: S · V2
**Actors:** Owner, Branch Manager (set prices); anyone who may sell (choose the tier).
**Preconditions:** authenticated. Design: ADR-037.

**Main flow (setting):**
1. The Owner opens a product's price and enters a wholesale price beside the ordinary one; a pack may be given its own wholesale price.
2. Terminals learn the price on their next sync.

**Main flow (selling):**
1. Where the pharmacy has set any wholesale price, the Sell screen offers Retail or Wholesale.
2. The cashier chooses Wholesale; every line in the basket is priced from the wholesale list.
3. The sale is committed and recorded as a wholesale sale; the receipt says so.

**Exception flows:**
- E-19.1 A unit with no wholesale price on a wholesale sale is charged its ordinary price.
- E-19.2 Offline: the tier and prices last synced are used; the sale is queued as any other (FR-9).

**Business rules:**
- BR-19.1 A product has at most one wholesale price, and each pack at most one; all are whole numbers of santim, set by a user with `catalog.manage`.
- BR-19.2 **A wholesale price is never calculated** — not from the retail price, and not for a pack from the base unit's wholesale price.
- BR-19.3 The tier applies to the whole sale; a sale is either retail or wholesale.
- BR-19.4 On a wholesale sale each line is charged the wholesale price **of the unit sold**, or that unit's ordinary price where none is set (E-19.1).
- BR-19.5 The till returns to retail after each sale.
- BR-19.6 The choice is not offered where no wholesale price exists.
- BR-19.7 Setting, changing or removing a wholesale price is recorded in the audit trail with the price before and after (FR-6, FR-17).
- BR-19.8 A controlled substance has no wholesale price.
- BR-19.9 The sales summary reports the value sold at wholesale as a part of the total, not as a tender.
- BR-19.10 A sale from a terminal that predates price tiers is a retail sale.
- BR-19.11 *(Scope.)* Anyone who may sell may sell at wholesale; the control is the record (ADR-037, Consequences). Per-customer price lists and percentage discounts are not part of this requirement.

**Acceptance criteria:**
- AC-19.1 *Given* a product at 4.00 retail and 3.30 wholesale, *when* ten are sold at wholesale, *then* the sale totals 33.00 and is recorded as wholesale.
- AC-19.2 *Given* a box at 100.00 retail and 85.00 wholesale holding thirty, *when* two boxes are sold at wholesale, *then* the sale totals 170.00 and sixty base units leave stock.
- AC-19.3 *Given* a strip with no wholesale price, *when* it is sold on a wholesale sale, *then* it is charged the strip's ordinary price.
- AC-19.4 *Given* a basket rung up at retail, *when* the cashier switches to Wholesale, *then* every line is re-priced and nothing else about the basket changes.
- AC-19.5 *Given* no product has a wholesale price, *when* the Sell screen is opened, *then* no tier choice is shown.
- AC-19.6 *Given* a wholesale sale was just completed, *when* the next sale is started, *then* it is retail.
- AC-19.7 *Given* an Owner changes a wholesale price, *when* the Activity log is read, *then* it names the product, the old price and the new, and who did it; *given* a Cashier, *then* the change is refused.
- AC-19.8 *Given* a retail sale, *when* it is synced, *then* its payload is identical to one from before price tiers existed.
- AC-19.9 *Given* wholesale and retail sales in a day, *when* the sales summary is requested, *then* it reports the wholesale value separately and the total includes it once.
- AC-19.10 *Given* two pharmacies, *when* one syncs, *then* it receives none of the other's wholesale prices.

### FR-7a — Reorder suggestions · Priority: S · V2
**Actors:** Owner, Branch Manager. **Design:** ADR-036.

**Business rules:**
- BR-7a.1 A product is suggested for reorder when it has sold in the last 30 days and stock on hand covers fewer than 14 days at that rate, including when it has run out.
- BR-7a.2 **A product with no sales in the period is never suggested**, whatever its stock.
- BR-7a.3 The suggested quantity brings stock to 30 days of sales, rounded up to whole packs where the product defines one (FR-11).
- BR-7a.4 Suggestions are ordered most urgent first, and can be shared as a list.
- BR-7a.5 Works with no network, from the terminal's own records, and states that it does.

**Acceptance criteria:**
- AC-7a.1 *Given* a product with 10 on hand that sold 290 in 30 days and has a box of 30, *when* suggestions are shown, *then* it is suggested at 10 boxes.
- AC-7a.2 *Given* a product with 2 on hand and no sales in 30 days, *then* it is not suggested.

### FR-8a — Profit, best-seller and dead-stock reports · Priority: S · V2
**Actors:** Owner, Branch Manager. **Design:** ADR-036.

**Business rules:**
- BR-8a.1 Best sellers are the products sold in the last 30 days, ordered by revenue.
- BR-8a.2 Profit is revenue less the cost of what was sold, where cost is the average the terminal has received the product at. It is computed in integer santim, divided once (G4), and **presented as an estimate**.
- BR-8a.3 **A product with no known cost has no profit figure** and is excluded from the profit total; the report states how many were excluded.
- BR-8a.4 Dead stock is a product with stock on hand and no sale for 60 days, that has also been on the terminal's books for 60 days.
- BR-8a.5 Near-expiry stock (within 60 days, or already expired) is listed by the supplier named on its goods receipt, with a value at cost, and each supplier's list can be shared (FR-18, part).
- BR-8a.6 Works with no network, from the terminal's own records, and states that it does.
- BR-8a.7 Controlled substances are excluded from all of these.

**Acceptance criteria:**
- AC-8a.1 *Given* 300 capsules received for 900.00 and 65 sold for 220.00, *then* cost of sales is 195.00 and profit 25.00.
- AC-8a.2 *Given* a product sold but never received on the terminal, *then* it shows "cost not known" and the profit total does not include its revenue.
- AC-8a.3 *Given* stock received 7 days ago and not yet sold, *then* it is not dead stock.
- AC-8a.4 *Given* two batches near expiry from two suppliers, *then* each appears under its own supplier with its value at cost.

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
| FR-1 tenant/branch + **onboarding, billing, subscriptions** | §5.1, §5.8 | `api/src/modules/billing/`, `api/src/common/auth/{subscription.guard,platform-admin.guard,tenant-status.guard,tenant-status}.ts`, `api/src/modules/billing/signup.service.ts`, `api/src/migrations/1759500000000-TenantDeactivation.ts` · platform console: `dashboard/src/console/` · owner side: `mobile/lib/ui/{subscription_screens,request_account_screen,branch_picker_screen}.dart` | `g1-tenant-isolation.spec.ts`, `g1-subscription-suspension.spec.ts` (15), `g1-signup-requests.spec.ts` (5), `g1-tenant-deactivation.spec.ts` (14), `g1-payment-proof-storage.spec.ts` (7), `g2_account_deactivation_test.dart` (6), `dashboard/test/console.spec.tsx`, `dashboard/test/deactivation.spec.tsx` | **Done** — Platform Admin as a separate identity (BR-2.2), manual screenshot verification (Vision §4), BR-1.3 suspension as interpreted by ADR-016, the prototype's sign-up request gate (ADR-022), and forced deactivation for a policy breach (ADR-025): every request refused, offline sign-in wiped, nothing deleted. AC-1.1's first branch is created on the phone. |
| FR-2 (+ matrix) | §8, §5.1 | **matrix: `packages/contracts/src/permissions.ts`** (generated into Dart) · enforcement: `api/src/common/auth/{capability.guard,branch-scope}.ts`, `api/src/modules/admin/` · client: `mobile/lib/core/permissions.dart` | `g1-permission-matrix.spec.ts` (21), `permissions_test.dart` (11), `g1-report-scoping.spec.ts` (17), `offline_credentials_test.dart` (7) | **Done** — every role × capability cell tested at both layers (`05-qa` §10); AC-2.1 verified on both. **AC-2.2 built 2026-09-26** (ADR-023): it had been counted as met by a surviving session, but after a sign-out nobody could sign back in without a network. Platform-Admin capabilities are declared and denied to every tenant role; their own surface is the platform console (`dashboard/src/console/` over `/platform/*`), and the route sweep asserts a tenant token cannot reach any of it. |
| FR-3 inventory (FEFO, negative stock, **reconciliation**) | §5.3, §10 | `api/src/modules/inventory/`, `api/src/modules/reporting/stock-report.service.ts`, `mobile/lib/data/{catalog,inventory}_repository.dart`, `mobile/lib/ui/reconcile_screen.dart` | `g5-oversell-detected.spec.ts`, `g5-stock-reconciliation.spec.ts` (12), `g5-expired-dispense.spec.ts` (6), `g5_reconciliation_test.dart` (13), `g5_expired_stock_test.dart` (8), `fefo_test.dart` | **Done** — FEFO, negative stock, BR-3.4 expiry alerting, and BR-3.2's promised **physical reconciliation** (contract v1.2.0). **E-4.2 expired-stock override built** (ADR-020): FEFO still refuses to select an expired batch, but the counter is now warned instead of told there is no stock, `expiry.override` gates the attribution, and the server audits every expired dispense from the batch's own expiry date — authorised or not. |
| FR-4 — POS, standard sale | §5.4 | `mobile/lib/ui/sell_screen.dart`, `mobile/lib/data/sale_repository.dart`, `api/src/modules/sync/sync.service.ts` | `g7_offline_durability_test.dart`, `g2-sync-integrity.spec.ts`, `daily-loop.e2e-spec.ts` (6 journeys) | **Done** — AC-4.1: an offline cash sale is committed locally, queued, and replays exactly once |
| FR-4 — psychotropic dispensing rules | §5.4 | rules: `packages/contracts/src/compliance.ts` (+ Dart mirror `mobile/lib/core/compliance.dart`) · till: `mobile/lib/{data/controlled_repository.dart,ui/dispense_screen.dart}` · server: `api/src/modules/ledger/` | `g5-controlled-ledger.spec.ts`, `g5_controlled_dispense_test.dart`, `packages/contracts/test/compliance.test.ts` | **Built, provisional, switched off (ADR-024).** AC-4.2 and AC-4.3 enforced on the till (offline) and on the server; the numbers are SRS `[ASSUMPTION]` A-1 under `status: 'provisional'`. Not done until A-1 is verified and recorded. |
| FR-4 psychotropic rules | §6.4 | `packages/contracts/src/compliance.ts` | `packages/contracts/test/compliance.test.ts` | **Provisional (ADR-024).** One file holds every number, and a parity test holds the till's copy to it — verification edits one place. |
| FR-6 — event store + **general audit log** | §5.6, §6 | `apps/api/src/migrations/EventStore`, `apps/api/src/modules/audit/` | `g3-ledger-immutability.spec.ts` (13) | **Done** for the non-regulated half (Vision §2.1.1). Append-only enforced by the database — UPDATE, DELETE and TRUNCATE all refused, including for the owner role. |
| FR-6 — controlled-substance ledger | §5.6, §6 | `api/src/modules/ledger/`, `api/src/migrations/1759400000000-ControlledLedger.ts`, `mobile/lib/ui/ledger_screen.dart` | `g5-controlled-ledger.spec.ts`, `g3-ledger-immutability.spec.ts` | **Built, switched off until A-1 (ADR-024).** AC-6.1 (database refuses edit and delete; corrections are compensating events), AC-6.2 (ordered history), BR-6.3 (CSV export marked provisional), BR-3.3 (projection rebuilds exactly from events). With the switch off every controlled operation is rejected and writes nothing. |
| FR-11 sell units (break-bulk) — **V2** | §3, §5.2, §5.4, §5.5; ADR-030 | contract: `packages/contracts/src/entities.ts` (`productPack`, `baseQuantity`) · server: `api/src/migrations/SellUnits`, `api/src/modules/sync/sync.service.ts`, `api/src/modules/admin/management.service.ts` · till: `mobile/lib/data/{sale,inventory,catalog}_repository.dart`, `mobile/lib/ui/{sell_screen,receive_screen,catalog_sheets}.dart` | `g4-sell-units.spec.ts` (30), `g4_sell_units_test.dart` (20), `g7_schema_upgrade_test.dart`, `sell_screen_test.dart`, `packages/contracts/test/contract.test.ts` | **Done** — AC-11.1 to AC-11.7 on both sides: pack sales exact to the santim, stock in base units, oversell by the box detected, a 1.4.0 terminal unchanged (ADR-009), a V1 local database upgraded in place. `itemsSold` in the sales summary counts units as rung up (ADR-030, consequences). |
| FR-12 pre-loaded medicines catalogue — **V2** | — (bundled reference data; the existing product-create path) | source: `docs/regulatory/EFDA-GDL-067-essential-medicines-list-2024.pdf` · build: `scripts/build-medicines-catalogue.py` → `mobile/assets/catalogue/medicines.json` · app: `mobile/lib/data/medicine_catalogue.dart`, `mobile/lib/ui/catalog_sheets.dart`, `mobile/lib/ui/medicines_screen.dart` | `medicine_catalogue_test.dart` (18), `inventory_screens_test.dart`, `medicines_screen_test.dart` (12) | **Done** — 1,315 entries from 490 generics of the 2024 list. AC-12.1 to AC-12.5 at the widget tier; the file itself is tested for size, duplicates, stray footnotes and the absence of any price or controlled flag. **Not covered:** medicines outside the Essential Medicines List (brands, the drug-shop and OTC lists) — typed by hand until those lists are added. |
| FR-13 barcode scanning — **V2** | §5.2; ADR-031 | contract: `packages/contracts/src/entities.ts` (`canonicalBarcode`, `productBarcodes`) · server: `api/src/migrations/ProductBarcodes`, `api/src/modules/admin/management.service.ts` · till: `mobile/lib/core/gs1.dart`, `mobile/lib/ui/scan_screen.dart`, `mobile/lib/ui/{sell_screen,receive_screen,stock_screen}.dart` | `g2-product-barcodes.spec.ts` (19), `gs1_test.dart` (24), `g2_barcodes_test.dart` (5), `barcode_screens_test.dart` (8), `sell_screen_test.dart`, `packages/contracts/test/contract.test.ts` | **Built; the camera is untested.** AC-13.1 to AC-13.9 hold with the camera replaced by a script — matching, canonical form, one-product-per-barcode, tenant isolation, N-1. **What no test here can show** is that a real phone reads a real box: focus, glare, a curved blister pack, a low-end camera. That is a device check, and belongs on the field-UAT list (`engineering/field-uat.md`). **Added:** a barcode can also be read from a picture on the phone, through the same detector and handling (BR-13.x unchanged). |
| FR-14 receipts — **V2** | ADR-032 (no schema or contract change) | `mobile/lib/core/receipt.dart`, `mobile/lib/ui/receipt_output.dart`, `mobile/lib/ui/receipt_screen.dart`, font: `mobile/assets/fonts/` | `receipt_test.dart` (15), `receipt_screen_test.dart` (5) | **Built as scoped; a printer has not been used.** Share-as-text and print-through-the-phone, AC-14.1 to AC-14.6: the text is checked line by line in both languages, and a real PDF is rendered in the tests — including in Amharic, with the font's glyph coverage read from the file. **Not built:** direct Bluetooth thermal printing (BR-14.7, ADR-032 §4). **Not shown by any test:** that a particular printer prints it; that is a field-UAT row. |
| FR-15 backup and restore — **V2** | ADR-033 (no schema, contract or server change) | `mobile/lib/data/backup.dart`, `mobile/lib/ui/backup_screen.dart`, `mobile/lib/ui/settings_screen.dart` | `g7_backup_restore_test.dart` (24), `backup_screen_test.dart` (16) | **Done at the data tier; the file's journey is untested.** AC-15.1 to AC-15.8: restore across two real database files, merge without loss, idempotence, order, wrong passphrase, tampering, wrong branch, plaintext scan, atomicity. **Not shown by any test:** a file actually sent through Telegram and picked back on a second phone — the share sheet and the file picker are the operating system's (`engineering/field-uat.md` §4.5). |
| FR-16 customer credit ledger — **V2** | §5.4; ADR-034 | contract: `packages/contracts/src/entities.ts` (`customerPayload`, `creditPaymentPayload`, `creditPortion`), `packages/contracts/src/sync.ts` (`customerRef`) · server: `api/src/migrations/CreditLedger`, `api/src/modules/credit/`, `api/src/modules/sync/sync.service.ts`, `api/src/modules/cashup/cash-up.service.ts` · till: `mobile/lib/data/customer_repository.dart`, `mobile/lib/data/sale_repository.dart`, `mobile/lib/ui/customers_screen.dart`, `mobile/lib/ui/payment_screen.dart` | `g4-credit-ledger.spec.ts` (31), `g4_credit_ledger_test.dart` (22), `credit_screens_test.dart` (16), `receipt_test.dart`, `packages/contracts/test/contract.test.ts` | **Done** — AC-16.1 to AC-16.10 on both sides: balance equals rows after mixed, replayed and concurrent sequences; cash-up agrees on terminal and server; tenant isolation; N-1. The concurrency test found, and this change fixed, a deadlock that would have parked a legitimate sale (ADR-034 §10). **Not built:** editing or merging customers, a statement across phones, ageing of debts. |
| FR-17 audit trail and daily summary on the phone — **V2** | ADR-035 (read-only; no schema or contract change) | server: `api/src/modules/reporting/daily-summary.service.ts`, `api/src/modules/audit/` · phone: `mobile/lib/core/owner_reports.dart`, `mobile/lib/ui/owner_screens.dart`, `mobile/lib/ui/reports_screen.dart` | `g4-daily-summary.spec.ts` (17), `owner_reports_test.dart` (25), `owner_screens_test.dart` (15) | **Built as scoped.** AC-17.1 to AC-17.8: each summary figure held to the report it restates, shortage never netted, branch and tenant scoping, every audit sentence in both languages. **Not built: unprompted delivery** (BR-17.10) — no push, SMS or bot; that needs accounts and a sender the project does not have (ADR-035 §3). |
| FR-7a reorder suggestions · FR-8a profit, best sellers, dead stock · FR-18 return list — **V2** | ADR-036 (read-only, on the device) | `mobile/lib/data/insights_repository.dart`, `mobile/lib/ui/insights_screen.dart` | `g4_insights_test.dart` (22), `insights_screen_test.dart` (12) | **Done as scoped** — every figure held to the sales and receipts it is made from, with packs. Computed from **this terminal's** records and labelled so; no consolidated figure across terminals. The supplier entity and payables are the FR-18 row; purchase orders as records are not built. |
| FR-19 retail and wholesale prices — **V2** | ADR-037; contract 1.8.0 (ADR-012 §4) | contract: `packages/contracts/src/entities.ts` (`priceTier`, `wholesalePriceSantim`), `packages/contracts/src/sync.ts` · server: `api/src/migrations/PriceTiers`, `api/src/modules/admin/management.service.ts`, `api/src/modules/sync/sync.service.ts`, `api/src/modules/reporting/sales-summary.service.ts` · till: `mobile/lib/data/sale_repository.dart`, `mobile/lib/data/catalog_repository.dart`, `mobile/lib/ui/sell_screen.dart`, `mobile/lib/ui/catalog_sheets.dart`, `mobile/lib/core/receipt.dart` | `g4-price-tiers.spec.ts` (24), `g4_price_tiers_test.dart` (16), `sell_screen_test.dart`, `inventory_screens_test.dart`, `receipt_test.dart`, `owner_reports_test.dart` | **Built as scoped.** AC-19.1 to AC-19.10. The tier is a record, not a control: the server stores the price charged and does not re-price a line (ADR-037 §5). **Not built:** per-customer price lists, a capability restricting who may sell at wholesale. **Not shown by any test:** the widened pack editor on a real 720-pixel phone. |
| FR-18 suppliers and payables — **V2** | ADR-038; contract 1.9.0 (ADR-012 §4) | contract: `packages/contracts/src/entities.ts` (`supplierPayload`, `supplierPaymentPayload`, `receiptCost`), `packages/contracts/src/sync.ts` (`supplierRef`) · server: `api/src/migrations/Suppliers`, `api/src/modules/payables/`, `api/src/modules/sync/sync.service.ts`, `api/src/modules/cashup/cash-up.service.ts` · till: `mobile/lib/data/supplier_repository.dart`, `mobile/lib/data/inventory_repository.dart`, `mobile/lib/data/shift_repository.dart`, `mobile/lib/ui/suppliers_screen.dart`, `mobile/lib/ui/receive_screen.dart` | `g4-suppliers.spec.ts` (30), `g4_suppliers_test.dart` (22), `suppliers_screen_test.dart` (21), `g7_schema_upgrade_test.dart` | **Built as scoped.** AC-18.1 to AC-18.12. **Enforced on the terminal only:** who may record a payment (BR-18.9) — sync does not authorise by operation type. **Not built:** stored purchase orders, invoices and due dates, expenses, merging duplicate suppliers, payables in the daily summary. **Not shown by any test:** a week beside the owner's own invoices. |
| FR-7 goods receipt (base) | §5.5 | `api/src/modules/sync/sync.service.ts` (`applyGoodsReceipt`), `inventory.service.ts` (`applyReceipt`), **`mobile/lib/ui/receive_screen.dart`** | `g7-offline-resilience.spec.ts`, `g5_reconciliation_test.dart` | **Done** — the counter can now record a delivery offline, and the shelf is credited immediately. |
| FR-8 reporting + cash-up | §5.4, §9 | cash-up: `api/src/modules/cashup/`, `mobile/lib/{data/shift_repository.dart,ui/cash_up_screen.dart}` · reports: `api/src/modules/reporting/{sales-summary,stock-report}.service.ts`, `mobile/lib/ui/{home_screen,reports_screen}.dart` | `g4-cash-up.spec.ts` (12), `g4_cash_up_test.dart` (10), `g1-report-scoping.spec.ts` (17) | **Done** — AC-8.1 cash-up, AC-8.2 consolidated + per-branch summary, BR-3.4 expiry alerting. Controlled-substance ledger report awaits Phase 2. |
| Platform console client (T2/T3) | `05-qa` §3 | `dashboard/src/lib/{api,format}.ts`, `dashboard/src/console/` | `dashboard/test/` — 38 tests: request headers and the contract version, `ApiError` status preservation, `isSessionExpired` against anything throwable, session storage under private browsing | **Done** — the console renews its session rather than signing the owner out every fifteen minutes (ADR-019), and identifies its browser with a real per-device UUIDv7 instead of one constant shared by every install. §3 puts the dashboard API at T2 (≥80% line) and it had **no tests at all**; the two that existed covered pure formatting helpers. Since 2026-09-24 the web app is the platform console only, as the prototype draws it (screens 20–26); the tenant pages it once had were never in the design and moved to the phone. `test/console.spec.tsx` pins its navigation, and the proof screenshot is fetched with the platform token rather than followed as a bare link the guard refused. |
| FR-9 single-writer sync | §7, §10 | `api/src/modules/sync/`, `mobile/lib/{sync,data/outbox.dart}` | `api/test/guardian/g2-sync-integrity.spec.ts`, `mobile/test/guardian/g2_sync_integrity_test.dart`, `daily-loop.e2e-spec.ts` | **Done** for the single-writer tier — AC-9.1 asserted at the 200 transactions the criterion names, AC-9.2 idempotent on replay. The *trigger* was untested and missing: nothing synced unless someone pressed a button or changed screens, so step 2's "on connectivity… (background)" was not met. The counter now syncs after each commit, every 30 s, and on resume (`sell_screen_test.dart`, found on a device 2026-09-24). Multi-writer + conflict engine is V2 by ADR-002, not a gap |
| Sync contract anti-drift | `05-qa` §6, ADR-009/010 | single source of truth in `packages/contracts/src/`, generated into Dart and TS; `ZodValidationPipe` on every request | `g2-contract-conformance.spec.ts` (5, **provider half**), codegen-freshness CI job, `calendar.spec.ts` | **Done** — §6 asks for both halves validated. Requests were; responses were only *typed*, and TypeScript is erased at runtime. Real responses are now parsed with the same schemas the Dart types are generated from |
| FR-10 localization | §3 | calendar: `packages/contracts/src/ethiopian-calendar.ts` + `mobile/lib/core/ethiopian_date.dart` (two implementations, one shared vector table) · strings: `mobile/lib/l10n/` | `ethiopian_date_test.dart` (19), `strings_test.dart` (7), `calendar.spec.ts` (16), `g4-utc-storage.spec.ts` (5) | **Done** — AC-10.1 Amharic + Ethiopian calendar, AC-10.2 UTC storage asserted at the schema level. The in-app user guide (`mobile/lib/l10n/help_content.dart`, `mobile/lib/ui/help_screen.dart`) is bilingual by the same rule, held by `help_content_test.dart` (every topic and step in both languages) and `help_and_payment_test.dart`; it opens from the sign-in screen, before any session exists. Corrected 2026-09-24 after a device run: the stock screens, sync chip and expired-stock dialog were English-only (the strings were tested, the screens were not — now `inventory_screens_test.dart` renders them in Amharic), and every expiry date displayed a day early in UTC+3 because a calendar date was read as an instant (`Strings.calendarDate`; CI now runs the mobile suite in the Addis Ababa time zone) |
| Screens & views (T3) | `05-qa` §3 | `mobile/lib/ui/`, `dashboard/src/console/` | `mobile/test/widget/` (36), `dashboard/test/console.spec.tsx` (3) | **Done** — rebuilt to `docs/prototype/index.html` on 2026-09-24 (mobile screens 01–19, web 20–26). §3 asks for widget tests on stateful UI, and these pin what is only visible on screen: sync triggers, the offline ceiling, the controlled refusal, the expired-stock warning and who may authorise it, the live cash-up variance, the sync chip telling an ended session apart from an outage, and the uniform login errors. Controlled dispensing and the ledger (screens 11, 17) stay behind A-1. |
| Client primitives (T1/T2) | `05-qa` §3, ADR-006 | `mobile/lib/core/ids.dart`, `mobile/lib/l10n/locale_store.dart` | `ids_test.dart` (4), `locale_store_test.dart` (5) | **Done** — `newId()` is asserted against the **same regex the server validates with**, so a Dart–TypeScript divergence fails here rather than as a queue that cannot drain after a day offline; version-7 and time-ordering are pinned because a swap to v4 would work perfectly and silently cost the property ADR-006 rests on. |
| NFR-1 offline window | §7, §8 | `mobile/lib/data/local_db.dart` (+ corruption quarantine, ADR-018), `outbox.dart`, `auth/offline_window.dart` | `g7_offline_durability_test.dart`, `g7_offline_window_test.dart` (6), `g7_chaos_test.dart` (7), `g7-offline-resilience.spec.ts`; field UAT is the release gate | **Done** — durability, the authority ceiling and `docs/05` §7's full chaos list; the 72h backlog replays in 3.4 s |
| NFR-3.2 local op < 100 ms | §7 | single local transaction, no network on the sale path | `g7_local_latency_test.dart` (percentile regression guard, CI) + `integration_test/nfr3_local_latency_test.dart` (**on-device**, `scripts/device-matrix.sh`) | Partial — harness built and CI guard tight; the device figure needs a handset (`engineering/device-matrix.md`, GA gate) |
| NFR-3.3 sync < 10s after 72h | §7 | `api/src/modules/sync/`, 2 MB body limit derived from the contract cap | `test/perf/nfr3.perf-spec.ts` | **Met** — 3.4 s for 186 ops |
| NFR-3.4 API p95 | §7, §9 | one query per report; lateral aggregates, no N+1 | `test/perf/nfr3.perf-spec.ts` + `nfr3-concurrency.perf-spec.ts` | **Met** — sequential: sync 33 ms / 500, dashboard ≤ 36 ms / 1000. **Under concurrency** (8 tenants at once): 210 ms / 500. Budget holds; margin narrows from ~15x to ~2.4x, which is the figure to re-measure on hosted staging |
| NFR-3.1 1,000 tenants | §7, §9, ADR-003 | per-tenant change sequence; an index behind every tenant predicate; JWT key built once (`api/src/modules/auth/auth.module.ts`); idle terminals pull every 2 min (`mobile/lib/ui/terminal.dart`) | `nfr3-1-thousand-tenants.perf-spec.ts`, `nfr3.perf-spec.ts`, `nfr3-concurrency.perf-spec.ts` | **Met on the production-like stack (2026-09-26).** 1,000 tenants seeded; each syncs a sale (push + pull) inside a 30 s window — a peak minute at 2× — with the load generator in the same process: push p95 339 ms, pull p95 169 ms (budget 500). At saturation (100 always in flight) every sale still applies exactly once and no tenant sees another's rows. Found on the way: the JWT library rebuilt its key on every request (~1.1 ms each); fixed. Hosted-region latency is staging's to add. |
| NFR-4.1 tenant isolation | §8, ADR-003/007 | `api/src/common/db/scoped-db.service.ts`, RLS policies in `InitialSchema`, `common/auth/jwt-auth.guard.ts` | `g1` suite + `g1-cross-tenant-route-sweep.spec.ts` (50) + `no-unscoped-access.spec.ts` | **Done** — every route the app serves is attempted across the boundary, and a route nobody has classified fails the sweep |
| NFR-4.2 credentials + rate limiting | §8, ADR-017/019 | `api/src/modules/auth/{login-throttle,auth}.service.ts`, `migrations/LoginAttempts`, `common/auth/jwt-auth.guard.ts`, `mobile/lib/auth/{session,offline_window}.dart` | `g1-login-throttling.spec.ts` (7), `g1-token-lifecycle.spec.ts` (16), `g7_offline_window_test.dart` (10), `g2_session_continuity_test.dart` (5) | **Done** — throttled never locked out; token expiry **and purpose** enforced in both directions; a refresh re-reads authority so a deactivated user cannot renew; offline cache tested at the window boundary (`05-qa` §10) |
| NFR-4.3 transport + response headers | §8, ADR-026 | TLS at the platform edge plus an app-level HTTPS rule, headers and rate limits in `api/src/common/http/security.ts`; release phone builds refuse `http://` (`mobile/lib/core/api_endpoint.dart`) | `g1-http-security.spec.ts` (19), `api/test/unit/security.spec.ts`, `api_endpoint_test.dart` (4); `scripts/smoke.sh` | **Done** — the full checklist and what holds each item: `engineering/security.md` |
| NFR-4.4 platform admin least-privilege | §8, BR-2.2 | `common/auth/platform-admin.guard.ts`, `modules/billing/platform-auth.service.ts` | `g1-cross-tenant-route-sweep.spec.ts` — both directions | **Done** — a platform token is refused by every tenant route and a tenant token by every platform route |
| NFR-6 localization & usability | §3, §5.4 | Amharic + Ethiopian calendar via FR-10; counter speed via a local-first sale path (NFR-3.2) and PIN login | `ethiopian_date_test.dart` (19), `strings_test.dart` (7), `g7_local_latency_test.dart`, `cash_up_screen_test.dart` (5), `pos_screen_test.dart` (8) | **Done** — the localization half is FR-10's row; the usability half is the counter path: a sale commits locally with no network on its critical path, and the screens are covered at T3. |
| NFR-7 maintainability & observability | §5.7 | `api/src/common/observability/` — a global interceptor for successes, an exception filter for refusals (guards run before interceptors), and domain signals from sync and inventory | `g1-telemetry-leaks-nothing.spec.ts` (6) | **Done** for the emitting half: all four signals `engineering/runbook.md` §2 watches are written as structured JSON on stdout, and a guardian asserts no PIN, rejected PIN or bearer token ever appears in one. Collector and thresholds need hosting (`06` §11). |
| NFR-5 retention | §5.6, §5.8 | no `DELETE` grant to the app role (the one exception, `login_attempt`, is operational telemetry and holds no tenant data); `deleted_at` on every tenant-scoped table, enforced by the docs/04 §2 column check in CI | `g3-ledger-immutability.spec.ts` — the event log refuses UPDATE, DELETE and TRUNCATE even for the owner role | Partial — **the mechanism is built and enforced; no duration is configured.** NFR-5.1's 7 years and NFR-5.2's 10 are both `[ASSUMPTION]`, and ADR-015 is explicit that no retention default ships until A-1 clears: a guessed number in a regulated system reads as a verified one. Nothing is hard-deleted meanwhile, so no record can be lost while the figure is unknown. |

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
