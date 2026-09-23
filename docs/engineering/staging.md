# Staging

**Implements:** `../06-delivery-plan.md` §5 (environments) and §6.2 (promotion path).
**Phase 0 exit gate:** *CI/CD auto-promotes to staging; staging reachable.*

---

## 1. What staging is

| Piece | Where | Deployed by |
|---|---|---|
| **API** | Fly.io — `pharmaet-staging`, single region (`fra`); image from `ghcr.io/<owner>/pharmaet/api` (GHCR rejects uppercase, so the repo name is lowercased) | `cd.yml` → `deploy-staging-api`, on every merge to `main` |
| **Database** | Neon — managed PostgreSQL 16, its own backup schedule | migrations run from the API image as Fly's release command |
| **Dashboard** | GitHub Pages — `https://<you>.github.io/pharmaEt/` | `cd.yml` → `deploy-staging-dashboard` |
| **Mobile** | built in CI; a signed internal-track build is Phase 1 | — |

**Synthetic data only, always.** Staging is seeded with the two fixture tenants and nothing
else. No real patient or controlled-substance data ever lands here, and staging shares no
credentials with production (`../06-delivery-plan.md` §5).

## 2. What happens on every merge to `main`

```
build & publish image (GHCR, immutable sha tag)
  └─ verify: stand THAT image up against a real Postgres, migrate, seed,
             drive scripts/smoke.sh through the whole walking skeleton over HTTP,
             then re-run the migration to prove it is a no-op
       ├─ deploy API to Fly  → release command migrates → rolling → smoke the live URL
       └─ deploy dashboard to Pages
```

The verify step is the one that earns its place. A deploy that would have failed fails on a
stack nobody depends on, before the hosted environment ever sees the image. It is also why
the migration runs from the *same image* that serves traffic — a separate migration image
drifts, and the drift shows up as a schema the running code does not expect.

Production is a separate, manually dispatched job and currently **refuses to run**: the GA
checklist (`../06-delivery-plan.md` §11) is not met — A-1 unverified, no restore drill, no
field UAT.

## 3. One-time setup

Everything else is already wired. These are the parts that need an account.

### 3.1 Neon — the database

1. Create a project at [neon.tech](https://neon.tech) (free tier is enough for staging).
2. Create a database named `pharmaet_staging`.
3. Copy the connection string. It looks like
   `postgresql://<owner>:<password>@<host>.neon.tech/pharmaet_staging?sslmode=require`.

That role is the **owner**: migrations run as it, and it is *not* what the application
connects as. The app connects as `pharmaet_app`, a non-owner role the first migration
creates — because Postgres exempts owners from row-level security, and an app running as the
owner would have RLS enabled and completely inert (ADR-003, ADR-007).

### 3.2 Fly.io — the API

```bash
# Once, on your machine:
curl -L https://fly.io/install.sh | sh
fly auth login
fly apps create pharmaet-staging

cd apps/api
fly secrets set \
  DATABASE_URL='postgresql://<owner>:<password>@<host>.neon.tech/pharmaet_staging?sslmode=require' \
  DATABASE_APP_PASSWORD="$(openssl rand -base64 32)" \
  JWT_SECRET="$(openssl rand -base64 48)" \
  CORS_ORIGINS='https://<your-github-username>.github.io'

fly tokens create deploy -x 8760h   # copy the output
```

`CORS_ORIGINS` must name the Pages origin exactly. Get it wrong and the console loads
perfectly and every request it makes is blocked by the browser — which looks like an API
outage and is not one.

### 3.3 GitHub — wire it up

```bash
gh secret set FLY_API_TOKEN            # paste the deploy token from above
gh variable set STAGING_API_BASE_URL --body 'https://pharmaet-staging.fly.dev/api'
```

Then enable Pages: **Settings → Pages → Source: GitHub Actions**.

Until `FLY_API_TOKEN` exists, the deploy job reports honestly in the run summary that the
image was built, published and verified but had nowhere to go. It does not fail the pipeline
and it does not pretend to have shipped.

## 4. Running staging locally

The same stack, the same image, the same Postgres major version:

```bash
docker build -f apps/api/Dockerfile -t pharmaet-api:local .
JWT_SECRET=local-only docker compose -f docker-compose.staging.yml up -d --wait
./scripts/smoke.sh http://localhost:3100/api
docker compose -f docker-compose.staging.yml down -v
```

This is exactly what CI runs on every merge, which is the point: if it passes here it passes
there, and a staging problem is reproducible on your desk without an account.

## 5. Verifying staging by hand

```bash
curl -s https://pharmaet-staging.fly.dev/api/health | jq
./scripts/smoke.sh https://pharmaet-staging.fly.dev/api
```

The health endpoint reports the contract versions the instance serves, so the N-1 window
(ADR-009) can be checked mid-deploy without reading the code. The smoke script drives the
whole walking skeleton — sign in, pull, push, replay for idempotency, read back, and confirm
the second tenant sees none of it.

## 6. Rolling back

```bash
fly releases -a pharmaet-staging          # find the previous version
fly deploy -a pharmaet-staging --image ghcr.io/<owner>/pharmaet/api:sha-<previous>
```

Migrations are forward-only, so rollback is redeploying the previous **image**, never
reversing the schema. That only works because schema changes are expand-then-contract: the
previous app version must still run against the current schema. A migration that breaks that
property is one that cannot be rolled back, and it does not ship
(`../06-delivery-plan.md` §6.2).

## 7. What staging is not, yet

- **No production-like data volume.** The seed is two tenants. NFR-3.1 (1,000 tenants) needs
  a representative dataset, which is Phase 1 performance work.
- **No low-end Android device lab.** NFR-1 and NFR-3.2 cannot be certified in CI; the device
  matrix and the field UAT pilot are release gates (`../05-qa-and-test-strategy.md` §7, §15).
- **No production environment.** Deliberately — see §2.
