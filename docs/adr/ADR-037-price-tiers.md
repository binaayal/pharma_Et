# ADR-037 — Price tiers: a second price on the product, a tier on the sale

**Status:** Accepted · **Date:** 2026-10-07
**Implements:** FR-19 (retail and wholesale prices) — `07-v2-sellability-plan.md` §3.3
**Depends on:** ADR-030 (sell units: a pack has its own price), ADR-009 (N-1),
ADR-012 (extending the envelope), ADR-015 (the audit trail), ADR-034 (credit)
**Constrained by:** guardian G4 (money is exact), ADR-024 (controlled dispensing is off)

## Context

A pharmacy that supplies a clinic, an NGO or a smaller drug shop sells the same box at two
prices. V1 has one price per product, so the wholesale sale is done one of three ways: the
cashier works the lower price out and has nowhere to type it, so the sale is rung up at
retail and "corrected" on paper; or it is not rung up at all; or the owner lowers the price,
sells, and raises it again — and the audit log fills with price changes that mean nothing.

Each of those keeps a paper book alive beside the phone, and each puts arithmetic at the
counter, which is where V2 is trying to remove it (ADR-029).

## Decision

### 1. Two tiers, and only two

`retail` and `wholesale`. Not a price list per customer, not a percentage discount, not a
free-typed price. A percentage would make the till do division on money and round it; a
typed price is a discount nobody approved. A second price **the owner set in advance** is
neither. If a pharmacy turns out to need a third list, that is an additive change to an
enum; nothing here has to be undone.

### 2. The wholesale price is stored, never derived

`product.wholesale_price_santim` — nullable, integer santim — beside the current price, and
`wholesalePriceSantim` on each pack beside the pack's price (ADR-030). Null means "this has
one price".

Nothing computes a wholesale price from a retail one, and nothing computes a box's wholesale
price from a tablet's. A box at 85.00 wholesale is 85.00 because the owner typed it, exactly
as the box at 100.00 retail is (ADR-030 §2).

### 3. Where no wholesale price was set, the customer pays what everyone pays

On a wholesale sale, a unit with no wholesale price is charged its ordinary price. The
fallback is **per unit sold**: a strip with no wholesale price sells at the strip's retail
price even when the tablet has a wholesale one — the till does not multiply the tablet's
wholesale price by ten and call it the strip's.

The alternatives were to refuse the line, which stops a real sale over a gap in the
catalogue, or to guess, which invents a price. Charging the ordinary price does neither, and
the receipt shows it.

### 4. The tier belongs to the sale, not the line

A clinic does not buy half its basket at retail. `priceTier` is on the sale; switching it
re-prices every line at once. The cashier picks **who the customer is**, never a price.

The switch appears only where the pharmacy has set a wholesale price on something, and goes
back to retail after every sale. Wholesale is the exception: a till left on wholesale would
quietly undercharge the next person in the queue.

### 5. The line still carries the price charged, and the server still does not re-price it

`unitPriceSantim` on the line is what was charged, as it always was, and
`lineTotal = qty × unitPrice` is checked as it always was. `priceTier` is a **label** on the
sale that says which list the cashier was on; it does not change what the server accepts.

So the server does not check a wholesale line against the product's wholesale price — for
the reason it does not check a retail line against the retail price (ADR-030 §4): the sale
happened offline at the price the terminal knew, and rejecting it later over a catalogue
edit strands a real transaction in an outbox.

The consequence is stated plainly under Consequences: the tier makes a wholesale sale
*visible*, it does not make an unauthorised price *impossible*. That was already true of
every price in the system.

### 6. Retail is stored as null

`sale.price_tier` is null for a retail sale, whether the terminal sent `retail`, sent
nothing, or predates the field. One spelling of the common case means "how much went out at
wholesale" is a single filter, and every sale already in the database is correct without
being touched. A check constraint refuses anything but null, `retail` or `wholesale`.

### 7. A wholesale price is a price

Setting one needs `catalog.manage`, bumps the product's `change_seq`, and writes
`audit.wholesale_price_changed` with the figure before and after — its own event type, so
the activity log can say "wholesale price" rather than leave the owner to work out which
price moved. On the phone it is flagged for a second look when it was **lowered**; a first
wholesale price is below retail by design and is not flagged.

The price form sends each price only if it changed, so a wholesale edit does not write a
retail price change nobody made. Pack wholesale prices travel with the packs and are in
`audit.packs_changed`, as pack prices already are.

### 8. Controlled substances have one price

The server refuses a wholesale price on a controlled product and the phone does not offer
the field, as with packs (ADR-030 §5). A controlled dispense goes through the ledger with
one price; a second is a change to the regulated half, which waits for A-1.

### 9. Reported as a part of the total, not a kind of money

The sales summary gains `wholesaleSantim`: the part of gross rung up at wholesale. It is not
a tender — it overlaps cash, other tender and credit — so it is shown as "of which
wholesale", only when there is some. Most wholesale customers pay later; that is ADR-034,
and the two compose without either knowing about the other.

### 10. Contract 1.8.0, additive

`priceTier` on a sale, `wholesalePriceSantim` on a pulled product and on a pack — all
optional. Logged in ADR-012 §4.

- A **1.7.0 terminal** sends no tier and ignores the new prices. Its sales apply unchanged
  and are retail, which is what they are.
- A **1.8.0 terminal against a 1.7.0 server** pulls no wholesale prices, so it shows no
  switch and sends no tier.
- A retail sale from a 1.8.0 terminal omits `priceTier`, so it is byte-for-byte what 1.7.0
  sent.

The local schema goes to version 8 with two nullable columns. The migration adds two
nullable columns and one check; the previous release runs unchanged on the new schema.

## Consequences

- **The tier is a record, not a control.** A terminal that sent a wholesale-priced line
  labelled retail would be accepted. What the owner gets is that an honest till labels every
  wholesale sale, the summary totals them, and the receipt says so. Catching a cashier who
  gives a friend the wholesale price is a matter of reading that total and those sales, not
  of the server refusing them. There is deliberately no capability for "may sell wholesale":
  the FR-2 matrix is unchanged, and whether one is wanted is the owner's to say after using
  it.
- **Who the wholesale customer was is not recorded** unless the sale is on credit, where the
  customer is named already. A tier per customer ("this clinic always buys wholesale") would
  hang on the customer record and is left out until someone asks for it.
- **Profit figures need no change.** FR-8a computes margin from line totals, so a wholesale
  sale's thinner margin is already what it reports.
- **The pack editor is wider by one field**, on a 720-pixel phone. It fits; a fifth field
  would not.
- A wholesale receipt says "Wholesale" beside the sale number, so an accounts office can see
  why the prices differ from the shelf.

## Verification

- Server: `apps/api/test/guardian/g4-price-tiers.spec.ts` (24) — the tier and the price
  charged are stored; stock moves as for any sale; the tier never excuses a wrong total; an
  unknown tier is refused by the contract and by the database; a 1.7.0 sale is unchanged;
  setting, removing, auditing and pulling a wholesale price; denied to a cashier; refused on
  a controlled product; tenant isolation; packs with both prices.
- Device: `apps/mobile/test/guardian/g4_price_tiers_test.dart` (16) — pricing per unit sold,
  the fallback, the stored tier, the wire payload with and without a tier, the pull, the
  pack editor.
- Screens: the switch and re-pricing (`sell_screen_test.dart`), the price form
  (`inventory_screens_test.dart`), the receipt (`receipt_test.dart`), the activity-log
  sentences (`owner_reports_test.dart`).
- Not shown by any test: the pack editor's fit on a real 720-pixel screen
  (`engineering/field-uat.md` §4.5).
