# ADR-019 — A session renews itself; an expired one says so

**Status:** Accepted · 2026-09-24
**Constrained by:** NFR-1.2 (*"the app never hard-blocks a core sale"*), NFR-1.3 (zero data
loss), BR-2.3 (offline authority ceiling), NFR-4.2
**Relates to:** ADR-002 (offline-first), ADR-009 (contract versioning), ADR-017 (throttling)

---

## Context

`POST /auth/login` has always returned a `refreshToken` alongside the access token. Nothing
ever accepted one — there was no refresh endpoint — and until the guard was fixed the refresh
token was instead accepted *as* an access token, which made the fifteen-minute access TTL
meaningless.

Fixing that exposed the real problem underneath. **A terminal stopped syncing fifteen minutes
after sign-in.** The access token expired, the server answered 401, `SyncClient` raised a
transport exception like any other, and `SyncService` reported `SyncState.offline`.

That is the worst possible disguise. `offline` is a *normal* state here — the whole product is
built to keep trading through it, and the chip showing it is a daily sight rather than an
alarm. So the terminal went on taking sales, the outbox went on growing, the owner's dashboard
quietly stopped updating, and nothing in the shop gave anybody a reason to look. Recovery
required signing out and back in, which nobody would think to do.

It survived every suite in the repository because they all sign in and sync within seconds.
Nothing ever waited fifteen minutes, so nothing ever saw a 401. `docs/04` §9 listed
`POST /auth/refresh` as part of the design; it was never built, and neither was the client
half that would have used it.

## The decision

**Build the refresh endpoint, redeem it transparently, and make an unrecoverable session a
state of its own.**

### A refresh re-reads authority

`POST /auth/refresh` does not copy the old token's claims forward. It loads the user, checks
they are not deactivated, and rebuilds the scope from the database.

This is the part worth arguing for. A refresh that copied its claims would let a token outlive
the authority it describes: a cashier dismissed this morning could refresh through the
afternoon, and a role changed at lunchtime would not take effect until the offline window
ended. Bounding exactly that staleness is what BR-2.3 is for, and a refresh is the one moment
the terminal is provably online and can afford to ask.

It cuts both ways, deliberately — a promotion applies at the next refresh, and so does a
demotion.

### It accepts only a refresh token

`typ` must be `refresh`. Without the check an access token could extend itself forever, which
is the same confusion as a refresh token authenticating an API call, pointing the other way.
Both directions are now asserted.

### The refresh token is not rotated

Issuing a new refresh token on every redemption is the stronger practice — it makes theft
detectable — and it is the wrong trade here. If the response is lost in transit after the
server has invalidated the old token, the terminal holds a credential that no longer works and
must be signed in by hand: at a counter, mid-shift, with a queue. A pharmacy that cannot
authorise a manager action because a packet dropped is a worse outcome than a stolen refresh
token on a device that is already in the shop.

Revisit if the terminals ever leave the premises.

### An expired session is not an outage

`SyncState.sessionExpired` exists solely so the UI can tell the truth. The chip renders it in
red and words it as an instruction — *"Sign in again"* — because every other sync state is
something the terminal will resolve by itself, and this is the only one that needs a person.

**Selling is untouched throughout.** An expired session does not block the till: sales commit
locally and queue exactly as they do when the network is down (NFR-1.2). What changes is that
somebody is now told why they are not reaching the server.

### No contract version bump

`CONTRACT_VERSION` tracks the **sync envelope** — its log enumerates entity types, and ADR-012
already records apply-side semantics changing without a bump. An auth endpoint is not an
entity type, and bumping to 1.3.0 would imply a new operation type that does not exist. The
schemas are additive and the N-1 window is untouched.

## Consequences

- A session cached before this existed has no stored refresh token. Those terminals fall back
  to `offline` and recover at the next sign-in rather than being logged out on upgrade —
  asserted by a test, because signing every terminal out to deliver a convenience would be
  precisely the wrong trade.
- The refresh is attempted **once** per call, never in a loop. A freshly minted token that is
  also refused means something other than staleness, and retrying would turn a broken session
  into a request storm against a server that has already said no.
- `apps/mobile/test/guardian/g2_session_continuity_test.dart` covers both halves: the terminal
  recovers by itself when it can, and says so plainly when it cannot — including that the
  queued sale is untouched either way.
- Writing the server side caught a second defect: `findOne({ deletedAt: null })` did not
  exclude the soft-deleted row, so a deactivated user's refresh succeeded. It now uses an
  explicit `IS NULL` predicate, matching the login path. The failure mode was the dangerous
  kind — it reads as correct.
