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
| **Set up ten products from the medicines list** | The pharmacist finds each in a few letters; note every one they could not find, and every suggestion that reads wrongly | The list was parsed from a PDF and spot-checked, not reviewed by a pharmacist |

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
