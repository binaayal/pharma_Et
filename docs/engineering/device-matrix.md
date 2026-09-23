# Device matrix (NFR-3.2)

**Implements:** `../05-qa-and-test-strategy.md` §7 (device matrix) and `../02-srs.md` NFR-3.2.
**Gate:** `../06-delivery-plan.md` §11 — *"Performance within NFR-3 budgets on staging (incl.
low-end Android)."*

---

## 1. Why this cannot be done in CI

> **NFR-3.2** core-loop actions (add item, commit sale) complete against local SQLite in
> **< 100 ms**, independent of network — this is the offline-first payoff and is
> non-negotiable for counter UX.

The number is a property of the **hardware**, not of the code. Committing a sale writes the
sale, its lines, the stock decrement and the outbox row in one transaction and then durably
flushes it, because surviving a process death is the entire point of G7. That flush is the
measurement, and on the cheap Android eMMC this product ships to it can cost an order of
magnitude more than on a build machine's SSD.

So there are two artefacts, and they are not the same thing:

| | Where it runs | What it proves |
|---|---|---|
| `apps/mobile/test/guardian/g7_local_latency_test.dart` | Dart VM, every CI run | The operation has not become *structurally* slow — no network on the sale path, no unindexed lookup, no transaction-per-line. Ceilings are well under 100 ms on purpose. |
| `apps/mobile/integration_test/nfr3_local_latency_test.dart` | **A real handset** | NFR-3.2 itself. |

They share `test/support/latency.dart` deliberately. Two numbers produced by subtly different
code cannot be compared, and comparing them is the whole point.

## 2. Running it

```bash
./scripts/device-matrix.sh              # every connected device
./scripts/device-matrix.sh <device-id>  # one device
```

It prints a markdown table and exits non-zero if any device missed the budget. Paste the
table into §4 below under the date you ran it.

What each column measures:

| Column | Operation |
|---|---|
| **add item** | `fefoBatch` — the indexed lookup between tapping a product and the line appearing in the cart |
| **commit sale** | the full local transaction plus the outbox enqueue: what the cashier waits on |
| **loaded p95** | the same commit, after 200 sales are already on the device — a terminal offline since Monday is the design, not an edge case |

## 3. Which devices

`../05-qa` §7 asks for **real low-end Android, not only emulators**. An emulator on a
developer machine uses that machine's storage and will pass regardless, which makes it worse
than no measurement: it produces a green table that means nothing.

Aim for at least:

- One **entry-level Android** current in the Ethiopian market (≤ 2 GB RAM, eMMC storage) —
  this is the device that decides whether NFR-3.2 holds.
- One **mid-range Android**, to show the trend.
- One **iOS** device, as the secondary target (ADR-001).

Also worth capturing while a handset is in hand, per `../05-qa` §7: SQLite behaviour under
low free storage, and power-loss durability (pull the battery mid-sale, reopen, confirm the
sale is there and queued).

## 4. Results

*Not yet run — no handset has been connected.* This section is the GA evidence; until it has
rows, `../06` §11's performance line stays unticked.

| Date | Device | Platform | add item p50/p95 | commit sale p50/p95 | loaded p95 | Verdict |
|---|---|---|---|---|---|---|
| — | — | — | — | — | — | — |

### Reference figures (NOT a substitute for the above)

Taken on a developer machine, to show what the CI guard is holding and what headroom the
budget has before hardware enters the picture:

| Operation | p50 | p95 | max |
|---|---|---|---|
| add item | 0.9 ms | 3.4 ms | 6.6 ms |
| commit sale | 8.5 ms | 20.6 ms | 28.4 ms |

**Read that second row carefully.** 20.6 ms p95 on an SSD leaves roughly 5x headroom against
a 100 ms budget, and a slow eMMC fsync can consume more than that. NFR-3.2 is therefore a
genuine, open risk rather than a formality — which is precisely why §11 gates GA on it.
