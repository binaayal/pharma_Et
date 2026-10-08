# Field UAT / pilot protocol

**Implements:** `../05-qa-and-test-strategy.md` §15 (field UAT) and §7 (device matrix).
**Gate:** `../06-delivery-plan.md` §11 — *"Field UAT pilot signed off (real pharmacy, real
outages)"*. Sign-off on this document **is** that gate.

---

## 1. What the pilot is for

> §15: *NFR-1 (offline through real power cuts) **cannot be fully certified in CI**. Before
> GA, run a supervised pilot in ≥ 1 real pharmacy through real outages, validating the daily
> loop, cash-up adoption, and offline durability in the field.*

Everything in CI is a simulation we wrote. The offline suites cut the network because a test
told them to; the chaos suites corrupt a file on purpose. A real pharmacy produces the
failures nobody thought to simulate — the ones that come from a counter, a queue, a power
cut at the wrong moment, and a cashier who has done this job for fifteen years and will not
change how they do it for an app.

Three things are being tested, and only one of them is software:

| | |
|---|---|
| **Does it survive?** | NFR-1.1's 72-hour window and NFR-1.3's zero-loss claim, against real outages rather than a mocked one. |
| **Is it used?** | Cash-up is the owner's primary anti-shrinkage control (`../01-vision-and-scope.md` §2.1.1). A control nobody performs is not a control, and that failure is invisible to every test we have. |
| **Does it make the day worse?** | The honest question. A till that is slower than the paper it replaced will be abandoned, and no requirement in `02-srs.md` would have caught it. |

## 2. Before it starts

**None of this is optional. The pharmacy is trading with real money and real medicine.**

- [ ] `../06-delivery-plan.md` §11 is green **except** this line and anything it depends on.
- [ ] The device matrix (`device-matrix.md`) has been run and NFR-3.2 holds on hardware of at
      least the class the pharmacy will use. A pilot on a handset that misses the local-op
      budget tests the wrong thing and wastes the pharmacy's goodwill.
- [ ] Backups verified by a restore drill (§11). Piloting without a proven restore risks a
      real business's records on an untested recovery path.
- [ ] **A written fallback.** The pharmacy keeps its existing process — paper or otherwise —
      available for the whole pilot, and staff are told plainly that they may fall back at any
      time without asking. A pilot that forces a shop to depend on unproven software is not a
      pilot, it is an experiment on someone else's livelihood.
- [ ] **Informed agreement from the owner**, in writing, covering: what data the system holds,
      that it is a pre-release version, that a defect could lose unsynced sales, and how to
      reach someone when it does.
- [ ] A named person on call for the pilot's duration, with `runbook.md` to hand.

## 3. Duration and shape

**Minimum two weeks**, including at least one full weekly cycle and — the point of the
exercise — **at least one unplanned power or network outage**. If no outage occurs naturally,
the pilot is extended rather than concluded: an offline-first product that has never been
offline in the field has not been tested.

Observe on site for the first two trading days and the first cash-up. After that, daily
contact is enough.

## 4. Scenarios

Each maps to a requirement, and each has a pass condition that is a fact rather than an
impression.

### 4.1 The daily loop (FR-3, FR-4, FR-7, FR-8)

| Step | Pass condition |
|---|---|
| Receive a real delivery | Every line on the wholesaler's invoice appears on the shelf count, with the lot and expiry as printed on the box |
| A full day of real sales | Every sale the shop took is in the system. Reconciled against the till and any paper fallback, not against the app's own total |
| Cash-up at close | The variance the app reports matches the drawer, counted by hand before the expected figure is revealed |
| Owner sees the day | The dashboard figure equals the counted takings for that branch and day |

**Fail if:** a sale taken at the counter is not in the system at close, in any circumstance.
That is S1 under §14 — stop the line.

### 4.2 Cash-up adoption (Vision §2.1.1)

Not a software test. Record, for every trading day:

- Was a cash-up performed? By whom?
- How long did it take, from opening the screen to closing the shift?
- If it was skipped — **why**, in the staff member's own words.

**Pass:** cash-up performed on at least 90% of trading days by the end of the second week,
without the observer prompting.
**Fail:** staff routinely skip it, or perform it by copying the expected figure instead of
counting. The second is worse than the first and will not show up in the data — it is what
the deliberately-hidden expected figure exists to prevent, and only observation catches it.

### 4.3 Offline durability through a real outage (NFR-1.1, NFR-1.3)

When an outage happens — and it will — record: when it started, how long it lasted, what was
sold during it, and what the sync chip showed.

| Pass condition | Requirement |
|---|---|
| Selling continued with no interruption a customer would notice | NFR-1.2, Principle #1 |
| Every sale taken offline appears on the server after reconnect, exactly once | NFR-1.3, AC-9.1 |
| Nothing was duplicated by a retry | AC-9.2 |
| Cash-up during the outage produced the right variance | FR-8 |
| The terminal recovered without anyone being told what to do | NFR-1.1 |

**Fail if:** any sale is lost or duplicated. S1.

### 4.4 The things only a real shop produces

Record these; none has a pass/fail, and all of them are why we are here.

- A cashier forgetting their PIN mid-queue. Did the throttle (ADR-017) help or obstruct?
- A terminal offline past the seven-day ceiling (BR-2.3). Did the restriction make sense to
  the person holding the device?
- An oversell. Did anyone notice the flag, and did the reconciliation get done (BR-3.2)?
- Anything a staff member worked *around* rather than through. Workarounds are findings, and
  usually the most valuable ones in the whole pilot.
- The expiry date entry (FR-7). It is Gregorian on purpose while the rest of the app is
  Ethiopian — does that read as deliberate at the counter, or as a bug?

### 4.5 V2 at the counter (FR-11, FR-12, FR-13)

These three were built and tested without a handset. Each has a part only a shop can check.

| What to do | What must be true | Why CI cannot show it |
|---|---|---|
| **Scan twenty different boxes** from the shelf, in the shop's own light — blister cartons, a bottle, a small box, one with a DataMatrix | Each is read within about two seconds; none reads as a different product | A test hands the app a string. Focus, glare, curvature and a cheap camera are not strings. |
| **Scan a basket of five**, including the same box twice | Five lines' worth in the cart, the repeat counted twice and not six times | The repeat guard is a timing choice made at a desk |
| **Receive one delivery by scanning** a box with a GS1 DataMatrix | The lot and expiry filled in match what is printed on the box | Real manufacturers' codes, not the ones written for the tests |
| **Deny the camera permission**, then tap scan | A plain message, and typing still works | Permission dialogs are the operating system's |
| **Sell a strip and a box** of a product with packs; receive five boxes | The owner agrees the stock count and the money are both right | Whether "strip" and "box" are the words this shop uses |
| **Print a receipt** on the shop's own printer, in Amharic and in English; **share one** to a phone by SMS and by Telegram | The page is legible, the Amharic is letters and not boxes, and the totals match the till | No printer has been connected to this app. Whether the shop's printer has an Android print service at all is the first thing to find out |
| **Back up, then lose the phone:** with the network off, ring up five sales on phone A, back up, send the file to yourself by Telegram. On phone B, signed in to the same branch, pick the file and restore. Turn the network on | The five sales appear once on the server. Restore the same file again: still five. Try a wrong passphrase: refused | The share sheet and file picker are the operating system's; and whether an owner can do this unaided is the real question |
| **Run the debt book for a week** beside the paper one: every credit sale and every repayment in both | At the end of the week the two totals agree, per customer. Note every entry the owner made in the paper book that the app had no place for | Whether "a name and what is owed" is enough, or whether shops need a limit, a due date or a guarantor, is something only a real book shows |
| **Have the owner read Today's summary each evening for a week** without being reminded, and the Activity log once | Count the evenings they actually opened it. Ask what they looked at first, and what was missing | Whether a summary nobody is nudged to open gets opened is the whole question behind "should it be pushed" (ADR-035 §3) |
| **Set up ten products from the medicines list** | The pharmacist finds each in a few letters; note every one they could not find, and every suggestion that reads wrongly | The list was parsed from a PDF and spot-checked, not reviewed by a pharmacist |
| **Give three products a wholesale price**, one of them on a pack, then ring up a mixed basket as Wholesale for a real clinic order | The total is what the owner would have written on paper; the pack editor's four fields are readable and typeable on the shop's phone; the switch is back on Retail for the next customer | Whether two tiers are the tiers this shop has, and whether the widened pack row fits a real 720-pixel screen and a real thumb (ADR-037) |
| **Run the supplier book for a week** beside the invoice drawer: every delivery marked paid or not, every payment recorded, at least one paid from the till | At the end of the week the total owed matches the owner's own invoices, per supplier; the cash-up on the day a supplier was paid from the drawer balances. Note every supplier that ended up listed twice | Whether one name field keeps suppliers from being duplicated in real typing, and whether owners pay from the till as often as assumed (ADR-038) |
| **Connect the owner's Telegram** (`hosting.md` §13 done first) and leave it for a week | A message arrives each evening, within about half an hour of 20:30; its figures match Today's summary opened at the same moment. Note the evenings it was late or missing, and whether the owner read it | No test sends a real message — there was no bot. And whether 20:30 is the right time for this shop is the owner's to say (ADR-039) |

## 5. Recording findings

One row per finding, in the log below. Severity per §14: **S1** data loss / cross-tenant /
ledger / money; **S2** core loop broken; **S3** non-core; **S4** cosmetic.

An escaped S1 or S2 is not only a fix — it is an escaped-defect incident under §16, and it
must produce a guardian test before it is closed. Every S1 in this system's history was
supposed to be impossible; the suite is how "supposed to be" becomes "is".

| # | Date | Scenario | What happened | Severity | Guardian test added | Closed |
|---|---|---|---|---|---|---|
| — | — | — | — | — | — | — |

## 6. Sign-off

The pilot passes when **all** of these hold:

- [ ] No S1 finding is open, and every S1 found has a guardian test that fails without its fix.
- [ ] No S2 finding is open.
- [ ] §4.1 passed on every trading day of the final week.
- [ ] §4.2 met its 90% threshold, by observation and not by the app's own record.
- [ ] §4.3 was exercised by **at least one real outage**, and passed.
- [ ] The owner says, in writing, that they want to keep using it.

That last line is not a formality and it is not softer than the others. Every other box can
be ticked by a system that a pharmacy will quietly stop using, and `01-vision-and-scope.md`
is about a business being run better — not about a passing test suite.

**Pilot pharmacy:** ______________________  **Dates:** ____________ to ____________
**Observer:** ______________________  **Owner (signature):** ______________________

---

## 7. Status

**Not yet run.** No pharmacy has been engaged. `../06` §11's field-UAT line stays unticked
until §6 above is signed, and this document is the definition of what signing it means.

### 7.1 Bench run on a real handset — 2026-10-07 (not the pilot)

A first functional pass of the V2 features on a phone, driven over USB. **It is not field
UAT:** no pharmacy, no customers, no outage, one person's test account. It is recorded here
because it is the first time any of FR-11 to FR-17 ran outside a test runner, and because of
what it found.

| | |
|---|---|
| Device | Samsung Galaxy A10 (SM-A105F), Android 9, 720×1520 — a low-end handset of the kind §2 asks for |
| Build | Release APK from CD, version code 60, commit `d8b92d5`, signed with the upload key |
| Backend | Live (Render free tier), contract 1.7.0 (1.8.0 once FR-19 is deployed) |
| Starting state | v1.0.0 (code 49) installed, signed in, a till open for two days |

**Upgrade in place.** Installed over v1.0.0 without uninstalling. The app opened still signed
in, the open till was intact, and the local database went from schema 4 to 7 with nothing
lost. This is the scenario `g7_schema_upgrade_test.dart` rehearses, on a real file.

| §4.5 row | Result |
|---|---|
| Packs: define, receive by the box, sell by the box | **Pass.** Box of 10 at 900.00 defined; five boxes received as 50 tablets; one box sold at 900.00, not ten tablets at 100.00 |
| Medicines list | **Pass.** "para 500" offered *Paracetamol 500mg tablet*; "Add, then add another" kept the sheet open |
| Scan a barcode | **Not tested.** The scanner opens and the camera runs (frames arrive and change), with permission granted. Nobody held a box in front of it. Still open |
| Credit sale and repayment | **Pass.** 900.00 sold with 400.00 paid; customer owed 500.00 after the round trip to the server (counted once); 200.00 repaid, 300.00 owed |
| Cash-up with a repayment | **Pass.** Float 200 + cash sales 400 + debts repaid 200 = 800 expected. Not counted: the till was left open |
| Today's summary and Activity log | **Pass**, against live data: 900 sold, 400 cash, 500 credit, 300 owed, 200 repaid, two tills open |
| Receipt: print | **Defect found.** The system print dialog showed the slip correctly on A4 except one character — see below |
| Receipt: share | Share sheet opened with Telegram, Messages and Gmail. Nothing was sent |
| Backup | Backup made in about 7.5 s (key derivation on this processor). Share sheet opened; nothing was sent. **Defect found** — see below. Restore: the file picker opens; no file was restored |

**What it found that no test had:**

1. **A missing character on the printed credit receipt.** "On credit — Test Customer" printed
   with an empty box for the dash: neither font the page is set in has it. Now brackets, and
   a test holds every word the app prints to the characters those fonts have.
2. **"Backup made" after the share sheet was closed without sending the file.** The file had
   gone nowhere. The screen now says so, and "last backup" does not move.
3. **The Reports headline stayed at "ETB 0 · 0 sales" after a sale had synced.** The tab is
   kept alive and loaded once. It now reloads when the terminal's data moves, as Home does.
   (This one predates V2.)
4. **A label in the pack editor wrapped** on a 720-pixel screen and pushed its field out of
   line. Shortened.
5. **The platform's own actions read as raw names** in the Activity log ("tenant
   reactivated"). They have sentences now.
6. **A medicine suggestion carried a misleading heading** ("Paracetamol 500mg tablet · For
   Treatment of Acute Attack"). The heading is no longer shown.
7. Counts read wrongly for one ("1 sales"). Reworded.

**Second pass, same day, on the next signed build** (version 2.0.0, code 61, commit
`ad806ef`, installed over code 60 with the session and the open till intact):

| Finding | On the phone |
|---|---|
| 2 — "Backup made" after a dismissed share sheet | **Fixed.** The screen says the backup was not sent anywhere, and "last backup" did not move |
| 3 — stale Reports headline | Not exercised: no sale was rung up in this pass, so nothing went stale. Home and Reports agreed (ETB 900) on opening. Held by a test |
| 5 — raw names in the Activity log | **Fixed.** "Pharmacy account switched back on", "Subscription changed" |
| 4 — pack label | Not re-opened in the editor; the unit chips on the Sell screen fit on one line |
| 7 — "1 sales" | **Not fixed by that build.** Home and Reports still read "1 sales". The first fix reworded the summary and missed these two screens; corrected with FR-18, with a test |
| 1 — the dash on a printed credit receipt, and 6 — the medicine heading | Not re-checked on the phone; each is held by a test |

**Third pass, same day: FR-7a, FR-8a, FR-18 and FR-19 on the phone** (version 2.0.0, code
64, commit `2dc6d74`, installed over code 61; server on the same commit, contract 1.9.0). The
local database went from schema 7 to 9 in place, signed in, till intact.

| What was done | Result |
|---|---|
| Wholesale price on a product (80.00 beside 100.00) and on its box (750.00 beside 900.00) | **Pass.** Both saved, synced, and shown on the product; the Activity log reads "Wholesale price of Amoxicillin 50mg set to 80.00" |
| Sell at wholesale | **Pass.** The Retail / Wholesale switch appeared only after a wholesale price existed; switching repriced the line to 80.00 and the box to 750.00; one box sold for 750.00 and synced; the next sale opened on Retail |
| The wholesale slip | **Pass** in the print preview: "Sale #BOL-576D · Wholesale", every character present. **Defect:** the screen itself did not say Wholesale — see below |
| Sales summary | **Pass.** Total 1,650; "Of which wholesale 750" |
| Receive a delivery not paid for | **Pass.** Supplier typed as a name, ten at 30.00, "Not paid yet" with 100.00 paid now: 200.00 left owing. **Defect** in the label — see below |
| Suppliers | **Pass.** The supplier had been opened by the receipt; "You owe 200", counted once after the round trip to the server |
| Pay a supplier from the till | **Pass.** No source was preselected and the button stayed disabled until one was chosen; 50.00 from the open till; 150.00 owed, flagged as unsynced until the push, then clean |
| Cash-up after it | **Pass.** Float 200 + cash sales 1,150 + debts repaid 200 − paid to suppliers 50 = 1,500 expected. Not counted: the till was left open |
| Where the money is | **Pass**, against real records: 1,650 sold in 30 days, profit about 250 on Amoxicillin; nothing to reorder, sitting or to return, each said plainly |

**What this pass found:**

8. **The pack editor clipped a price.** With a wholesale field added there were four fields
   on one line, and "900.00" showed as "900.0". Each pack is now two lines — name and size,
   then the two prices — and a test lays it out at this phone's width.
9. **"Goes on the supplier's account" ran into its own figure** ("…account200.00"). Now
   "Left owing".
10. **The sale-complete screen did not say a sale was wholesale**, though the paper did.
    It does now.

**Fourth pass, same day: the medicines list, the scanner, and restore** (version 2.0.0,
code 67, commit `1e26bc5`, installed over code 64).

| What was done | Result |
|---|---|
| The medicines list | **Pass.** Stock's add button offered "Pick from the medicines list" first. All 1,315 medicines listed; "para" narrowed to 7; two ticked, priced at 45.00 and 60.00, and added — both in Stock a moment later. No medicine name was typed |
| Link a barcode | **Pass, from a picture.** An EAN-13 image (6291100080014) put on the phone over USB was read by the phone's own detector and linked to Amoxicillin as 06291100080014 |
| Sell by scanning | **Pass, from pictures.** The EAN-13 added Amoxicillin; a GS1 DataMatrix of the same medicine was recognised as the same product (count 2); a picture with no barcode said "No barcode was found in that picture" and added nothing |
| Receive by scanning | **Pass, from a picture.** The DataMatrix filled the product, lot `LOT42A` and expiry 2027-12-31 in one read. The receipt was not saved |
| Back up to a file | **Pass.** "Save it as a file" opened the system picker in Downloads; the file was written (1.8 kB with nothing waiting, 2.3 kB with one sale waiting), and the screen warned that a copy only on this phone is lost with it |
| Restore, wrong passphrase | **Pass.** "That passphrase does not open this backup"; nothing changed |
| Restore, offline, of a file holding one unsynced sale | **Pass.** With Wi-Fi and data off, one sale was rung up (saved in 86 ms, queued), backed up to a file and restored on the same phone: "Everything in that backup is already on this phone", and still exactly one sale waiting |
| …and then back online | **Pass.** The sale uploaded once: 3 sales, ETB 1,655 |
| Fix 8, the pack editor | **Fixed.** Two lines a pack; "900.00" and "750.00" in full |

**What the scanner test does and does not show.** Decoding ran on this phone, in the
shipped app, through the same detector and the same handling the camera feeds: EAN-13,
DataMatrix, GS1 parsing, the catalogue match, the repeat guard. What it does not show is the
lens — focus, glare, a curved blister pack, the shop's light. The camera opened and ran with
permission granted in three passes and saw only black, the phone lying on it. A box held in
front of it remains the first row of §4.5.

**What this pass found:**

11. **A backup could only be sent, never kept.** The share sheet held Telegram, Gmail,
    OneDrive and Bluetooth — no memory card, no folder. "Save it as a file" was added for
    this (ADR-033 §5, amended), and is how the restore above could be run at all.
12. **The medicines list was invisible** until a name was being typed — the owner had not
    seen it. It is now a screen of its own, offered first.
13. "1 sales or receipts" on the backup screen. Reworded so the count reads right for one.

**Fifth pass, 2026-10-08: the daily summary on Telegram** (version 2.0.0, code 69, commit
`be54fe2`; the owner had created a bot and put its token on the server that morning).

| What was done | Result |
|---|---|
| The server, on restart with the token | **Pass.** It registered its own webhook with Telegram; Telegram reported the live URL and no delivery errors |
| The two routes with no sign-in, called without their secret | **Pass.** Both answered 404 on the live server |
| Connect Telegram | **Pass.** The app opened the bot's chat with a one-time link; the bot replied "Connected to ttt. You will get the day's summary here each evening." Back in the app, the screen had already changed to Connected, without a tap |
| Send today's summary now | **Pass.** The message arrived within seconds, and its figures were the day's: 1 sale · ETB 80, cash 80.00, two tills still open, 300.00 owed by one customer, three products running low. The screen then read "Last sent for 2026-10-08" |
| Build 68 fixes, same morning | **Pass.** The sale-complete screen says "Wholesale"; the backup notice reads "Sales and receipts not yet on the server: 1" |

**Not shown:** the evening schedule sending by itself. The repository secret it needs was
not yet set when this pass was run, and a day already sent is skipped by design.

**Not done in any pass:** a barcode read through the lens; a restore onto a *second* phone
(the merge onto a fresh database is held by `g7_backup_restore_test.dart`); a session as a
cashier — signing out would have needed the owner's password to get back in.

**Left on the test account:** a pack on Amoxicillin 50mg, a Paracetamol product, a
receipt of five boxes, one credit sale, one customer ("Test Customer") and one repayment;
and from the third pass a wholesale price on Amoxicillin and its box, one wholesale sale,
a supplier ("Test Wholesaler") owed 150.00, a delivery of ten Paracetamol and one payment.
From the fourth: two Paracetamol products from the medicines list, a barcode on Amoxicillin,
and one 5.00 sale. The two backup files and three test pictures put in the phone's own
storage for this pass were removed afterwards.
Nothing in this system is deleted, so they stay.
