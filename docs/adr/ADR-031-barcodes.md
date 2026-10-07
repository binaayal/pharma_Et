# ADR-031 — Barcodes: a product carries its barcodes, in one canonical spelling

**Status:** Accepted · **Date:** 2026-10-07
**Implements:** FR-13 (barcode scanning) — `07-v2-sellability-plan.md` §3.1
**Depends on:** ADR-009 (N-1 compatibility), ADR-012 (extending the envelope), ADR-014 (an
algorithm implemented twice, verified once), ADR-003 (tenant isolation)
**Constrained by:** NFR-1 (the counter works offline), ADR-024 (controlled dispensing is
switched off)

## Context

Typing a drug name for every item is the first thing a pharmacist complains about, and the
phone on the counter has a camera. Two kinds of code are on a medicine box in Ethiopia:

- a **retail barcode** — EAN-13 mostly — which is a product number (a GTIN) and nothing else;
- a **GS1 DataMatrix**, which EFDA's traceability scheme is moving medicines to. It carries
  the GTIN and, beside it, the batch number and expiry date.

A scan has to resolve to a product on a phone with no network, in the time it takes to wave a
box at a camera, and it must never resolve to the *wrong* product: that is the wrong
medicine at the wrong price, on a device nobody is watching.

## Decision

### 1. The link lives on the product, and reaches the till by pull

`product.barcodes` is a list of strings — several, because one medicine comes from several
manufacturers, each with its own GTIN. It is reference data like the price: written online,
behind `catalog.manage`, and mirrored to every terminal on its next pull. A scan is matched
against the mirror, so scanning never needs the network.

### 2. One canonical spelling

An all-digit code of 8, 12 or 13 digits is left-padded to 14. GS1 defines EAN-8, UPC-A and
EAN-13 as the GTIN-14 with leading zeros dropped, so this is the standard's own identity and
not a convenience: the EAN-13 on a box and the GTIN inside its DataMatrix become one stored
value. Without it a product linked by scanning one would not be found by scanning the other.

Anything else — a wholesaler's Code 128 shelf label — is kept as read, trimmed.

The server canonicalises what it is sent and stores only the canonical form (the contract's
`barcode` schema refuses any other). `canonicalBarcode` exists twice, in TypeScript and in
Dart, because the till compares offline; `BARCODE_VECTORS` is generated into Dart and run
against both, the arrangement ADR-014 set for the calendar.

### 3. One barcode, one product — per pharmacy

Within a tenant, a barcode on one live product is refused on another, with a 409 naming the
product that has it. If a code named two products a scan would have to choose, and would be
wrong half the time without saying so. The check runs inside the write's transaction on the
tenant-scoped connection, so two pharmacies may each link the same box (it *is* the same
box) and neither can learn what the other has linked.

It is a service-level rule, not a database constraint: it spans rows and the contents of a
JSON list. A GIN index makes the lookup cheap.

### 4. An unknown barcode adds nothing

No fuzzy match, no "did you mean". The scanner says the barcode belongs to no product, and
the cashier types the name as before. Someone with `catalog.manage` links it from the
product's screen, once.

### 5. A scan is a faster tap, with the same rules

Scanning a box at the till calls the same code path as tapping its name: the same FEFO
batch, the same expired-stock warning and authorisation (ADR-020), the same refusal of a
controlled substance while the switch is off (ADR-024). The scanner is not a second way to
sell and so cannot be a way round any of them.

### 6. A DataMatrix fills the receipt's fields; a person still confirms them

At goods receipt, a GS1 code's lot (AI 10) and expiry (AI 17) are put **into the form**,
shown, and saved only when the person adds the line. They are the two fields where a typing
slip means expired stock marked good — and also the two a misprinted or misread code would
get wrong, so they are read for the person, not instead of them.

The parser reads what is certainly there and stops at the first identifier whose length it
does not know, keeping what it had. A date that is not a date yields no date. The worst
outcome of an unreadable code is "unknown barcode"; it is never a guessed expiry.

**At sale, the lot and expiry in a DataMatrix are ignored.** FEFO still chooses the batch.
Binding a sale line to the scanned lot is what track-and-trace reporting will need, and it
changes which batch stock leaves from — that belongs with that feature, not smuggled in
with this one.

### 7. The camera

`mobile_scanner`, with the barcode detector bundled in the app rather than fetched from
Google Play Services on first use: a first scan that needs a download is a first scan that
fails in a shop with no network. The camera permission is requested only when somebody taps
scan, is declared not-required so phones without a camera still install, and frames are
decoded on the device and never stored or sent.

### 8. Contract 1.6.0, additive

`barcodes` on a pulled product, optional. A 1.5.0 terminal ignores it and keeps finding
products by name. Nothing a terminal *pushes* changes: a scanned sale is an ordinary sale.
Logged in ADR-012 §4. Local schema v6 adds one nullable column.

## Consequences

- Linking is a one-time cost per product, done by someone with `catalog.manage` and a
  network. A new shop scans nothing on day one until its boxes are linked. FR-12's list has
  no barcodes to offer — EFDA's list has none.
- A barcode identifies the **product**, not a pack. Scanning a box of 100 adds one base
  unit, and the cashier taps "box" (FR-11). Mapping a barcode to a pack is a small
  extension of the same list and waits for a pilot to say it is wanted.
- The app is larger by the bundled detector (several megabytes).
- No patient or image data is added; the store data-safety answers do not change
  (`store/README.md`).

## Alternatives rejected

- **A `product_barcode` table with a unique index.** The right shape if barcodes were
  queried across products at volume. Here they are read whole with their product on every
  pull, and a table would add a synced entity, an RLS policy and a pull section to enforce
  one rule the service already holds in a transaction.
- **Match scans on the server.** Fails the first time the power is out.
- **Store codes as scanned and normalise when comparing.** Two spellings of one barcode
  could then both be saved, on different products, and the uniqueness rule would hold for
  strings while failing for boxes.
- **Let any cashier link an unknown barcode at the till.** Fast, and it lets a cashier
  decide which price a box rings up at. The same reason a cashier cannot change a price.
- **Unbundled ML Kit via Play Services.** Smaller download; needs the network the first
  time, which is the one moment that cannot be relied on.
