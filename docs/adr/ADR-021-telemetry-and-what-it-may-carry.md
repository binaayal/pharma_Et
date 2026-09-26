# ADR-021 — Telemetry goes to stdout as JSON, and never carries a credential

**Status:** Accepted · 2026-09-24
**Implements:** NFR-7 (structured logging and sync telemetry surfaced to the platform team)
**Constrained by:** NFR-4.2 (credential protection), BR-2.2 (a platform admin has no default
access to tenant data)
**Relates to:** ADR-005 (the sync seam), ADR-017 (login throttling)

---

## Context

`engineering/runbook.md` §2 names four signals to watch — sync failure rate, oversell counts,
error rate and latency — and said plainly that none of them was wired and all were checked by
hand. NFR-7 asks for them to be "surfaced to the platform team".

That phrase is the whole reason this needs a decision. The moment telemetry is surfaced, logs
stop being a developer's scratch output and become **a place data is kept**: shipped off the
machine, retained for longer than most records, and held somewhere with fewer controls than
the database it came from. A PIN in a log is a PIN in every copy of that log, and no amount of
row-level security reaches it.

## The decision

### One JSON object per line, on stdout

No agent, no SDK, no dependency. Every platform this deploys to collects stdout, so wiring a
collector becomes configuration rather than code — and there is nothing extra to keep running
or to patch in a regulated system.

Formatting flips to human-readable on a developer's own machine, because a person tailing a
terminal is a user too. The condition is written as **"not development"** rather than
"production or staging": under the other spelling the test suite exercised the readable
branch, and every assertion about what ships would have been made against a format that never
ships.

### What it may carry, and what it may never

| Carried | Never carried |
|---|---|
| Tenant id, user id, terminal id — our own UUIDs, identifying a row | A PIN or password, successful **or** rejected |
| Route **template**, status, duration | An access or refresh token |
| Counts: received, applied, duplicate, rejected, resulting quantity | A username — what somebody types, and the easiest thing in a system to leak |

The route template rather than the URL, so requests aggregate; a path with an id in it makes
every request unique and every average meaningless.

A guardian suite asserts the absence — and, deliberately, the presence of the route and tenant
too. A log stripped until it is safe and useless is not a win: the runbook's signals need
something to aggregate on and somebody to act about.

### Successes from an interceptor, failures from an exception filter

**Guards run before interceptors.** A request refused by `JwtAuthGuard` — an expired token, a
missing one, a refresh token used as an access token — never reaches an interceptor, so an
interceptor-only implementation produces a log in which every authentication failure is
invisible. Those are the requests a platform team most wants counted.

Splitting by outcome rather than by convenience covers the whole pipeline and writes each
request exactly once. The filter changes no response: an observability layer that alters what
a client receives has stopped observing.

### The sync path emits its own signal

A push answers `201` with per-operation acks, so a batch can be refused in full while the
transport looks perfectly healthy (ADR-005). Alerting on HTTP status alone would never see it,
which is why `sync_push` carries the ack breakdown and why the **rejected** count is the
number worth watching.

Oversell is emitted as a rate rather than an incident: BR-3.2 records rather than prevents, so
a non-zero count is correct and the *shape of the curve* is the signal — one branch spiking is
a stock problem, many tenants spiking after a deploy is a sync problem.

## Consequences

- The sync service gains a telemetry call. It is a controlled artifact by path, which is why
  this ADR exists — the change is one emission and alters no sync semantics, and the gate
  cannot know that, which is the point of a gate.
- `ObservabilityModule` is `@Global()`. Used sparingly in this codebase and earned here: a
  module you must remember to import is a signal somebody will forget to emit, and the service
  holds no state.
- **Nothing pages anybody.** This ADR covers emission only. The collector and the thresholds
  need somewhere to run, and `06` §11's *"Runbook + monitoring/alerting live"* stays unticked
  until they do.
