# ADR-036 — Reorder, profit, dead stock and returns are worked out on the phone

**Status:** Accepted · **Date:** 2026-10-07
**Implements:** FR-7a (reorder suggestions), FR-8a (profit, best-seller and dead-stock
reports), and the near-expiry return list from FR-18 — `07-v2-sellability-plan.md` §3.2
**Builds on:** ADR-030 (packs and base units), ADR-006 (a batch's id is its receipt line's)
**Constrained by:** ADR-027 (free hosting, kept by the owner on 2026-10-07), NFR-1 (offline)
**Not a controlled artifact:** read-only arithmetic over the local database. No contract,
schema, server or rule change.

## Context

The backlog's case for these four reports is renewal: an owner decides each month whether
the app is worth the fee, and "where the money is" is the screen that answers it. It also
says how they must work — *"offline from local data, not only online"* — because the
reports that already existed need the server every time.

That matters more now than when it was written. The server stays on a free tier that sleeps
when idle, so the first online report of the day is slow. A screen an owner waits fifteen
seconds for is a screen they stop opening.

## Decision

### 1. Computed on the phone, from the phone's own records

Sales, deliveries and stock are already in the local database. The four reports are queries
and arithmetic over it: they open at once and work with no network.

### 2. …and the screen says whose figures they are

A phone knows what *it* sold and received. For a shop with one phone — most of them — that
is everything. For a shop with two, each phone sees its own half; and a phone that was
reinstalled starts its history again. Every tab states this in one line, and the reports do
not pretend to be consolidated.

The consolidated version needs the server, and can be added beside this as "all phones"
when a multi-phone owner asks for it. It would replace none of the logic; the rules below
are the same either way.

### 3. Thirty days, and four plain rules

- **Reorder:** a product is suggested when it is selling and the shelf holds under 14 days
  of those sales — including when it has run out. The suggestion brings it to 30 days,
  rounded **up** to whole boxes where the product has a pack. **A product nobody is buying
  is never suggested**, however little there is: buying more of it is how dead stock starts.
- **Earning:** what sold in the last 30 days, ordered by what it brought in.
- **Dead stock:** on the shelf and unsold for 60 days. Stock received a week ago is new, not
  dead, so a product only counts once it has also been on the books for 60 days.
- **Return:** batches expiring within 60 days — and those already expired, marked — grouped
  by the supplier named on the goods receipt.

The thresholds are constants, not settings. A setting nobody has asked for is a thing to
explain; these can become settings when a pilot shop says the numbers are wrong for them.

### 4. Profit is an estimate, in integers, and says so

There is no cost on a sale line. Cost is taken as the average of what this phone has
received the product at — total paid over total base units, kept as two integers and
divided once, at the end (G4). A box bought at 100.00 for 30 has no exact unit cost, and
rounding per unit before multiplying is how a margin report drifts.

It is called "estimated" on the tile and explained underneath. It is an average, not FIFO:
the question it answers is "what earns", not "what is the taxable margin".

**Where there is no cost, there is no profit figure.** A product sold but never received on
this phone is listed with "cost not known", left out of the profit total, and counted in a
line that says so. Treating revenue with no known cost as pure profit would be the most
flattering number the app could show, and the least true.

### 5. A batch finds its supplier through its own id

A batch's id is the id of the receipt line that created it (ADR-006), so the return list
needs no new bookkeeping: join the batch to that line, read the supplier typed on the
receipt. A batch received on another phone has no line here, and is listed under "supplier
not known" rather than guessed at.

The supplier is still free text. Two spellings of one wholesaler are two groups; that is
what a real supplier entity fixes, and it is the rest of FR-18.

### 6. The lists can be sent

The buying list, and each supplier's return list with lots, expiry dates and a total at
cost, share as text — to whoever does the buying, or to the wholesaler.

## Consequences

- An owner has four reports that cost nothing to open and work in a power cut.
- A multi-phone shop gets partial figures, labelled as such.
- "Running low" on the daily summary (a fixed 20 units, ADR-035) and "reorder" here (days
  of cover) are different questions and can disagree. The summary's is the blunt alarm; this
  is the buying list.
- Controlled substances appear in none of it; their stock is the ledger's.
- FR-18 is **part built**: the return list is here; supplier accounts, payables and purchase
  orders are not.

## Alternatives rejected

- **Compute on the server.** Right for a multi-phone shop, and unusable offline or on a
  cold server — which the backlog named as the problem to fix.
- **FIFO costing.** Needs every sale matched to the delivery it came from. More accurate for
  an accountant; no different for deciding what to stock.
- **Suggest reordering anything below a fixed count.** Recommends restocking what does not
  sell.
- **Show profit as revenue where cost is unknown.** See decision 4.
