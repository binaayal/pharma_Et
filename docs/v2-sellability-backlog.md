# PharmaET — Sellability Backlog (v1.0 → v2)

_Reviewed from the APK (`et.pharma.pharmaet_mobile` v1.0.0): Flutter, offline-first on SQLite, REST backend on Render (`pharmaet-2yw8.onrender.com`). Lens for every item below: does it **reduce the owner's work**, **make/save them money**, or **make them feel in control**? If it only adds data-entry burden, it does not ship._

_Already settled, not gaps: the app is localized to Amharic. The monthly subscription paid by transfer + uploaded proof is a deliberate, accepted design — leave it as is._

---

## The one thing to internalize first

PharmaET today still works best as an **add-on**, not a **replacement**. An owner who installs it still types every drug name (no barcode), still keeps a receipt machine (can't print), and still runs a paper credit book (no customer ledger). Running it alongside the old tools means running *two* systems — and nobody pays monthly for a second system.

**It becomes sellable the moment it lets the owner throw an old tool away.** Every P0 below removes one existing chore or device. That is the whole strategy.

Market note: the offline-first design is right for Ethiopia and matches what buyers expect. The remaining distance to a confident sale is completeness at the counter (scan, print, loaded catalogue) and trust for the owner who isn't standing in the shop (backup, audit log, end-of-day summary).

---

## P0 — Blockers. No confident sale happens until these are done.

| # | Feature | Why it sells (effort saved / money / trust) | Rough effort |
|---|---------|---------------------------------------------|--------------|
| P0-1 | **Barcode scanning via phone camera** (2D DataMatrix + EAN/GTIN) | Kills the #1 daily pain: typing drug names. Faster checkout, fewer wrong-strength dispensing errors. EFDA is moving to GS1 DataMatrix anyway, so this is also future compliance. | M |
| P0-2 | **Pre-loaded Ethiopian drug catalogue** | EFDA *publishes* the Essential Medicines List, List of Medicines for Drug Shop, and OTC list. Parse them once; ship them in the app. Owner stops typing thousands of products on day one — the single biggest "not extra effort" win. | M (one-time data work) |
| P0-3 | **Receipt printing** — Bluetooth/USB thermal + A4 PDF | Customers and institutional buyers need paper. Right now `print` is unsupported and the app can't even request Bluetooth. Without this they keep the old till, so they never fully switch. | M |
| P0-4 | **Hosting & latency fix** | App depends on one free-tier Render instance abroad: cold-start lag on the first sale of the day, reports need the internet every time, and the owner's controlled-drug data sits on a foreign server they don't control. Move to a paid/always-on tier, ideally in-region, with a clear data-residency answer. | S–M |
| P0-5 | **Unit / break-bulk selling — confirm, then fix if missing** | Pharmacies buy a box of 100 and sell 1 strip or 1 tablet. If the app can't sell a fraction of a pack, every stock count and price is wrong and owners won't trust it. The schema shows one `unit` per product — **verify whether buy-unit vs sell-unit conversion exists.** If it doesn't, this is the most important P0 of all. | S to verify, M to build |

---

## P1 — Revenue & retention. These make the owner money, so they stop cancelling.

| # | Feature | Why it sells | Rough effort |
|---|---------|--------------|--------------|
| P1-1 | **Customer credit / debt ledger (ዕዳ)** | A huge share of real sales are on credit to regulars, clinics, and organizations. No customer table exists today. Tracking and recovering debt directly makes the owner money — the strongest retention hook. | M |
| P1-2 | **Near-expiry return-to-supplier list** | The app already flags stock expiring within 60 days. Group that stock by supplier into a return-for-credit list, so the owner recovers money on medicine they'd otherwise bin. Pure money-back, almost no new data entry. | S |
| P1-3 | **CBHI insured-sale capture + claim-ready export** | CBHI is expanding and the sector is digitizing. Let the owner tag insured sales and export a reimbursement-ready summary. Faster claims = cash flow. Start with export, not a live insurer API (national system isn't open yet). | M |
| P1-4 | **Supplier payables & purchase orders** | Goods receipt currently stores only a supplier *name*. Add balances owed, POs, and delivery history so the owner manages cash going out, not just stock coming in. | M |
| P1-5 | **Low-stock auto-reorder suggestions** | You already compute on-hand per batch. Turn it into a reorder list the owner acts on in seconds. Prevents stockouts = lost sales. | S |
| P1-6 | **Profit, best-seller & dead-stock reports** | Reports today are sales/cash-up only. Margin-per-drug and dead-stock-to-discount reports tell the owner where the money actually is. Make them work offline from local data, not only online. | M |
| P1-7 | **Wholesale vs retail price per product** | Many pharmacies sell to walk-in customers at one price and to clinics/organizations at another. One product should hold both prices so the cashier picks the right one, not do mental math. | S |

---

## P2 — Differentiators / moat. Build after P0–P1 land.

| # | Feature | Why | Effort |
|---|---------|-----|--------|
| P2-1 | **EFDA track-and-trace event reporting** | EFDA's system wants Receiving/Selling/Recall events reported with GTIN + batch + expiry (2D DataMatrix). You already scan (P0-1) and track batches — reporting these events becomes a compliance feature competitors lack. | M–L |
| P2-2 | **E-invoice compliance** when the Ministry of Revenue schedule lands | Directive 1142/2026 is in force; a phased rollout schedule is coming for taxpayers who keep books (VAT-registered pharmacies qualify). Being certified-ready is a sales headline the day it's mandated. Watch for the schedule. | L |
| P2-3 | **Drug interaction / dosage / generic-substitution reference** | Turns a cash register into a dispensing aid. Source from the Ethiopian medicines lists already parsed for P0-2. Reduces liability, raises perceived value. | M |
| P2-4 | **Multi-branch stock transfer + consolidated owner view** | You have branches and sync; add inter-branch transfer and a single owner dashboard across shops. Locks in multi-shop owners (highest-value customers). | M |
| P2-5 | **Customer refill reminders + purchase history** | Builds on the credit ledger (P1-1). Remind chronic customers (BP, diabetes) when a refill is due — repeat business the owner would otherwise lose. | M |
| P2-6 | **Fayda national ID on controlled dispensing** | Optional patient identity on the controlled-substance ledger via Fayda. Strengthens the EFDA story for narcotics/psychotropics. | M |

---

## Owner comfort & trust — gaps the counter features won't cover

These are what make an owner *comfortable* handing their shop to the app, especially when they aren't behind the counter themselves. Cheap to build, disproportionately reassuring.

- **On-device backup & restore.** Data lives on the phone plus one server. If the phone is lost, stolen, or broken, the owner must not lose their records. Give a one-tap backup (to their own storage or an export file) and an easy restore. This is the single biggest "can I trust my business to this?" fear.
- **An audit log the owner can read.** Who voided a sale, who changed a price, who adjusted stock, and when. The app already forces a reason on some actions — surface all of it in a plain list the owner reviews. Staff theft is the owner's number-one anxiety; showing you take it seriously sells the app by itself.
- **End-of-day summary to the owner's phone.** A short daily line — today's sales, cash counted, any shortage, what's running low, who was on shift. Lets an absentee owner relax without calling the shop every evening.
- **Send the receipt digitally** (SMS, Telegram, or share) in addition to printing. Cheap, and matches how Ethiopian customers actually keep records.
- **A simple guided first run.** A non-technical owner should be walked through opening the till, receiving stock, and making the first sale. If setup feels hard, they quit before they see the value.

---

## In plain English — what we're adding and why it helps the owner

For non-technical readers. Each line is something that saves the owner work, makes them money, or lets them trust the app.

**Fixes at the counter**
- **Scan with the phone camera instead of typing.** Point the camera at the box and the drug comes up. Faster line, fewer wrong-medicine mistakes.
- **The drug list already inside the app.** The owner doesn't type thousands of medicines to get started — Ethiopia's official lists come loaded. Open it and start selling.
- **Print a real receipt.** Hand customers and organizations a paper slip, so the owner can finally retire the old cash register.
- **A fast, always-on server.** No slow wake-up on the first sale, reports always open, and the owner's data isn't on a random machine abroad.
- **Selling loose tablets/strips, not just whole boxes** (needs checking). Pharmacies sell part of a pack all day; the app must count that correctly or the numbers are wrong.

**Things that make the owner money**
- **A credit/debt book (ዕዳ).** Always know who owes you and how much, so you collect it instead of losing it.
- **Return expiring medicine to the supplier for credit.** The app already spots what's about to expire — now it helps you send it back and get money, not bin it.
- **Insurance (CBHI) sales + ready-made claim list.** Tag insured sales and get reimbursed faster.
- **Supplier accounts.** Track what you owe each supplier and what you ordered — not just a name.
- **"Buy more of this" reminders.** The app already knows what's low; just show a reorder list so you never run out of a fast seller.
- **Profit and dead-stock reports.** See which drugs earn the most and which are sitting dead on the shelf.
- **Two prices per drug** — one for walk-in customers, one for clinics — so the cashier never does mental math.

**Things that make the owner trust it**
- **One-tap backup.** If the phone is lost or broken, your records are safe.
- **A record of who did what.** See who voided a sale, changed a price, or touched stock — your protection against theft.
- **A daily summary on your phone.** Today's sales, cash, and shortages — without calling the shop.
- **Send receipts by SMS/Telegram** and a simple walkthrough the first time, so nobody feels lost.

**The long game**
- **Report medicine movements to EFDA** once scanning is in — a compliance feature competitors don't have.
- **Government e-receipts** when the new law is enforced — be ready before it's required.
- **One screen across all your shops** — see every branch and move stock between them.

**The whole idea in one sentence:** the app should let the owner *throw away a tool they use today* — stop typing, retire the old receipt machine, close the paper debt book — and feel safe doing it.

---

## Explicitly DON'T build (effort that won't sell)

- **Full hospital/EMR modules** — different buyer, scope creep. Stay a pharmacy tool.
- **Live insurer API integration** before the national system is openly available — build the export, not the pipe.
- **Web/desktop feature parity** chased for its own sake — phone plus one counter desktop is enough for v2.
- **AI / "smart" anything** before barcode, printing, and break-bulk selling work. It impresses no owner who can't print a receipt.

---

## Pricing & packaging note

- The offline + transfer-proof model is fine; keep it. The pricing *structure* is the open question: a monthly fee competes against one-time-license rivals, so the value has to stay visible every month (the reports, reorder list, and debt recovery do that work — lead with them at renewal).
- Consider a **lower monthly tier for single-shop pharmacies** and reserve the full price for multi-branch, where consolidated reporting (P2-4) is the real value.
- Lead the sales pitch with the three things that let an owner **throw a tool away**: scan instead of type, print real receipts, and the whole drug list already loaded.

---

## The 90-day cut (ship this first, in order)

1. **Confirm break-bulk selling (P0-5)** — if it's missing, nothing else matters; fix first.
2. **Pre-loaded EFDA catalogue (P0-2)** — removes setup friction before anyone even evaluates.
3. **Barcode scan (P0-1)** — fixes the daily pain they feel in the first hour.
4. **Receipt printing (P0-3)** — lets them retire the old till.
5. **Hosting fix (P0-4)** + **on-device backup** — so uptime and data-safety fears stop losing you customers.

Then **customer credit ledger (P1-1)** and the **audit log** as the first retention + trust features. Everything else follows.

---

## Sources

- Ethiopia E-Invoicing Directive 1142/2026 — [lookuptax](https://lookuptax.com/tax-changes/ethiopia/electronic-invoicing-directive-1142-2026), [vatupdate](https://www.vatupdate.com/2026/10/01/e-invoicing-in-ethiopia-requirements-scope-and-implementation-timeline/)
- EFDA pharmaceutical traceability (GS1 GTIN/SSCC/GLN, 2D DataMatrix) — [EFDA Traceability](https://www.efda.gov.et/traceability/), [EFDA barcode factsheet](https://www.efda.gov.et/wp-content/uploads/2023/07/Overview-of-barcode-use-for-pharmaceutical-products-in-Ethiopia.pdf)
- EFDA medicines lists (pre-loadable catalogue) — [Essential Medicines List Oct 2024](https://www.efda.gov.et/wp-content/uploads/2025/02/Ethiopian-Essential-Medicines-List-Oct-2024.pdf), [List of Medicines for Drug Shop](https://www.efda.gov.et/wp-content/uploads/2023/06/List-of-Medicines-for-Drug-Shop.pdf), [drug lists index](https://www.efda.gov.et/doc-category/drug-lists/)
- Market/competitor context (offline + one-time pricing expectations) — [MedSoftwares: Pharmacy software for Ethiopia 2026](https://www.medsoftwares.com/news/best-pharmacy-hospital-software-ethiopia-2026)
- CBHI digitization — [Better Than Cash Alliance](https://www.betterthancash.org/news/transforming-ethiopias-health-sector-digitizing-payments-for-improved-access-and-efficiency), [MoH national health insurance digitization](https://www.moh.gov.et/sites/default/files/2024-12/REQUEST%20OF%20EXPRESSION%20OF%20INTEREST%20.pdf)
