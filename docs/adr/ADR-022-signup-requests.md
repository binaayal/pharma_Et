# ADR-022 — Sign-up requests: anyone may ask, a person decides

**Status:** Accepted · **Date:** 2026-09-24
**Implements:** the onboarding flow in the prototype (`docs/prototype/index.html` screens 01,
02 and 22), Vision §4 (manual verification), FR-1
**Constrained by:** BR-2.2 (the platform has no default access to tenant data), ADR-003

## Context

The prototype's login screen offers *"New pharmacy? Request an account"*. The request
collects a pharmacy name, owner, phone, city and branch count, and lands in the web
console's **Sign-up requests** queue, where platform staff *"call the number to confirm it's
a real pharmacy before approving"*. Until now the only way to open a pharmacy was
`POST /platform/tenants`, typed in by us — the request half did not exist.

Opening tenants on self-signup would make the platform the cheapest place in Ethiopia to
mint a pharmacy identity. The prototype calls this out as the anti-abuse gate.

## Decision

1. **A request is not a tenant.** `POST /signup-requests` is public and writes one row to
   `signup_request`. It creates no tenant, user, branch or subscription.

2. **`signup_request` has no `tenant_id`** — until approval there is no tenant, and a rejected
   request never becomes one. It is added to the CI list of known non-tenant tables beside
   `platform_admin` and `login_attempt`, and is read and written only through
   `runAsPlatform`, which logs every use. The tenant role has no grant on it.

3. **One open request per phone number**, enforced by a partial unique index on the
   normalised number. It is the cheapest brake on somebody filling the queue, and it is
   honest with the caller, who already knows the number is theirs.

4. **Approval and account creation are one transaction.** The reviewer supplies the pharmacy
   code, the owner's username and a starting PIN (given to the owner on the verification
   call — V1 has no SMS gateway). `createTenantIn` runs inside the same transaction that
   marks the request approved, so there is never a tenant without a decision behind it, nor
   an approved request without a tenant. A taken code fails the whole approval and leaves
   the request pending.

5. **A decision is final.** A decided request cannot be decided again.

## Consequences

- The prototype's texted PIN is replaced by a PIN read out on the verification call, until
  an SMS gateway exists. The approval form says so.
- The owner's phone is known for tenants opened this way, and the tenant detail page shows it.
  Tenants opened directly by us have none, which is the truth.
- Guardian: `apps/api/test/guardian/g1-signup-requests.spec.ts` asserts no tenant on submit,
  one pending per phone, no tenant-token access to the queue, sign-in after approval, and
  atomic refusal on a taken code.
