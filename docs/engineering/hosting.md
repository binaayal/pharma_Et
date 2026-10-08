# Hosting — Render + Neon + Cloudflare R2

**Status:** ✅ Current · owner: Bina · **Decision:** ADR-027
**Replaces:** the Fly.io setup in `staging.md` (kept only for its local-stack section)

PharmaEt runs live on three free tiers, chosen so that **every upgrade later is a plan change,
never a code change and never an app update** for the pharmacies' phones.

| Piece | Service | Free tier | What it holds |
|---|---|---|---|
| API + web console | **Render** web service (Frankfurt) | free instance | the Docker image CD builds; nothing stored on its disk |
| Database | **Neon** Postgres (AWS Frankfurt) | free project | every pharmacy's records, with RLS |
| Payment screenshots | **Neon** (`payment_proof_blob`, ADR-028) until a card allows **Cloudflare R2** | within Neon's 0.5 GB; deleted once decided | encrypted screenshot bytes only |

```
phone / browser ──HTTPS──▶ Render (pharmaet) ──TLS──▶ Neon Postgres
                                 └──────────TLS──▶ R2 bucket (ciphertext only)
GitHub Actions: build image → verify → migrate Neon → Render deploy hook → live smoke
```

---

## 1. Before you start

- Merge PRs **#45 → #46 → #47 → #48 → this one**, in that order. The first CD run after the
  last merge publishes `ghcr.io/binaayal/pharma_et/api:latest`. Its deploy job will say
  "Live not deployed — missing …", which is expected until §6.
- On your machine: the repo on `main`, `pnpm install` done, `openssl` available.
- A password manager. Every value marked 🔑 below goes in it, and nowhere else.

## 2. Neon — the database (10 min)

1. Sign up at **neon.tech** (GitHub login is fine). Create a project:
   name `pharmaet`, **Postgres 16**, region **AWS Europe Central 1 (Frankfurt)**.
2. **Dashboard → Connect.** Turn **Connection pooling OFF**, so the host does *not* contain
   `-pooler`. PharmaEt scopes every transaction with `SET LOCAL` and needs a direct
   connection. Copy the string. It looks like
   `postgresql://neondb_owner:…@ep-…eu-central-1.aws.neon.tech/neondb?sslmode=require`.
   🔑 This is **`NEON_DATABASE_URL`**, the owner role. It runs migrations and nothing else.
3. Generate the application role's password (hex, so it never needs URL-escaping):
   ```sh
   openssl rand -hex 24          # 🔑 DATABASE_APP_PASSWORD
   ```
   The first migration creates the role `pharmaet_app` with this password. The server
   connects as that role, which **row-level security applies to** (ADR-007).

## 3. Cloudflare R2 — the screenshot bucket (10 min) — *later*

> **Skip this section for now.** Without a card there is no R2 or B2 account, so
> `render.yaml` sets `PROOF_STORAGE=db`: screenshots are kept, encrypted, in Neon and deleted
> when you approve or reject the payment (ADR-028). Come back here when you can open R2; the
> switch is `PROOF_STORAGE=s3` plus the four `S3_*` values in Render. Generate the two secrets
> in step 4 below either way.

1. Sign up at **dash.cloudflare.com** → **R2 Object Storage**. Cloudflare asks for a payment
   method before enabling R2, even on the free tier. Nothing is charged under 10 GB.
   > **No card?** Use **Backblaze B2** (10 GB free) instead. Create a *private* bucket and an
   > application key; the endpoint is `https://s3.<region>.backblazeb2.com`. The same five
   > variables below apply, so nothing else changes.
2. **Create bucket:** name `pharmaet-proofs`, location hint **Eastern Europe (EEUR)**.
   Leave **Public access OFF** and do not enable the `r2.dev` URL. Only the server reads
   these files.
3. **R2 → Manage API tokens → Create API token:** permission **Object Read & Write**,
   **specific bucket** `pharmaet-proofs`. Copy:
   - 🔑 **Access Key ID** → `S3_ACCESS_KEY_ID`
   - 🔑 **Secret Access Key** → `S3_SECRET_ACCESS_KEY`
   - the **S3 endpoint** `https://<ACCOUNT_ID>.r2.cloudflarestorage.com` → `S3_ENDPOINT`
4. Generate the remaining secrets:
   ```sh
   openssl rand -base64 48       # 🔑 JWT_SECRET
   openssl rand -base64 32       # 🔑 PROOF_ENCRYPTION_KEY — lose it and old screenshots are unreadable
   ```

## 4. Prepare the database from your machine (5 min)

The server refuses to start on an empty database, so migrate it and create your platform
admin once, by hand. Quote every value in single quotes.

```sh
cd apps/api

# Schema, RLS policies and the pharmaet_app role
NODE_ENV=production DATABASE_URL='<NEON_DATABASE_URL>' \
  DATABASE_APP_USER=pharmaet_app DATABASE_APP_PASSWORD='<DATABASE_APP_PASSWORD>' \
  pnpm migration:run

# Your platform-console login (14+ characters; never the dev password)
DATABASE_URL='<NEON_DATABASE_URL>' PLATFORM_ADMIN_EMAIL='you@example.com' \
  PLATFORM_ADMIN_PASSWORD='<a long passphrase>' PLATFORM_ADMIN_NAME='Binyam Ayalneh' \
  pnpm create-admin
```

Do **not** run `pnpm seed` against Neon. The demo pharmacies' PINs are public, and the
seed refuses in production anyway.

## 5. Render — the server (15 min)

1. **The image is public** on GHCR (`ghcr.io/binaayal/pharma_et/api`, anonymous pull
   verified), so Render needs no registry credential. If you ever make the package private,
   add a Render registry credential named `ghcr` (a GitHub token with only `read:packages`)
   and restore the `creds:` line noted in `render.yaml`.
2. Sign up at **render.com** → **New → Blueprint** → pick this repository. Render reads
   `render.yaml` and asks for every value marked `sync: false`. Fill in:

   | Key | Value |
   |---|---|
   | `DATABASE_URL` | 🔑 NEON_DATABASE_URL (the server swaps in `pharmaet_app` itself) |
   | `DATABASE_APP_PASSWORD` | 🔑 from §2 |
   | `JWT_SECRET` | 🔑 from §3 |
   | `PROOF_ENCRYPTION_KEY` | 🔑 from §3 |

   **Apply.** The first deploy pulls `:latest` and starts. Note the URL, e.g.
   `https://pharmaet-2yw8.onrender.com`. If that name was taken it has a suffix; use yours
   everywhere below.
3. **Service → Settings → Deploy Hook → copy it.** 🔑 This is `RENDER_DEPLOY_HOOK_URL`.

## 6. GitHub — let CD deploy (5 min)

Repository **Settings → Secrets and variables → Actions**:

| Kind | Name | Value |
|---|---|---|
| Secret | `RENDER_DEPLOY_HOOK_URL` | from §5.3 |
| Secret | `NEON_DATABASE_URL` | from §2 |
| Secret | `DATABASE_APP_PASSWORD` | from §2 |
| Variable | `LIVE_URL` | `https://pharmaet-2yw8.onrender.com` |
| Variable | `MOBILE_API_BASE_URL` | `https://pharmaet-2yw8.onrender.com/api` |

Then **Actions → CD → Run workflow** on `main`. From now on every merge to `main` builds,
verifies, **migrates Neon, deploys that exact image, waits for it, and smoke-tests it**
without anything writing to live data (`scripts/smoke-live.sh`).

## 7. Check it (5 min)

1. Open `https://pharmaet-2yw8.onrender.com/api/health`.
   - `"status":"ok"`, and `"commit"` is the latest `main` commit.
   - **`"clientIp"` must be your own public IP** (compare with whatismyip.com). On Render it
     takes `TRUST_PROXY=3` (set in `render.yaml`): `1` showed a `10.x` internal proxy and `2`
     a Cloudflare edge address.
     If it ever shows a `10.x`/`172.x` address again, raise it by one and look again. Get this right: otherwise every pharmacy shares one login-throttle counter.
2. Open `https://pharmaet-2yw8.onrender.com/`, sign in with the admin from §4.
3. Open `/privacy` and `/delete-account`.
4. `./scripts/smoke-live.sh https://pharmaet-2yw8.onrender.com` → **live smoke passed**.

## 8. Keep it awake, and hear when it isn't (5 min)

A free Render instance **sleeps after 15 minutes without traffic**, and the next request
waits 30–60 s. A cashier's first sign-in after lunch would time out. So:

- **uptimerobot.com** (free) → New monitor → HTTP(s) →
  `https://pharmaet-2yw8.onrender.com/api/health`, every **5 minutes**, alert to your email/phone.

This keeps the one instance awake: Render's 750 free hours a month cover one service running
all month. It is also your downtime alarm (runbook §2). `/api/health` does not touch the
database, so Neon still sleeps when no pharmacy is working and uses no compute.

## 9. Put the app on phones — today, without the stores

Store accounts and review take days. Until then, give pharmacies a **signed APK**:

1. Create the upload key and its four secrets: `mobile-release.md` §2 steps 1–2.
   **Back up the keystore file and its passwords.** Lose them and no installed phone can
   ever be updated.
2. Run **Actions → CD** again. The `pharmaet-android` artifact holds `app-release.apk`, built
   against `MOBILE_API_BASE_URL` and signed with your key.
3. Send the APK by WhatsApp/Telegram. On the phone: open it → allow *Install unknown apps* →
   install. Updates are a new APK installed over the old one; data is kept.
4. **When you move to Google Play later**, under *Play App Signing* choose **"Use my own app
   signing key"** and upload *this* key. Then Play updates install over the APKs you
   sideloaded. With a Google-generated key they would not, and every pharmacy would
   have to uninstall and lose any unsynced sales.

### Onboarding the first pharmacy
They install → **Request an account** → it appears in your console under **Sign-up
requests** → you call the number → **Approve** (choose code, username, starting PIN) → you
tell them the PIN by phone → they sign in and create their branch → they pay by CBE/Telebirr
and upload the screenshot → you approve it under **Payments**.

## 10. Backups on the free tier

Neon free keeps only a short restore window. Until you upgrade, take a weekly copy to
**your own** machine (never into GitHub, where artifacts of a public repo are readable):

```sh
pg_dump '<NEON_DATABASE_URL>' -Fc -f pharmaet-$(date +%F).dump   # needs PostgreSQL 16 client
gpg -c pharmaet-$(date +%F).dump && rm pharmaet-$(date +%F).dump    # encrypt it
```

## 11. Growing out of free — what changes, and what never does

**Never changes:** the Docker image, every environment variable name, the database schema,
the storage keys, the CD pipeline, and, **if you keep the same URL**, the phones.

| When | Upgrade | What you do | Code change |
|---|---|---|---|
| First paying pharmacies depend on it daily | **Render Starter** (~$7/mo): no sleep, shell access, zero-downtime deploys | `plan: starter` in `render.yaml` (or the dashboard). Keep UptimeRobot for alerts. | none |
| Database near **~400 MB**, or you need a longer restore window | **Neon Launch** | upgrade the project in Neon. Same connection string. | none |
| Many pharmacies / more than 10 GB screenshots | R2 pay-as-you-go (cents per GB) | nothing; billing starts past the free tier | none |
| Two or more API instances | Render paid, scale to 2 | the in-memory rate limit becomes N × the limit (ADR-026); the login throttle is already shared in Postgres | none |
| Leaving Render (e.g. a VM) | any Docker host | same image, same env vars, `TRUST_PROXY` per its proxy | none, **but see below** |

**The one thing to decide early: your own domain.** Every installed phone has the API URL
built in. `*.onrender.com` works for as long as you stay on Render, free or paid. If you
ever leave Render, every phone needs a new APK. A domain (~$10/year, e.g. `pharmaet.et`
or a `.com`) removes that for good:

1. Buy the domain. Put its DNS on Cloudflare (free).
2. Render → Settings → **Custom Domains** → add `app.<yourdomain>` and follow the DNS steps
   (HTTPS is automatic).
3. Change `LIVE_URL` and `MOBILE_API_BASE_URL` to the domain, and ship one new APK.

After that, changing hosts is a DNS change. **Do this before you hand out many APKs**:
ideally before the first store release, since store listings and the privacy URL also
point at it.

## 12. Rolling back

Migrations only move forward, so the previous image runs on the new schema (docs/06 §6.2):

```sh
# the previous build's tag is on its CD run, e.g. sha-1a2b3c4d5e6f
curl -X POST "$RENDER_DEPLOY_HOOK_URL&imgURL=ghcr.io%2Fbinaayal%2Fpharma_et%2Fapi%3Asha-1a2b3c4d5e6f"
./scripts/smoke-live.sh https://pharmaet-2yw8.onrender.com
```

## 13. The daily summary on Telegram (5 min) — *optional*

Each evening the owner of every pharmacy that asked for it gets the day's summary in
Telegram (ADR-039). It is **off until you do this**, and nothing else depends on it.

1. **Create the bot.** In Telegram, open **@BotFather** → `/newbot` → give it a name
   (e.g. *PharmaEt*) and a username ending in `bot` (e.g. `pharmaet_summary_bot`). BotFather
   replies with a **token** like `1234567890:AA…`. Treat it as a password.
2. **Make a dispatch secret** on your machine: `openssl rand -hex 24`.
3. **Render** → the `pharmaet` service → **Environment** → add, then save (it redeploys):

   | Key | Value |
   |---|---|
   | `TELEGRAM_BOT_TOKEN` | the token from BotFather |
   | `TELEGRAM_BOT_USERNAME` | the bot's username, without `@` |
   | `SUMMARY_DISPATCH_SECRET` | the secret from step 2 |

   On start the server tells Telegram where to deliver what people type to the bot; the log
   says `telegram webhook registered`.
4. **GitHub** → the repository → Settings → Secrets and variables → Actions → **New
   repository secret** → `SUMMARY_DISPATCH_SECRET`, the *same* value as step 2.
5. **Check it.** In the app as the owner: More → **Daily summary on Telegram** → Connect
   Telegram → press **Start** in Telegram → back in the app, **Send today's summary now**.
   Then GitHub → Actions → *daily summary* → **Run workflow**: the run's summary should say
   `HTTP 200` and `"skipped": 1` (it was already sent for today).

**What goes where.** The token is on Render only. The dispatch secret is on Render and in
GitHub. Neither is in the repository, the app, or any log. If the token leaks: BotFather →
`/revoke`, put the new one on Render — the webhook secret is derived from it and rotates
with it.

**When it does not arrive.** Actions → *daily summary* shows each evening's run. `HTTP 404`
means the two copies of the dispatch secret differ. A run that is simply late is GitHub's
scheduler under load. On a paid plan that stays awake, replace the workflow with any
scheduler calling the same endpoint.
