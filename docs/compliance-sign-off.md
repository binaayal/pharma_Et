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
| **A-1** | EFDA directive No. 1121/2025 — controlled-substance retention period and psychotropic dispensing rules (one substance per prescription; 15-day vs 30-day validity) | **Phase 2 entry gate** (`06-delivery-plan.md` §2): the controlled-substance ledger, FR-4 psychotropic enforcement, FR-6, NFR-5.1 | ⛔ **Unverified** |
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

*No entries yet. Phase 0 built no regulated code, so none was required — the ledger, the
audit log and the psychotropic rules are deliberately absent from the schema until A-1
clears (see `04-system-design.md` §5.6, `02-srs.md` §7).*

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
