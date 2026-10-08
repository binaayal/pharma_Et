# ADR-039 — The daily summary arrives on the owner's Telegram

**Status:** Accepted · **Date:** 2026-10-07
**Implements:** FR-17, the part ADR-035 §3 left out — delivery
**Supersedes:** ADR-035 §3 ("the summary is opened, and shared; it is not pushed")
**Decided by:** the owner, 2026-10-07 — "let the daily summary arrive on the owner's
Telegram account if it's possible, or you decide what's best" (`07` §6, decision 5)
**Depends on:** ADR-003 (tenant isolation), ADR-027 (free-tier hosting), ADR-025 (a
deactivated pharmacy gets nothing), ADR-035 (the summary itself)
**Constrained by:** BR-17.1 (the same figures as the report), BR-17.2 (a shortage is never
netted), `01` §2.3 (as little about anyone as possible)

## Context

FR-17 gave the owner a summary of the day. They had to open it. An owner who is not
thinking about the shop that evening does not, and the summary exists for exactly that
evening — the one where a till came up short and nobody rang.

ADR-035 §3 listed four ways for it to arrive and chose none: push needs a Firebase project,
SMS costs money per message, a Telegram bot "needs a server that is awake at closing time,
which the free tier is not", and a local notification cannot say what the day held. Three
of those reasons still stand. The third was solvable and is solved here.

## Decision

### 1. Telegram, through a bot

It is free, it is where pharmacy owners in this market already read messages, it needs no
store permission, no SMS contract and no Google project, and a message there is read on any
phone the owner carries — not only the one with PharmaEt on it.

### 2. A chat is linked by pressing Start, never by typing an address

The owner taps **Connect Telegram** in the app. The server mints a one-time code and returns
`https://t.me/<bot>?start=<code>`; the app opens it; the owner presses Start; Telegram tells
the server which chat sent that code.

- The code is 24 random bytes, works **once**, for **fifteen minutes**, and only a signed-in
  owner can mint one. The server stores its SHA-256, not the code.
- Nobody types a phone number, a username or a chat id — so nobody can aim a pharmacy's
  figures at the wrong chat by a typo, and a support agent cannot be talked into doing it.
- Asking again replaces the code. An existing chat stays linked until the new one is
  confirmed, so a half-finished relink does not silently stop delivery.

Owner only (`settings.configure`, the audit trail's gate). The summary is the whole business
in a paragraph; where it is sent is not a manager's or a cashier's to decide.

### 3. Something else rings the bell

A free instance sleeps and cannot wake itself. A **scheduled GitHub Actions workflow**
(`daily-summary.yml`, 17:30 UTC — 20:30 in Addis Ababa) makes one request each evening. The
request wakes the instance and asks it to send. It costs nothing, lives in the repository
with everything else, and is replaced by a real scheduler on the day the service moves to a
plan that stays awake — the endpoint does not change.

GitHub may run a scheduled job late. For an end-of-day message that is acceptable, and it is
said here rather than discovered.

### 4. A day is sent once

Each link records the shop's day it last sent for. A schedule that fires twice, is retried,
or is run by hand sends nothing the second time. A send that **fails** is not recorded, so
the next run tries again. If Telegram says the person has blocked the bot, the link is
dropped and the owner can reconnect.

"The shop's day" is the calendar day in Addis Ababa (UTC+3, no daylight saving), not the
server's.

### 5. Each summary is computed inside its own tenant

The dispatch is the first code path that produces a pharmacy's figures without that pharmacy
asking. So it does the minimum outside a tenant scope — list who is linked — and then, for
each, opens **that tenant's** scope and runs the same `DailySummaryService` the screen
calls, under RLS. The platform connection never reads a sale.

It sends only where the pharmacy is active (ADR-025) and the linked person is still its
owner. A link is not a standing right to the figures.

### 6. Two doors with no session, each behind a secret

- **`POST /api/telegram/webhook`** — Telegram calling. Telegram echoes a secret we gave it
  in a header; without it the route answers 404. All it can do is redeem a code.
- **`POST /api/internal/summary-dispatch`** — the schedule calling. A shared secret in a
  header; 404 without it. It returns three counts and nothing else, because its response
  lands in a CI log.

Both comparisons are constant-time. 404 rather than 401: an endpoint that says "wrong
secret" confirms it exists. The webhook secret is derived from the bot token, so there is
one fewer secret to set and rotating the token rotates it.

### 7. The message is the phone's own text

`summaryText` on the server reproduces `DailySummary.toText` on the phone line for line, in
English and Amharic, chosen by the language the owner was using when they connected. It is
plain text — a product named `Vitamin_C*` must not become formatting. One line is added that
the screen says elsewhere: the figures are as of the last sync (BR-8.1).

That language is stored on the link as `message_language`. It is a delivery preference —
which language to *write to this person in* — and not a property of any record: nothing in
the schema is stored in a language or a calendar (BR-10.2). The guardian that holds that
rule (`g4-utc-storage`) refuses any column named for a locale, and caught the first name
this column was given.

### 8. Off until somebody turns it on

With no `TELEGRAM_BOT_TOKEN` the feature reports itself unavailable, the screen says so, the
schedule exits quietly, and nothing else in the system is affected. A bot is an account,
and creating one is the service owner's act (`hosting.md` §13) — it cannot be done from code.

## Consequences

- **A pharmacy's daily figures pass through Telegram.** That is a third party carrying
  business data, by the owner's choice, to a chat the owner linked. The screen says so
  before they connect. Nothing about a patient or a customer by name is in the message.
- **Delivery is best-effort.** A late schedule, a server that is slow to wake, Telegram
  being unreachable: the summary is late or missing that evening, and still one tap away in
  the app. There is no retry later the same night beyond the schedule's own.
- **One time for everyone.** 20:30 Addis Ababa. A pharmacy that closes at 22:00 gets its
  summary before its last sales; "send it now" covers that by hand. A per-pharmacy time is
  a column and a second cron entry.
- **Tenant-wide, to the owner.** A branch manager's own-branch summary is not sent.
- **`dispatch` reads every tenant and user to decide who is eligible.** Fine at tens of
  pharmacies; at thousands it should become one joined query.
- **Not built:** push notifications and SMS (ADR-035's reasons stand); a summary on a
  schedule the owner sets; delivery to a group chat (the link is one person's).
- The table has no `tenant`-facing sync: no terminal ever pulls it.

## Verification

- Server: `apps/api/test/guardian/g1-telegram-summary.spec.ts` (35) — the code is opaque,
  hashed, single-use and expiring; a manager and a cashier are refused; both secret doors
  are shut without their secret; each pharmacy's message goes to its own chat and contains
  nothing of the other's; the text equals the report for the same day; a day is sent once
  and a failure is retried; a stopped pharmacy, a demoted or departed owner, and a blocked
  bot get nothing; the application role cannot read another tenant's link.
- Route classification: both unauthenticated routes are in `g1-cross-tenant-route-sweep`.
- Phone: `apps/mobile/test/widget/summary_delivery_screen_test.dart` (13) — never says
  Connected before the server does; says plainly when there is no bot, and when offline.
- **A message arriving: shown on a real phone, 2026-10-08**, once the owner had created a
  bot (`engineering/field-uat.md` §7.1, fifth pass) — the webhook registering itself on
  start, the link, the confirmation and "send it now". **Still not shown: the scheduled
  evening run**, which had not yet fired with its secret set.
