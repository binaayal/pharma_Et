# ADR-030 — Sell units: a pack is recorded on the line, never multiplied into it

**Status:** Accepted · **Date:** 2026-10-07
**Implements:** FR-11 (sell units / break-bulk) — `07-v2-sellability-plan.md` §3.1
**Amends:** `04-system-design.md` §3 (what a quantity is counted in)
**Depends on:** ADR-009 (N-1 compatibility), ADR-012 (extending the envelope), ADR-006
**Constrained by:** guardian G4 (money is exact), BR-3.2 (a sale is never blocked on stock)

## Context

A pharmacy buys a box of 100 and sells a strip of 10, a single tablet, or the box. V1 gave a
product one `unit` and counted everything in it. `04` §3 said packaging was "handled at
product definition, not at transaction time" — and nothing handled it. In practice:

- receiving 5 boxes meant typing 500, and the cost per tablet rather than the invoice's cost
  per box;
- selling a box meant typing 100 on the quantity stepper;
- **a box price could not be recorded at all** unless it happened to be a whole number of
  santim per tablet. A box of 30 at 100.00 is 333.33… santim each, and the contract, the
  phone and Postgres all assert `lineTotal = qty × unitPrice` in integers.

The third is not an inconvenience. It means the till charges something other than the price
the owner set, and the cash-up shows a variance nobody can explain.

## Decision

### 1. A product defines packs; each pack has its own price

`product.packs` is a list of `{ name, size, priceSantim }`: what the counter calls it, how
many base units it holds (2 to 100,000), and what one sells for. At most four, no two sharing
a name or a size. The base unit and its price are unchanged and are not a pack.

A pack's price is **stated, not derived**. A box is routinely cheaper than its tablets added
up, so there is nothing to derive it from.

### 2. Stock is counted in base units, everywhere, always

`stock_batch.qty_on_hand`, stock adjustments, oversell events and the controlled ledger do
not know packs exist. One number per batch, in the smallest unit — so "how many tablets do I
have" has one answer, and FEFO, expiry alerts and reconciliation are untouched.

### 3. A line is counted in the unit it was rung up in, and carries its pack size

A sale line sold by the box records `qty` = boxes, `unitPriceSantim` = the box price, and
`packSize` = base units per box, with `packName` for the receipt. A receipt line does the
same with the box's cost. `packSize` absent or null means the base unit.

- **Money:** `lineTotal = qty × unitPrice` holds exactly as before, in the pack's price. The
  contract refinement and the `sale_line_total_consistent` check are not touched.
- **Stock:** moves by `qty × packSize`. One function in the contract, `baseQuantity`, is the
  only place the server multiplies.

The alternative — convert to base units at the counter and store 60 tablets — cannot hold a
box price, which is the problem being solved.

### 4. The terminal's line is the record; it is not checked against the current packs

The server does not verify that a line's `packSize` is one of the product's packs. A terminal
offline for three days holds the packs as they were when it last pulled, and its sale
happened at that size and that price. Rejecting it would strand a real transaction in an
outbox (BR-4.1) over a catalogue edit. This is the rule prices already follow.

The consequence is deliberate: editing a pack never rewrites a past sale, and a receipt
reprinted later reads the pack from the line.

### 5. Controlled substances have no packs

A controlled dispense is one product and one quantity in base units, written to the ledger
(FR-4 §4b). The server refuses packs on a controlled product, and the dispense payload gains
no pack field. A second unit in a record whose value is that it has exactly one would be a
change to the regulated half, and that waits for A-1 like the rest of it.

### 6. A pack price is a price

Setting packs needs `catalog.manage`, bumps the product's `change_seq` so terminals learn of
it, and writes `audit.packs_changed` with the list before and after. Pack prices are **not**
in `product_price`; their history is the audit log.

### 7. Contract 1.5.0, additive

`packSize` and `packName` on a sale line, `packSize` on a receipt line, `packs` on a pulled
product — all optional. Logged in ADR-012 §4.

- A **1.4.0 terminal** never sends a pack, ignores `packs`, and keeps selling by the base
  unit. Its operations apply unchanged.
- A **1.5.0 terminal against a 1.4.0 server** — a store rollout racing a deploy — pulls
  products without `packs`, so it has none to offer and sends none. Nothing is rejected.
- A loose sale from a 1.5.0 terminal omits both fields, so it is byte-for-byte what 1.4.0
  sent.

The local schema goes to version 5 with four nullable columns. Null on every existing row,
which is correct rather than merely safe: those lines *were* in the base unit.

## Consequences

- **`qty` on a sale or receipt line is no longer always base units.** Anything that reads a
  line for *stock* must use `baseQuantity`. Today that is the sale apply, the receipt apply,
  the expired-dispense audit and the phone's movement trail — all changed here.
- **`itemsSold` in the sales summary counts units as rung up**: two boxes are two items.
  That is what "items sold" means to a cashier; a units-of-medicine figure belongs to the
  FR-8a reports, which will compute it with `baseQuantity`.
- **Cost per base unit is a ratio, not a column.** A box costing 90.00 for 30 is 3.00 each
  only by coincidence. FR-8a's margin report computes margin from line totals — pack cost
  against pack revenue — and never needs to divide.
- **A wrong pack size moves the wrong amount of stock.** Bounded by the 100,000 cap, shown on
  the receive screen as "= 150 capsule" before confirming, and corrected like any other
  count: with a stock adjustment, which is in base units.
- FR-12 (the pre-loaded catalogue) can now carry pack sizes, and FR-13 can map a barcode to a
  pack rather than only to a product.

## Alternatives rejected

- **Store everything in base units and add a `price_per_pack` hint.** Cannot represent a
  box price exactly; fails G4 the first time a box of 30 is sold.
- **Fractional quantities** (sell 0.1 of a box). Puts a non-integer next to money, which
  `04` §3 forbids for good reason, and makes stock a decimal.
- **A separate product per pack** ("Amoxicillin — box", "Amoxicillin — capsule"). What
  owners do today in other tools. Stock splits across two rows that are one shelf, and
  breaking a box becomes a manual transfer nobody records.
- **A `product_pack` table.** More correct in the abstract; the list is at most four entries,
  read whole on every pull and written whole on every edit, and never queried by content. A
  table would add a synced entity, an RLS policy and a pull section for no query it enables.
- **Validate `packSize` against the product on the server.** Rejects honest sales from an
  offline terminal — see decision 4.
