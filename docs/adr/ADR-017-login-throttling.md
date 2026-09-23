# ADR-017 — Login throttling: slow an attacker without closing a pharmacy

**Status:** Accepted · **Date:** 2026-09-23
**Implements:** NFR-4.2 (*"PIN login rate-limited"*), `05-qa` §10
**Constrained by:** NFR-1.2 (*"the app never hard-blocks a core sale"*), BR-2.3

## Context

Counter login is a **four-digit PIN**, chosen for speed at the till (NFR-6). Four digits is
ten thousand possibilities, and an unthrottled endpoint tries them in minutes. That matters
more here than the number suggests: this product's central claim to an owner is that it
records *who did what*, and an attribution you can forge by guessing a PIN is not an
attribution at all. Every cash-up variance and every audit entry rests on it.

So NFR-4.2 requires rate limiting. The question is what form, and the obvious answer is
wrong.

**Account lockout would be a denial-of-service against the pharmacy.** Lock a cashier after
five bad attempts and, in a shop with one terminal and one cashier, the till stops. Anyone
who knows a pharmacy's code and a username — neither is secret — could close a business for
as long as the lockout lasts. A control that hands an attacker a bigger weapon than the one
it removes is not a security control.

It also collides directly with NFR-1.2: *"the app never hard-blocks a core sale."*

## Decision

**Throttle the attempt, never lock the account, and never touch a live session.**

1. **A rolling window, not a counter that latches.** Five failures for one
   `(tenant code, username)` within fifteen minutes earns `429` with `Retry-After`. The
   window rolls; nothing needs unlocking, and no support call is required to undo it.

2. **A second, looser limit per source address** — twenty failures in the same window —
   which is what actually catches someone walking the username space. The per-username limit
   alone would let an attacker try five PINs against every cashier in the tenant.

3. **A successful login clears the counter.** A cashier who fumbles four times and then gets
   it right should not be one mistake from a lockout for the rest of the quarter.

4. **An issued token is never invalidated by this.** A terminal already signed in keeps
   working, online or off. This is the property that makes throttling safe here: because the
   app is offline-first and holds a cached session (BR-2.3), a login being throttled does
   **not** stop a pharmacy trading. The attacker is slowed; the shop is not touched.

5. **Attempts are recorded in Postgres, not in memory.** In-process counters reset on every
   deploy and are per-instance, so an attacker paces around them by waiting or by retrying.
   A table costs one insert per failed attempt, which is nothing, and it is honest across
   restarts and instances.

6. **Throttling is applied before the credential is checked and identically for every
   input.** Applying it only to existing accounts would turn the rate limiter into an
   account-enumeration oracle: "throttled" would mean "this user is real". The attempt is
   recorded against the strings supplied, whether or not any of them name anything.

## Rationale

- The threat is an attacker with a list of usernames and time. The defence that matters is
  making time expensive, not making accounts fragile.
- Fifteen minutes and five attempts is enough to make ten thousand PINs take months, and
  short enough that a locked-out cashier's realistic remedy is a cup of tea rather than a
  phone call to us.
- Recording attempts against whatever was typed, including nonexistent tenants, keeps the
  rate limiter from leaking the thing the uniform login error was written to hide.

## Consequences

- An attacker can deliberately throttle one known username for fifteen minutes. That is a
  real, accepted cost: it is bounded, it affects one user rather than a tenant, and — the
  part that makes it tolerable — **a terminal already signed in is unaffected**, so the
  counter keeps working throughout. Lockout has neither property.
- `login_attempt` is a table with **no `tenant_id`**, because an attempt may name a tenant
  that does not exist. That is deliberate and it is on the CI list of known non-tenant
  tables, so the next person to add such a table has to say so on purpose.
- Failed attempts accumulate. A retention sweep is needed before the table is large; it is
  not needed at pilot scale, and pretending otherwise would be building for a problem that
  does not exist yet. Noted rather than solved.
- A four-digit PIN remains a four-digit PIN. Throttling buys time; it does not make the
  secret strong. If the pilot shows PIN sharing is common, the answer is a different
  authentication factor, not a tighter limit.

## Alternatives rejected

- **Account lockout after N failures.** Converts a guessing attack into a business-stopping
  one that needs no guessing at all.
- **Exponential backoff per account, unbounded.** Elegant, and indistinguishable from a
  lockout by the time it matters — a cashier told to wait sixteen minutes has been locked
  out with extra steps.
- **CAPTCHA.** On a counter terminal, under time pressure, frequently offline. No.
- **Longer PINs.** Directly against NFR-6, which asks for minimal taps to complete a sale,
  and would push staff towards sharing or writing them down — which defeats attribution far
  more reliably than guessing does.
- **In-memory counters.** Reset by every deploy and blind across instances, so the limit is
  whatever an attacker's patience makes it.
