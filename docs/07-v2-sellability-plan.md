# 07 — V2: the sellability release

**Status:** ✅ Draft · owner: Bina
**Depends on:** `01-vision-and-scope.md`, `02-srs.md`, `06-delivery-plan.md`, ADR-029
**Input:** [`v2-sellability-backlog.md`](v2-sellability-backlog.md) — the review of the shipped
v1.0.0 APK, kept verbatim. This document is that backlog checked against the code and turned
into requirements and an order of work.

---

## 1. What V2 is for

V1 proved the spine: a sale is never lost, offline, across a power cut. It did not make the
app something an owner can run **instead of** what they already have. Today an owner who
installs PharmaEt still types every drug name, still keeps a receipt machine, and still runs a
paper credit book. That is a second system, and nobody pays monthly for a second system.

**V2's test for every item: does it let the owner throw an old tool away?** Each requirement
below must reduce the owner's work, make or save them money, or make them feel in control. An
item that only adds data entry does not ship.

V1's principles (`01` §6) are unchanged and still outrank every feature here: the daily loop
never breaks, nothing regulated is lost, and every write at the counter works offline.

---

## 2. The backlog, checked against the code

The backlog was written from the APK. These are its claims read against the repository on
2026-10-07 — where it was right, and where the code says something different.

| Backlog claim | What the code says | Consequence |
|---|---|---|
| P0-5: "one `unit` per product — verify whether buy-unit vs sell-unit conversion exists" | **It does not exist.** `product.unit` is a label; every quantity on a sale line, a receipt line and a batch is an integer count of that one unit (`04` §3). Receiving 5 boxes of 100 means typing 500; selling a box at a box price that is not a multiple of the tablet price cannot be recorded at all, because `lineTotal = qty × unitPrice` is asserted in the contract and the database. | The backlog's "most important P0" is real. **FR-11, built first.** |
| "No customer table exists" | Correct. `01` §2.3 lists the credit ledger as a non-goal "to be reconsidered". | ADR-029 reverses that non-goal. FR-16. |
| "Goods receipt stores only a supplier *name*" | Correct — `goods_receipt.supplier_name`, free text; the contract comment says "a supplier entity is deferred". | FR-18. |
| "`print` is unsupported and the app can't even request Bluetooth" | Correct. The receipt screen has a print button with nothing behind it; the manifest declares only `INTERNET`. `share_plus` is already a dependency, so sharing a receipt is cheap. | FR-14. |
| "Reports need the internet every time" | Correct. `reports_screen.dart` reads `/reports/*`; only a cashier's "today on this device" figure is local. | FR-8a reports are computed from local data first. |
| "An audit log the owner can read" is missing | **Half true.** The log exists, is immutable, and is served by `GET /audit` (ADR-015). There is no screen for it on the phone. | FR-17 is a screen, not a subsystem. |
| "The app already flags stock expiring within 60 days" | Correct (`CatalogRepository.attention`). No supplier link, so no return list yet. | FR-18 builds on FR-3. |
| "One free-tier Render instance abroad" | Correct, and recorded as a deliberate starting point with an upgrade path (ADR-027). | An owner decision about money, not an engineering one — §6. |
| "Already localized to Amharic"; "transfer + proof subscription is deliberate" | Both correct. | Untouched. |

---

## 3. V2 requirements

New requirements take the next free identifiers; nothing is renumbered (`README.md`
conventions). Each is specified in `02-srs.md` — with acceptance criteria and an RTM row —
**when it becomes ready to build**, not before, so the SRS never carries a requirement nobody
has thought through.

### 3.1 P0 — the counter (no confident sale without these)

| Id | Requirement | Throws away | Touches a controlled artifact? |
|---|---|---|---|
| **FR-11** | **Sell units (break-bulk).** A product defines packs — strip of 10, box of 100 — each with its own price. Stock stays in the base unit; receiving and selling may be done in any defined unit. | The mental arithmetic, and the wrong stock counts that follow from it | **Yes** — sale and receipt lines (sync envelope), `product` |
| **FR-12** | **Pre-loaded medicines catalogue.** EFDA's published lists ship inside the app; adding a product is picking from the list and setting a price. | Typing the catalogue on day one | No — bundled reference data, and the existing product-create path |
| **FR-13** | **Barcode scanning** with the phone camera (EAN/GTIN and GS1 DataMatrix), at sale and at receipt. A product carries its barcodes; a DataMatrix also yields lot and expiry at receipt. | Typing drug names all day | Yes — `product` gains barcodes (pull payload) |
| **FR-14** | **Receipts on paper and on the phone.** Bluetooth thermal printer, A4/PDF, and share (SMS, Telegram, anything) from the receipt screen. | The old receipt machine | No |
| **FR-15** | **Backup and restore on the device.** One tap writes an encrypted backup file to the owner's own storage; restore brings back a lost phone's unsynced work. | The fear of losing the shop with the phone | No — but it handles the local database, so it gets guardian tests under G7 |

### 3.2 P1 — money and trust (why they keep paying)

| Id | Requirement | Why | Controlled? |
|---|---|---|---|
| **FR-16** | **Customer credit ledger (ዕዳ).** Customers, credit sales, repayments, balance owed. | Recovering debt is money the owner can see | Yes — new synced entities, a `credit` tender |
| **FR-17** | **The audit trail and an end-of-day summary on the owner's phone.** Who voided, who changed a price, who adjusted stock; and one daily line — sales, cash counted, shortage, low stock, who was on shift. | Staff theft is the owner's first anxiety | No — reads what ADR-015 already records |
| **FR-18** | **Suppliers.** A supplier entity, what is owed to each, and the near-expiry **return-for-credit** list grouped by supplier. Purchase orders follow. | Money back on stock that would be binned | Yes — goods receipt gains a supplier id |
| **FR-7a** | **Reorder suggestions** (was "usage-based ordering", un-deferred by ADR-029). A list of what is low against what sells. | Stock-outs are lost sales | No |
| **FR-8a** | **Profit, best-seller and dead-stock reports** (un-deferred), computed on the device from local data, with the server's consolidated figure when online. | Shows where the money is, every month, at renewal | No |
| **FR-19** | **Price tiers.** A retail and a wholesale price per product; the cashier picks the customer type, not the price. | No mental arithmetic for clinics and organisations | Yes — `product`, sale line |
| **FR-20** | **CBHI insured-sale capture and claim export.** Tag a sale as insured; export a claim-ready summary. Export only — no insurer API. | Faster reimbursement | Yes — sale payload |

### 3.3 P2 — after P0 and P1 have landed

Recorded so they are not re-proposed as new ideas, not scheduled: EFDA track-and-trace event
reporting (builds on FR-13); e-invoice readiness under Directive 1142/2026, when the Ministry
of Revenue publishes a schedule; a dispensing reference (interactions, substitution) sourced
from FR-12's data; FR-5 inter-branch transfer with a consolidated owner view; refill
reminders (builds on FR-16); Fayda ID on controlled dispensing.

Two of these are regulatory and inherit V1's rule: nothing load-bearing is built on an
unverified reading of a directive. Track-and-trace and e-invoicing each need the same kind of
verification A-1 does before they are more than an export.

### 3.4 Not building

Unchanged from the backlog, and binding in the same way a deferred item is:

- **Hospital / EMR modules.** Different buyer.
- **A live insurer API** before the national system is open. FR-20 is an export.
- **Web or desktop feature parity for its own sake.** The phone is the product.
- **AI anything** before scanning, printing and break-bulk work.
- **Multi-writer offline.** Still deferred, still for ADR-002's reasons — see ADR-029.

---

## 4. Order of work

The backlog's 90-day cut, kept in its order. Each line is one PR or a short series, through
the same gates as V1 (`06` §4, §7).

| # | Item | State |
|---|---|---|
| 1 | **FR-11 sell units** — it was unverified; it was verified missing, so it went first | **Built** — ADR-030, contract 1.5.0 |
| 2 | **FR-12 pre-loaded catalogue** | **Built** — the 2024 Essential Medicines List as suggestions in the product form. The drug-shop and OTC lists are not in it yet |
| 3 | **FR-13 barcode scan** | **Built; needs a real phone and real boxes** — ADR-031, contract 1.6.0 |
| 4 | **FR-14 receipts** — share first (a day's work), then Bluetooth printing | **Half built** — share, and print through the phone's print system (ADR-032). **Bluetooth thermal printing is not built**: it needs a printer in hand |
| 5 | **FR-15 backup and restore**, and the hosting decision (§6) | |
| 6 | **FR-16 credit ledger** | |
| 7 | **FR-17 audit trail and daily summary on the phone** | |
| 8 | FR-18, FR-7a, FR-8a, FR-19, FR-20 — in the order pilots ask for them | |

**Why FR-11 is first and not merely important.** FR-12 loads a catalogue of products, FR-13
attaches barcodes to them, FR-8a computes margin from their cost. All three are built on what
a product *is*. If a product cannot say "a box is 100 tablets and costs this much", every one
of them is built on a model that has to be changed underneath it.

---

## 5. What V2 does to the V1 gates

Nothing is loosened.

- **Guardian suites stay the merge gate.** FR-11, FR-16 and FR-19 all touch money on a sale
  line; G4 grows with each.
- **The sync contract stays additive** (ADR-009, ADR-012). Every V2 change to the envelope is
  a MINOR bump with a version-log entry, and a V1 terminal keeps syncing unchanged.
- **Local schema upgrades stay additive.** A V2 app installs over a V1 database holding
  unsynced sales (`g7_schema_upgrade_test.dart`).
- **A-1 is unaffected.** No V2 item switches controlled dispensing on, and FR-12 does not set
  `is_controlled` from a list — the server still refuses to create a controlled product
  (ADR-024).
- **The V1 GA checklist (`06` §11) is still open** on the same four lines: staging perf,
  A-1, a restore drill, a field pilot. V2 is built alongside those, not instead of them. The
  pilot is where FR-11 to FR-14 get their real test.

---

## 6. Decisions that are the owner's

Engineering can settle everything else from the documents. These it cannot:

1. **Hosting (backlog P0-4).** ADR-027 chose free tiers knowingly and wrote the upgrade path.
   Moving to an always-on instance removes the cold start; it costs money every month, and
   the region and data-residency answer is a business statement to customers. Nothing in V2
   is blocked on it — every counter feature is offline — so it waits for a decision rather
   than a build.
2. **Pricing tiers** (single-shop vs multi-branch). A billing change, not a code change yet.
3. **Regulatory readings** for track-and-trace and e-invoicing, as with A-1.
4. **What the receipt is, legally.** FR-14 prints a slip that states the sale. Whether that
   slip can replace the receipt a registered sales machine produces — and so whether a shop
   may actually retire its till — is the Ministry of Revenue's rule to state, not ours.
   Until it is answered the receipt carries no TIN and claims nothing (ADR-032 §6).
