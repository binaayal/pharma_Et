# ADR-025 — Forced deactivation of a pharmacy by the platform

**Status:** Accepted · **Date:** 2026-09-30
**Related:** ADR-016 (what suspension blocks), ADR-023 (offline sign-in), ADR-019 (session
continuity), BR-2.2 (platform access), FR-1

## Context

The platform had one lever over a pharmacy: suspending its subscription. ADR-016 made that
lever deliberately weak. A suspension is a billing matter between us and a customer in good
standing, so it blocks management writes and nothing else. Sales still sync, reads still
work, and the till never stops.

That is right for a late payment. It is the wrong tool for a pharmacy that breaks the terms
of service, for example by selling prescription-only medicine without prescriptions, using
the platform for fraud, or abusing staff accounts. There the platform must be able to stop
serving the account altogether, and quickly, without deleting anything the pharmacy or a
regulator may later need.

## Decision

A third tenant status, `deactivated`, set and lifted only by a Platform Admin from the web
console, with a required reason (at least 10 characters) that the owner is shown verbatim.

**What it refuses: everything.** Every authenticated request from the tenant gets a `403`
with `code: tenant_deactivated`: reads, reports, `/sync/pull` and `/sync/push` alike. This is
the deliberate difference from ADR-016.

| Surface | Suspended (ADR-016) | Deactivated (this ADR) |
|---|---|---|
| Sign-in, refresh | allowed | **refused** after the credential is proven |
| `/sync/push`, `/sync/pull` | allowed | **refused** |
| Reports, reads | allowed | **refused** |
| Management writes | refused (402) | refused (403) |
| Submitting a payment proof | allowed | refused (billing is not the issue) |

**It reaches tokens already issued.** A guard straight after authentication checks the
tenant's status on every request, from a cache with a 15-second TTL that the deactivating
instance clears at once. Sign-in and refresh check it directly. A check at sign-in alone
would leave every signed-in terminal working for the life of its token, and a refresh token
lasts thirty days.

**It is not an enumeration oracle.** Sign-in says "deactivated" only after the credential is
verified. A wrong PIN against a deactivated pharmacy is refused exactly as before (ADR-017).

**It deletes nothing.** The tenant's rows, events, ledger and subscription are untouched.
A refused `/sync/push` writes nothing, and the terminal keeps the operations in its outbox,
because `SyncService` never removes an unacknowledged operation. So ADR-016's reasoning still
holds: the records are the pharmacy's, and they are still on the pharmacy's devices.
Reactivation clears the three deactivation columns and the account resumes exactly as it
was, including the queued backlog, which uploads on the next sync.

**The device stops too.** On a `tenant_deactivated` refusal the app signs out and wipes this
device's cached offline sign-in for that pharmacy (ADR-023). Without that, a phone could
reopen the till offline for the rest of its offline window. A phone that never reconnects
cannot be reached; this is inherent to offline-first and is bounded by that window (168 h).

**It is on the record.** `audit.tenant_deactivated` and `audit.tenant_reactivated` go into
the tenant's own audit trail, marked `byPlatformAdmin`, for the same reason the billing
events are (BR-2.2). The schema enforces that a deactivation has a time, a reason and a
platform-admin actor, and that an active account has none of them.

## Consequences

- A Platform Admin can stop an abusive account in one step, and undo it in one step.
- One indexed primary-key read per tenant per 15 seconds per API instance. The NFR-3.2
  latency guard is unaffected.
- Across several API instances a deactivation takes up to 15 s to be enforced everywhere.
  Sign-in and refresh are immediate.
- Deactivation is not deletion, and there is still no endpoint that hard-deletes a tenant
  (NFR-5.3).

## Verification

- `apps/api/test/guardian/g1-tenant-deactivation.spec.ts` (14): refused sign-in with reason;
  a wrong PIN is still a plain 401; pre-existing tokens refused on reads and sync; refresh
  refused; a refused push writes nothing; the neighbouring tenant is unaffected; reactivation
  restores tokens, sign-in and records; audit events; tenant tokens cannot call it; reason
  required; no overwrite; schema constraint.
- `apps/mobile/test/guardian/g2_account_deactivation_test.dart` (6): client parses the
  refusal; sync reports `accountDeactivated`, not `offline`, and keeps the outbox; also when
  the refusal arrives on refresh; offline sign-in is wiped for that pharmacy only; the login
  screen shows the reason.
- `apps/dashboard/test/deactivation.spec.tsx` (3): the confirmation requires the reason and
  the typed pharmacy code.
