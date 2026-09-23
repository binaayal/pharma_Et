# Compliance sign-off log

**Status:** ✅ Live record · owner: Bina (compliance owner)
**Required by:** `06-delivery-plan.md` §7, as adapted by
[ADR-011](adr/ADR-011-solo-maintainer-change-control.md)

> With one maintainer, a GitHub approval by the author attests to nothing. This file is the
> compliance evidence instead: a dated, signed record of who verified what, against which
> source. It is the artifact an auditor asks for, and it was never the approval click.
>
> **Every entry names its source.** "I read the directive" is not a sign-off; "EFDA directive
> 1121/2025 Art. 14, obtained from <source> on <date>" is.

---

## 1. Open items blocking Phase 2

| ID | Item | Blocks | Status |
|----|------|--------|--------|
| **A-1** | EFDA directive No. 1121/2025 — controlled-substance retention period and psychotropic dispensing rules (one substance per prescription; 15-day vs 30-day validity) | **Phase 2 entry gate** (`06-delivery-plan.md` §2): the controlled-substance ledger, FR-4 psychotropic enforcement, FR-6, NFR-5.1 | ⛔ **Unverified.** 872/2022 was reviewed 2026-09-23 and is a different directive with a different scope — see §2. |
| A-4 | Electronic records satisfy EFDA record-keeping duties | The whole product; nothing had confirmed it | ✅ **Verified** — 872/2022 Art. 29 §1(l), for import/export/wholesale |
| NFR-5.2 | Sales/financial record retention period (planned 10 years, per Ethiopian business/tax record-keeping) | Freezing the retention configuration | ⛔ Unverified — needs an accountant, not a lawyer |

Until A-1 clears, compliance tests are **provisional**: they assert the *mechanism*
(immutability, tombstones-only, retention enforcement) but not the regulatory numbers, and
no regulated requirement can be marked done (`05-qa-and-test-strategy.md` §8, §13).

**What verifying A-1 actually requires** — so it is not mistaken for a reading exercise:

1. The directive text itself, from a citable source (EFDA publication or the Federal Negarit
   Gazeta), not a summary or a secondary article.
2. The specific articles covering (a) record retention duration, (b) one-psychotropic-per-
   prescription, (c) prescription validity periods, (d) what a dispensing record must contain.
3. Confirmation from a qualified Ethiopian pharmacy-regulatory advisor that the reading is
   current and complete — the directive may be amended, and an amended clause read as
   current is worse than no reading at all.
4. An entry in §2 below recording all of that, dated and signed.

## 2. Sign-off record

### 2026-09-23 — EFDA Directive 872/2022 reviewed · **A-1 NOT cleared**

**Reviewed by:** Bina (owner) provided the source; engineering read it.
**Source:** EFDA Directive **872/2022**, *Medicine and Medical Device Import, Export and
Wholesale Control Directive* (የካቲት 2014 / February 2022, Addis Ababa). Stored verbatim at
`regulatory/EFDA-872-2022-import-export-wholesale-control.pdf`.
**Advisor:** none. This is an engineering reading of a primary source, not a regulatory
opinion. §1 of this document sets the bar for a sign-off and this entry does not meet it.

#### Finding: this is a different directive, with a different scope

- **Art. 3 (Scope):** *"This directive shall be applicable to medicine and medical device
  [importer], exporter and wholesaler."* It does not cover retail or community pharmacy.
- The string **"1121" appears zero times**. `01-vision-and-scope.md` names **1121/2025** as
  the directive A-1 rests on; this is 872/2022.
- The word **"prescription" appears zero times**. It therefore says nothing about
  one-psychotropic-substance-per-prescription, nor about 15-day or 30-day validity.
- **No five-year or seven-year retention appears anywhere.**

**Effect on A-1: none. A-1 remains unverified**, and the regulated subset stays unbuilt.

#### What it *does* establish, and what that is worth

These are real findings from a primary source, and two of them retire assumptions the build
was quietly resting on:

| Art. 29 | Text | Effect |
|---|---|---|
| §1(l) | records may be kept *"in a paper copy **or electronically**"* | **Electronic record-keeping is permitted.** The entire product assumed this and nothing had confirmed it. |
| §1(i) | retain records about sold medicines *"**at least one year after the expiry dates** of the products"*, and notify the authority before disposing of them | A real retention floor — for **wholesale**, not retail. Does not license a number at the counter. |
| §1(e) | narcotic and psychotropic purchase and sale documents kept *"under lock and key box"* | EFDA does impose distinct handling duties on controlled-substance records. Supports ADR-004's shape; supplies none of its numbers. |
| §1(g) | retain records of narcotic and psychotropic medicines and *"report the same to the authority **every three months**"* | Periodic regulatory reporting is expected. An export capability will be needed (FR-6 / BR-6.3). |
| §2 | documents in a court case *"may remain on hold until the issues or cases are resolved"* | Retention has an **open-ended extension**. A retention policy that deletes on a fixed timer is wrong even once the base period is known. |
| §3 | financial records kept *"based on the legal requirements of the country"* | NFR-5.2's ~10-year assumption is still an accounting question, not a directive one. |

#### Assumption cleared

**A-4 `[ASSUMPTION]` → verified:** *electronic records satisfy EFDA record-keeping duties.*
Source: 872/2022 Art. 29 §1(l). Scope caveat: stated for import/export/wholesale; the same
provision has not been read for retail, so this is strong evidence rather than proof for the
counter.

#### Still outstanding for A-1

The directive governing **retail/community pharmacy dispensing** and controlled-substance
records at the counter — 1121/2025 by the name in Vision §7. Specifically: the retention
period for dispensing records, the substances-per-prescription limit, and prescription
validity windows.

**Signed:** engineering, 2026-09-23. Not a compliance sign-off; a recorded reading.

---

*No compliance sign-off yet, and none is due.*

Phase 2 has built the **event store** and the **general action audit log** (ADR-015). Neither
required a sign-off, because neither asserts anything a directive governs: the audit log is
staff accountability (Vision §2.1.1), and the store's append-only property is an
architectural decision (ADR-004) that no reading would reverse.

Still absent from the schema and the code, pending A-1: any `controlled.*` event type, the
psychotropic dispensing rules, the controlled-stock projection, and **any retention period at
all** — including a default. A guardian assertion holds the first of those true.

<!-- Template — copy for each sign-off:

### YYYY-MM-DD — <what was verified>

**Verified by:** <name>, <role>
**Source:** <citable document, article/section, where obtained, date obtained>
**Advisor:** <name, qualification> — or "none; self-verified against primary source"
**Finding:** <what the source actually says, in its own terms>
**Effect on the build:** <requirement IDs, code paths, test IDs affected>
**Signed:** <name>, <date>

-->

## 3. Regulated changes requiring a sign-off entry

Any change to these needs an entry in §2 before it merges, in addition to the mechanical
gates the `controlled-artifact` CI job enforces:

- The event/ledger schema (`04-system-design.md` §5.6) and its retention configuration.
- Psychotropic dispensing rules (FR-4: substance-per-prescription limit, validity windows).
- Anything that changes what a controlled-substance dispensing record contains.
- Any relaxation of the append-only property — which should never happen, and would need a
  superseding ADR before it could even be proposed.
