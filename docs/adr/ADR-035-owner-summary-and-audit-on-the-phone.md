# ADR-035 — The owner's evening: a daily summary they open, and the audit trail as sentences

**Status:** Accepted · **Date:** 2026-10-07
**Implements:** FR-17 (audit trail and end-of-day summary on the owner's phone) —
`07-v2-sellability-plan.md` §3.2
**Builds on:** ADR-015 (the audit log exists and is immutable), ADR-012 §3 (two cash figures),
ADR-034 (the credit ledger), ADR-027 (hosting on free tiers)
**Not a controlled artifact:** a new read-only report and two screens. No contract, schema,
rule or permission-matrix change.

## Context

The owner's first anxiety is what happens when they are not in the shop. Two things answer
it, and both were half there:

- **The audit log** has recorded who changed a price, wrote off stock or added staff since
  ADR-015, immutably — and nobody could read it without a database client.
- **The day's figures** exist across four reports (sales, cash-up, stock, and now credit).
  An owner had to open each, and nothing told them whether the day was *fine*.

The backlog asks for "an end-of-day summary **to the owner's phone**" — a message that
arrives. That last word is the part with a real constraint behind it.

## Decision

### 1. One daily summary, computed by the server, read on the phone

`GET /reports/daily-summary` answers the evening question in one call: sales (cash, other
tender and credit apart), every till that touched the day with who ran it and its variance,
what is owed and what was repaid, what is running low or expiring or oversold, and how many
price changes, write-offs and expired sales happened. Scoped like the sales summary: an
owner sees every branch, a branch manager their own.

It stores nothing. Every figure is read from records that already exist, and the tests hold
each to the report that already shows it.

The phone asks for **its own day** — local midnight to local midnight, sent as instants —
so "today" is the shop's today, not the server's.

### 2. A shortage is never netted against an overage

50.00 missing from one till and 50.00 extra in another is two things to ask about. The
summary reports the sum of shortfalls and the sum of overages separately, lists each till
with its own figure, and leads with the shortage. A net of zero would report a clean day.

A till opened and never counted is reported as open, not left out.

### 3. The summary is opened, and shared; it is not pushed

> **Superseded by ADR-039 (2026-10-07).** The owner chose Telegram, and the objection
> below — nothing runs at closing time on a sleeping server — is met by a scheduled job
> that wakes it. The rest of this section is kept as the reasoning of its day.

The owner opens "Today's summary" under Reports, and can share it as a short text message
to their own chat. **It does not arrive by itself**, and that is a decision, not an
omission:

- **A push notification** needs Firebase Cloud Messaging: a Google project, credentials in
  the build, and a server that sends. None of that exists, and creating it is the owner's
  account to open.
- **An SMS** costs money per message and needs a gateway contract.
- **A Telegram bot** is free, but something has to run at closing time to send it — and the
  server is on a free tier that sleeps when idle (ADR-027, kept by the owner's decision of
  2026-10-07). A scheduled job on a sleeping instance does not fire.
- **A local notification** on the owner's phone could say "the summary is ready" but not
  what is in it without the same fetch, and would be wrong about a day whose tills had not
  synced.

So the honest version of "to the owner's phone" on today's infrastructure is: one tap, one
screen, one share. The server endpoint is the hard part of any pushed version and is done;
adding delivery later is a sender, not a redesign. Recorded as an owner decision in `07` §6.

### 4. The audit trail is read as sentences, by the owner

"Price of Paracetamol 500mg changed from 6.00 to 5.00 — Hana, 7 Oct 23:10", not an event
type and a JSON payload. Product ids are resolved from the catalogue on the phone; one it
does not know reads as "a product", never as an identifier.

Entries that are the usual shape of a problem are marked and can be listed alone: a price
made **cheaper**, a write-off that is not an ordinary recount, expired stock sold. A price
that went up, or stock that was found, is not marked — a filter that flags everything is a
filter nobody uses.

An event the app has no sentence for (a newer server's) is shown by its name. An audit
trail does not get to skip entries.

Owner only, as the server already enforces (`settings.configure`, ADR-015): a manager
reading the record of their own staff is a different thing from an owner reviewing the
business. Read-only, with no control that suggests otherwise.

### 5. Both need the network, and say so

The summary is every phone's sales added up; the audit trail lives on the server. Neither
exists on one phone. Offline, each screen says it needs a connection — and the audit screen
in particular does not show "nothing to show", which would read as "nobody did anything".
Both state how fresh their data is (BR-8.1).

On the free hosting tier the first request after an idle period is slow. These are the two
screens where an owner will feel that.

## Consequences

- An absent owner has one screen that says whether the day was fine, and one that says who
  did what. Neither needs them to know which report to open.
- **Nothing reaches the owner unprompted.** If they do not open the app, they are not told
  about a shortage. That is the gap this ADR leaves, on purpose and by name.
- "Running low" is a fixed threshold (twenty base units or fewer), the same on the phone
  and the server. It is not usage-based; that is FR-7a.
- The audit trail on the phone shows the most recent 200 entries with no date range.
- There are no voided sales in the audit trail because the system has no way to void a
  sale — the backlog's example does not exist to be logged.

## Alternatives rejected

- **Compute the summary on the phone from local data.** Works offline and is wrong for any
  pharmacy with two phones, which is every pharmacy whose owner is not at the counter.
- **Build push delivery now with a placeholder sender.** A notification feature that does
  not notify, shipped behind credentials nobody has created.
- **Show the raw audit log.** It is what existed, and nobody read it.
- **Let a branch manager read the audit trail.** One cell of the permission matrix, and the
  one ADR-015 deliberately left closed.
