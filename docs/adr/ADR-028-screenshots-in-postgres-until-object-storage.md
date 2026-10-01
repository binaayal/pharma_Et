# ADR-028 — Payment screenshots in Postgres until there is object storage

**Status:** Accepted · **Date:** 2026-10-01
**Amends:** ADR-027 decision 4 (object storage), for as long as no account exists
**Related:** ADR-026 (encryption at rest), `../engineering/hosting.md`

## Context

ADR-027 put payment screenshots in Cloudflare R2. Opening R2 needs a payment card, and the
fallback (Backblaze B2) could not be opened either, so on launch day there is no object
storage. Render's disk is wiped on every deploy, so local files are not an option.

## Decision

1. A third storage backend, `PROOF_STORAGE=db`: screenshots live in a new table,
   `payment_proof_blob`, keyed by the same storage key R2 would use. The bytes are the same
   AES-256-GCM ciphertext as before (ADR-026), so the database holds no readable image.
2. **The pharmacy's connection cannot touch the table.** The application role has no grant
   on it (revoked explicitly, overriding InitialSchema's default privileges). Writes and
   reads go through the platform connection, which logs each use. RLS is enabled and forced
   anyway, so a future grant cannot cross tenants silently.
3. **Deleted once decided.** Neon's free plan has 0.5 GB, so the console deletes a
   screenshot when the admin approves or rejects it, unless the admin unticks that.
   `payment_proof.image_deleted_at` records the deletion, and an
   `audit.payment_proof_image_deleted` event goes into the pharmacy's trail. The proof row
   itself — amount, reference, decision, who, when — is the billing record and is kept.
   A screenshot cannot be deleted before its decision. A "free space" action deletes any
   decided screenshot left behind.

## Consequences

- No new account or cost. A typical phone screenshot (300–800 KB) occupies the database only
  until it is decided.
- **Moving to object storage later:** set `PROOF_STORAGE=s3` and the four `S3_*` values. New
  uploads go to the bucket. Screenshots still pending at that moment stay readable only if
  their rows are copied into the bucket first (one script over `payment_proof_blob`), or
  they are decided before the switch, which is simpler.
- Postgres reuses the space of deleted rows (autovacuum). It does not shrink the reported
  storage immediately.

## Verification

`apps/api/test/guardian/g1-payment-proof-storage.spec.ts` (7): the app role is refused; the
platform reads the image back byte for byte; deciding deletes it and keeps the record,
subscription and audit event; the image answers 410 afterwards; keeping it is a choice;
nothing pending is deleted; the purge frees what is left; a tenant token is refused.
