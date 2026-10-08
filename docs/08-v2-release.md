# 08 — PharmaEt 2.0: what it is, what was proven, what to do before selling it

**Status:** Release candidate · **Date:** 2026-10-08
**Scope decided by:** ADR-029 · **Plan:** `07-v2-sellability-plan.md`
**For:** the owner of this product, deciding whether to put it in front of a paying pharmacy.

This is one page to read before a sales conversation. It says what a pharmacy gets, how sure
we are of each part, and what is still yours to do. It does not repeat the requirements
(`02-srs.md`) or the decisions (`adr/`); it points at them.

---

## 1. What a pharmacy owner gets

V1 could record a sale. V2 is the list of things that let an owner **throw an old tool
away** (ADR-029).

| They stop using… | Because the app now… | Requirement |
|---|---|---|
| Mental arithmetic for a strip or a box | sells and receives by the pack, each with its own price; stock stays in tablets | FR-11 |
| Typing every medicine's name | lists 1,315 medicines to tick and price in one go | FR-12 |
| Searching by name at the counter | rings up by barcode; a delivery's lot and expiry fill in from one scan | FR-13 |
| A receipt book | prints or shares a receipt, in Amharic or English | FR-14 |
| Fear of a lost phone | backs up what is only on the phone — sent, or saved as a file — and restores by merging | FR-15 |
| The paper debt book | records who owes what, takes repayments, keeps the drawer honest about them | FR-16 |
| Phoning the shop each evening | sends the day's summary to their own Telegram; shows who changed a price or wrote off stock | FR-17 |
| The drawer of supplier invoices | records what each delivery left owing and what was paid, including from the till | FR-18 |
| Lowering a price to sell to a clinic | keeps a wholesale price beside the retail one; one tap at the counter | FR-19 |
| Guessing what to buy | says what is running out, what earns, what has not sold, what to send back | FR-7a, FR-8a |

All of it works with no network and syncs when there is one. All of it is in Amharic and
English.

## 2. How sure we are

Three different kinds of evidence, and they are not interchangeable.

**Held by automated tests on every change** — the server's guardian suites (tenant
isolation, sync integrity, money, stock, the ledger, offline) and the phone's own. Nothing
merges without them. Money is exact to the santim; one pharmacy never sees another's rows; a
replayed sync counts once; an offline sale is never lost.

**Done on a real phone against the live server** — a Samsung Galaxy A10, Android 9, six
passes on 7–8 October 2026 (`engineering/field-uat.md` §7.1). Upgrade in place from 1.0;
packs; the medicines list; credit sale and repayment; price tiers; a delivery on account and
a supplier paid from the till, with the cash-up agreeing; backup to a file and restore;
an offline sale that uploaded once; a real summary arriving on Telegram. Those passes found
thirteen defects no test had. All thirteen are fixed.

**Not yet shown by anything:**

| What | Why it matters | Who can close it |
|---|---|---|
| A barcode read **through the lens**, on real boxes, in a shop's light | Decoding was proven from pictures. Focus, glare and curved packs were not | You, in ten minutes with twenty boxes |
| A receipt **on a real printer** | The page was checked in the print preview only | You, with any printer the phone can see |
| Restore onto a **second** phone | Done on one phone; the merge onto a fresh one is test-only | You, with a second handset |
| A **week** of any of it in a working pharmacy | Every number above is from a bench, not a shop | The pilot |
| The evening Telegram message **arriving by itself** | Sent by hand and by a manually run schedule; the 20:30 run had not yet fired | The first evening |
| Anything on **iOS** on a device | It builds in CI. Nobody has held it | An iPhone |

## 3. What 2.0 does not do

Said plainly, so it is not discovered in front of a customer.

- **No Bluetooth thermal receipt printer.** Printing goes through the phone's own print
  system; sharing a receipt as text works everywhere (ADR-032).
- **No CBHI / insurance claim export** (FR-20). It needs the scheme's actual claim form.
- **No controlled-substance dispensing.** Built and switched off until EFDA's requirements
  are confirmed (A-1, ADR-024). Do not promise it.
- **No stored purchase orders, supplier invoices with due dates, or general expenses.** The
  reorder list is shared as text; supplier payments are the only money-out the cash-up knows.
- **One phone's reports are that phone's.** "Where the money is" is worked out on the device;
  two phones in one shop each show their own (ADR-036). The server's reports cover everything.
- **Two phones can each create the same supplier or customer** before either syncs; merging
  duplicates is not built.
- **The receipt is not a fiscal receipt.** It carries no TIN and claims nothing about tax.
  Whether it can replace a registered sales machine is the Ministry of Revenue's to say.
- **The free hosting tier sleeps.** The first request after a quiet spell takes up to a
  minute. Selling to more than a few shops means the paid tier (`engineering/hosting.md` §11).

## 4. Before the first paying pharmacy

In order. The first four are short and are yours.

1. **Scan twenty real boxes** and print one receipt. If either fails, that is a finding to
   fix before a demo, not during one.
2. **Decide the hosting step.** Free is fine for a pilot of one or two. For a pharmacy that
   depends on it daily: Render Starter, about $7 a month, no sleep (`hosting.md` §11).
3. **Buy the domain before handing out many APKs.** Every installed phone has the server's
   address built in (`hosting.md` §11, "the one thing to decide early").
4. **Set the price.** The app bills ETB 1,000 a month today because that is what the test
   account was given. Single-shop versus multi-branch pricing is undecided (`07` §6).
5. **Run the pilot as written** — `engineering/field-uat.md` §4.5, one shop, one week, the
   paper tools kept beside the phone and compared at the end.
6. **Get the three outside answers** that no code can supply: EFDA on controlled substances
   (A-1), the Ministry of Revenue on the receipt, and the CBHI form if insurance matters to
   your first customers.

## 5. The honest pitch

What can be said to a pharmacy owner today without overstating anything:

> It sells by the tablet, the strip or the box and keeps your stock right. It works when
> the internet is down. It keeps your credit book and tells you who owes you. It tells you
> each evening on Telegram how the day went and whether any till was short. It keeps what
> you owe your suppliers. It is in Amharic. If the phone is lost, your sales are not.

And what cannot yet: that it replaces a fiscal receipt machine, that it handles controlled
medicines, that it files insurance claims, or that it has run for a month in a shop like
theirs. The first three are answers we are waiting on. The last is what the pilot is for.

## 6. The build

Version 2.0.0, build 71, commit `e13c918`. It is attached to the draft GitHub release
`v2.0.0` as a signed APK and is the build the last device pass ran on. Publishing that
release is the owner's act; nothing is public until then.

## 7. Where everything is

| For | Read |
|---|---|
| What each feature must do, and the test that holds it | `02-srs.md` §3 and the traceability matrix in §6 |
| Why it was built the way it was | `adr/ADR-029` to `ADR-040` |
| What happened on the phone, pass by pass | `engineering/field-uat.md` §7.1 |
| Running it: hosting, the Telegram bot, rolling back | `engineering/hosting.md`, `engineering/runbook.md` |
| Getting the app onto phones and into the stores | `engineering/mobile-release.md`, `store/README.md` |
