# Staging

**Implements:** `../06-delivery-plan.md` §5 (environments) and §6.2 (promotion path), as
revised by ADR-027.

---

## 1. What staging is now

There is no hosted staging environment. PharmaEt runs **one live environment** on free tiers
(Render + Neon + Cloudflare R2), set up per [`hosting.md`](hosting.md). Staging is the
**pre-release stack CD builds on every merge**: the image that is about to ship, against a
real PostgreSQL 16, with the real migrations and the demo seed, driven end to end by
`scripts/smoke.sh`. A release that would fail, fails there, on a stack nobody depends on.

| Piece | Where |
|---|---|
| Pre-release verification | `cd.yml` → `verify`, `docker-compose.staging.yml` (synthetic data only) |
| Live | Render `pharmaet`, Neon, R2: `hosting.md` |

**One artifact, one origin.** The console is built into the API image and served by it
(`../03-architecture.md` §7): no CORS, and the console can never run against a server it was
not built for.

## 2. What happens on every merge to `main`

```
build & publish image (API + console, GHCR, immutable sha tag, commit baked in)
  └─ verify: THAT image + Postgres 16 → migrate → seed demo → scripts/smoke.sh (writes, on
             throwaway data) → console served → /api 404s → migration re-run is a no-op
       └─ live: migrate Neon with THAT image → Render deploy hook with THAT image →
                wait for /api/health to report the commit → scripts/smoke-live.sh (read-only)
```

The migration runs from the same image that will serve, before it serves, so the schema is
never behind the code.

## 3. Running the pre-release stack on your machine

```bash
docker build -f apps/api/Dockerfile -t pharmaet-api:local .
JWT_SECRET=local-only docker compose -f docker-compose.staging.yml up -d --wait
./scripts/smoke.sh http://localhost:3100/api
docker compose -f docker-compose.staging.yml down -v
```

This is exactly what CD runs. **Never point `scripts/smoke.sh` at live**: it signs in as the
demo pharmacy and pushes sales. The live check is `scripts/smoke-live.sh`.

## 4. When a separate hosted staging is worth paying for

When pharmacies depend on live every day and you want to try a release on real
infrastructure first: a second Render service and a Neon **branch** (a copy-on-write clone
of the live database, cheap on Neon's paid plans). The blueprint and pipeline already support
it. It is one more service in `render.yaml` and one more deploy job pointing at its hook.
