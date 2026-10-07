# ADR-032 — Receipts: one description of the sale, shared as text and printed through the phone

**Status:** Accepted · **Date:** 2026-10-07
**Implements:** FR-14 (receipts on paper and on the phone) — `07-v2-sellability-plan.md` §3.1
**Constrained by:** NFR-1 (works offline), FR-10 (Amharic), guardian G4 (money is exact)
**Not a controlled artifact:** nothing here touches the sync envelope, the schema or a rule.

## Context

The receipt screen had a Print button with nothing behind it. A customer — and more often
an organisation buying for its staff — needs something to take away, and a shop that cannot
give one keeps its old till beside the phone.

"Print a receipt" hides three different things:

1. sending the receipt to the customer's phone;
2. printing on whatever printer the shop's phone can already reach;
3. driving a Bluetooth thermal printer directly, byte by byte.

They differ in what can be built and verified without hardware in hand.

## Decision

### 1. One `ReceiptDoc`, rendered more than once

The receipt is built once from the committed sale — lines in the unit they were sold in
(FR-11), the integer totals the sale was committed with, tender, change, first name of who
served — and every output is a rendering of that one object. The shared text and the printed
page cannot disagree about what was sold, and a later thermal rendering will be a third
function over the same object.

Nothing is recomputed for display. The total printed is the total charged.

### 2. Sharing is plain text through the phone's share sheet

SMS, Telegram, WhatsApp, email — whatever the phone has. No account, no integration, no
network of the app's own. Plain text with each line's arithmetic written out, not padded
columns: a chat app shows it in a proportional font.

### 3. Printing goes through the operating system's print system

The receipt is laid out as a PDF and handed to Android's or iOS's print dialog: any printer
the phone has a print service for, and "Save as PDF" where there is none. It is drawn as a
narrow slip — an 80mm roll's printable width — so it prints properly on a roll and sits at
the top of an A4 sheet like a slip stapled to a page.

Amharic needs a font: the PDF library's built-in ones have no Ethiopic glyphs. Noto Sans
Ethiopic (SIL OFL) is bundled as the **fallback** font — it has the letters and no digits,
so prices and product names are set in Helvetica and only Amharic falls through. Bundled
rather than fetched, because printing must work with no network.

### 4. Direct Bluetooth thermal printing is not in this change

It is the output most small pharmacies will eventually want, and it is deliberately left
for its own piece of work, for reasons that are all about what cannot be checked at a desk:

- it cannot be tested without a printer: pairing, paper width, and what a given model does
  with a command are properties of the hardware;
- **Amharic on a thermal printer is not a code page.** These printers have no Ethiopic
  character set, so an Amharic receipt has to be sent as a raster image, at a width and
  density that vary by model;
- it adds Bluetooth permissions the stores ask about.

Until then a thermal printer is reachable where its maker ships an Android print service,
through decision 3. That is an honest partial answer, not the whole of "retire the till".

### 5. A failed receipt is never a failed sale

By the time the receipt screen exists the sale is committed locally and queued (ADR-002). If
sharing or printing fails, the screen says the receipt could not be sent and that the sale
is saved, and the next sale is still one tap away.

### 6. What the receipt does not claim

It carries the shop's name as this device knows it (the branch), the sale reference, both
calendars, the lines and the money. It carries **no TIN and no statement of what kind of
document it is**, and it is not presented as a fiscal receipt.

Whether a slip from this app can stand in for the receipt a registered sales machine
produces is a question for the Ministry of Revenue's rules, not for this code — the same
kind of question as A-1, and connected to the e-invoicing item already parked in
`07-v2-sellability-plan.md` §3.3. It is recorded there as the owner's to answer.

## Consequences

- The app grows by the font (about 0.4 MB) and the PDF and printing libraries.
- A pharmacy with a Wi-Fi printer, or a thermal printer with a print service, prints today.
  One with a bare Bluetooth printer shares by message until decision 4 is built.
- There is no reprint: the receipt exists on the screen that follows the sale. Reopening a
  past sale's receipt needs a sales-history screen, which FR-17 will bring.
- The header is the branch name. A pharmacy's legal name and TIN are not on the device;
  adding them is a tenant-settings change that waits on decision 6.

## Alternatives rejected

- **Bluetooth ESC/POS first.** The headline feature, and the one that cannot be verified
  here; shipping it untested would put a "Print" button in front of owners that fails on
  their particular printer.
- **Render HTML and let the platform convert it.** No font to bundle, but the conversion
  API is deprecated in the printing library and unavailable on some platforms.
- **Send a picture of the receipt.** Heavier on a metered connection, unreadable by a
  screen reader, and cannot be searched for later in a chat.
- **Print through the server.** Needs the network at the one moment the customer is waiting.
