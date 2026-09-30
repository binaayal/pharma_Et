# ADR-027 — Hosting on Render + Neon + Cloudflare R2, starting on free tiers

**Status:** Accepted · **Date:** 2026-09-30
**Supersedes:** the Fly.io deployment in `../engineering/staging.md` and `../06-delivery-plan.md` §5
**Related:** ADR-007 (non-owner app role), ADR-026 (security baseline), `../engineering/hosting.md`

## Context

PharmaEt starts selling with no hosting budget. Fly.io no longer offers a free allowance
for this, and its setup ran migrations as a `release_command`, kept payment screenshots on
the machine's local disk (which `fly.toml` never mounted as a volume), and seeded demo
pharmacies into the one environment. The owner will move to paid plans as revenue arrives
and needs that move to break nothing: not the phones in the field, not the data, not the
pipeline.

## Decision

1. **Render** runs the API and console as an **image-backed** web service, from the image
   CD already built and verified. Render never builds PharmaEt, so what runs is byte-for-byte
   what was tested. It deploys only when CD calls its deploy hook (`autoDeploy: false`).
2. **CD runs the migrations**, from that same image against Neon, *before* the deploy hook.
   This replaces Fly's `release_command` and does not rely on Render's pre-deploy command,
   which the free plan lacks. It stays correct on a paid plan unchanged.
3. **Neon** stays the database, over a **direct** (not pooled) connection, because every
   request scopes itself with `SET LOCAL` inside a transaction (ADR-007).
4. **Payment screenshots go to S3-compatible object storage** (Cloudflare R2; Backblaze B2 or
   any S3 API as a drop-in). Render's disk is ephemeral on every plan. Production refuses to
   start without `PROOF_STORAGE` set explicitly, so the ephemeral-disk mistake cannot recur.
5. **One live environment, `NODE_ENV=production`.** There is no budget for a separate
   staging. Pre-release verification is CD's docker-compose stack (real Postgres, real
   migrations, full smoke), and the live check after deploy is **read-only**
   (`scripts/smoke-live.sh`). No demo tenant ever touches the live database.
6. **`/api/health` reports `commit` and `clientIp`.** CD waits for the new commit before it
   declares the deploy done. The operator checks `clientIp` once to prove `TRUST_PROXY` is
   right for this host (ADR-026 §2).

## Consequences

- $0/month to start. The free-tier limits are written down with their upgrade triggers
  (`hosting.md` §11): Render sleeps after 15 minutes idle (kept awake by an uptime monitor,
  which is also the downtime alert), Neon's storage and restore window are small, R2 is
  10 GB.
- Every upgrade is a plan change. The image, env var names, schema, storage keys and pipeline
  do not change.
- **Phones carry the API URL.** `*.onrender.com` is stable while PharmaEt stays on Render; a
  custom domain before wide distribution makes any future host move a DNS change instead of
  an app update. This is the one early decision that protects every later one.
- The GA-gated `deploy-production` job remains for the day a separate production
  environment is funded. Until then, "live" is production, and `release-readiness.mjs`
  still records what GA would require.
