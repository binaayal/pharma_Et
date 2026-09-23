# Runbook

**Implements:** `../06-delivery-plan.md` §6.3 (release health & rollback triggers) and §11
(launch readiness).
**Audience:** whoever is on call. Today that is one person.

> This is written to be followed at 2 a.m. by someone who did not write the code. Every
> section states **the signal**, **what it means**, and **what to do**, in that order.
> Diagnosis before action, because the wrong action here loses a pharmacy's trading records.

---

## 0. The one rule

**A pharmacy that cannot sell is the worst outcome this system can produce.** Worse than a
stale report, worse than a delayed sync, worse than a billing dispute. Every design decision
in this product bends that way — ADR-016 (a suspension never blocks a queued sale), ADR-017
(throttling never locks an account), BR-3.2 (an oversell completes and is flagged), BR-2.3
(an expired offline window never stops a sale).

When an incident forces a judgement call, that is the tie-breaker.

The corollary: **terminals keep working while the server is down.** The app is offline-first.
An API outage is not a retail outage — it is a sync delay. That buys real time, and panicking
into a bad fix costs more than the outage does.

---

## 1. Severity

| Sev | Definition | Response |
|---|---|---|
| **S1** | Data loss, **cross-tenant exposure**, or ledger/audit integrity failure | Immediate rollback + incident. Do not debug forward. |
| **S2** | Pharmacies cannot sync, or cannot sign in, across multiple tenants | Rollback if a deploy is implicated; otherwise fix forward |
| **S3** | One tenant affected; degraded reports; single-terminal problems | Fix forward in hours |
| **S4** | Cosmetic, or an internal-only annoyance | Normal PR flow |

`../06` §6.3: *"a suspected S1 (data loss / cross-tenant / ledger) is an immediate rollback +
incident."* **Suspected**, not confirmed. Rollback first, investigate from the previous image.

---

## 2. Signals to watch

`../06` §6.3 names four. What each one actually means here:

| Signal | Where it comes from | What a breach means |
|---|---|---|
| **Sync failure / retry rate** | non-2xx on `POST /api/sync/push`, and `rejected` acks inside 2xx responses | A 200 with rejected acks is the dangerous case: transport is fine and the data is not landing. Alert on ack status, not just HTTP status. |
| **Oversell count** | rows in `oversell_event` | Expected to be non-zero — BR-3.2 records rather than prevents. A *spike* means either a real stock problem or a sync gap that made terminals disagree. |
| **Error rate / p95 latency** | API logs | NFR-3.4 budgets: sync p95 < 500 ms, dashboard reads p95 < 1 s. |
| **Contract version served** | `GET /api/health` | `supportedContractVersions` must still include N-1 throughout a rolling deploy (ADR-009), or reconnecting terminals are refused. |

> **Status: not yet wired.** There is no alerting stack. These are the signals to instrument
> when there is one, and until then they are checked by hand. `../06` §11 lists
> *"Runbook + monitoring/alerting live"* as a single GA line, and only the runbook half of it
> exists. Saying so here is better than implying a pager exists.

---

## 3. Triage — the first five minutes

```bash
# 1. Is it up, and is it serving the contract window?
curl -s https://<host>/api/health | jq

# 2. Does the whole loop still work, end to end?
API=https://<host>/api ./scripts/smoke.sh

# 3. What changed?
gh run list --branch main --limit 5
fly releases -a pharmaet-staging        # or the production app
```

`smoke.sh` is the fastest honest answer: 18 assertions covering login, sync, isolation,
the authz matrix, the contract window, security headers and throttling. If it is green, the
problem is narrower than it looks.

---

## 4. Playbooks

### 4.1 Suspected cross-tenant exposure — **S1**

**Signal:** a tenant reports seeing another pharmacy's data, or a `g1` suite fails on `main`.

1. **Roll back now** (§5). Do not reproduce in production first.
2. Preserve evidence before anything else — the audit log is append-only and cannot be
   edited, so capture *who read what*:
   ```sql
   SELECT * FROM event WHERE occurred_at > now() - interval '24 hours' ORDER BY occurred_at;
   ```
3. Identify the route. The cross-tenant route sweep
   (`apps/api/test/guardian/g1-cross-tenant-route-sweep.spec.ts`) classifies every route; a
   leak means either a route was added without classification — the sweep fails on that, so
   check whether it was skipped — or RLS was not in force.
4. Confirm RLS is actually binding. The classic cause is the app connecting as the **owner**
   role, which Postgres exempts from RLS entirely (ADR-003/007):
   ```sql
   SELECT current_user;                        -- must be pharmaet_app, NOT the owner
   SELECT relname, relrowsecurity FROM pg_class
    WHERE relname IN ('sale','product','stock_batch');   -- all must be true
   ```
5. Notify affected tenants. This is a personal-data incident, not only a bug.

### 4.2 Ledger or audit integrity alarm — **S1**

**Signal:** `GET /api/audit/verify?streamId=…` reports a gap, or a G3 assertion fails.

The `event` table refuses UPDATE, DELETE and TRUNCATE by trigger, **including for the owner
role**. So a gap does not mean someone edited it; it means something stranger.

1. Check the triggers are still installed and **enabled**. The test harness disables them to
   reset and re-enables them; a crash between the two, run against the wrong database, would
   leave them off:
   ```sql
   SELECT tgname, tgenabled FROM pg_trigger
    WHERE tgrelid = 'event'::regclass AND NOT tgisinternal;   -- tgenabled must be 'O'
   ```
   `tgenabled = 'D'` means **the log has been unprotected**. Treat as S1: re-enable, then
   establish what was written while they were off.
2. If the triggers are intact, the gap is in sequence numbers, not rows — look for a failed
   transaction that consumed a number, which is expected and harmless, versus a missing
   record, which is not.

### 4.3 Sync is failing across tenants — **S2**

**Terminals keep selling.** This is a queue backing up, not a retail outage. Say that to
anyone who calls.

1. `413` on push → the body limit. The contract caps a batch at 500 operations ≈ 770 KB and
   `main.ts` sets 2 MB. If this returns, check `useBodyParser` was not replaced by an
   `app.use(express.json())`, which silently does nothing.
2. `400` with a contract error → an N-1 violation (ADR-009). Check `GET /api/health`:
   `supportedContractVersions` must include what the terminals send. A deploy that narrowed
   the window is the cause; roll back.
3. `200` with `rejected` acks → read the `reason`. `operation tenant does not match the
   authenticated tenant` on legitimate traffic would mean tokens and data have diverged — S1,
   go to §4.1.
4. `402` on push → **this must never happen.** ADR-016 says a suspension blocks management
   writes only, never a queued sale. If a terminal gets 402 from `/sync/push`, the
   `@AllowWhenSuspended()` decorator has been lost from the push route. That exact defect has
   occurred once before. Fix forward immediately; the guardian suite counts the decorator's
   uses.

### 4.4 A pharmacy cannot sign in — **S2/S3**

1. **`429`** — they are throttled (ADR-017). This is working as designed: 5 failed attempts
   per username, 20 per source address, in 15 minutes. It **never** locks an account, and a
   terminal already signed in keeps trading. Tell them to wait, and that the till still works.
   To confirm rather than guess:
   ```sql
   SELECT username, source_ip, count(*) FROM login_attempt
    WHERE succeeded = false AND attempted_at > now() - interval '15 minutes'
    GROUP BY 1, 2 ORDER BY 3 DESC;
   ```
   A successful login clears that identity's failures, so an unlock is simply a correct PIN.
2. **`401` for everyone in one tenant** — check the tenant exists and is not soft-deleted.
   The error is deliberately identical for "no such pharmacy" and "wrong PIN", so the API
   will not tell you which; query directly.
3. **`401` on a route that worked yesterday, with a platform-admin token** — expected. A
   token carrying no tenant is refused by every tenant route (BR-2.2).

### 4.5 Oversell spike — **S3**

Oversells are recorded, not prevented (BR-3.2, G5). A spike is a symptom, not the fault.

```sql
SELECT branch_id, count(*) FROM oversell_event
 WHERE observed_at > now() - interval '24 hours' GROUP BY 1 ORDER BY 2 DESC;
```

Concentrated in one branch → a real stock discrepancy; the pharmacy reconciles with a count
(the `stock_adjustment` path). Spread across many tenants after a deploy → suspect sync, not
stock, and go to §4.3.

### 4.6 A tenant says they are wrongly suspended — **S3**

A suspension blocks management writes only. If they report being unable to *sell* or *sync*,
that is §4.3 and it is a defect, not billing.

```sql
SELECT state, current_period_end, suspended_reason
  FROM subscription WHERE tenant_id = '<id>';
```
Resolve through the platform surface (`POST /api/platform/subscriptions`), not by editing the
row — the endpoint writes the audit event that says who restored it and when.

---

## 5. Rollback

Migrations are **forward-only** (`../06` §6.2). Rollback is redeploying the previous image
onto a database that has already migrated forward — the schema is never reversed.

```bash
fly releases -a <app>                 # find the previous version
fly deploy -a <app> --image ghcr.io/<owner>/<repo>/api:sha-<previous>
curl -s https://<host>/api/health | jq   # confirm it is serving
API=https://<host>/api ./scripts/smoke.sh
```

This is safe because every migration PR proves it in advance: the `rollback_safety` CI job
runs the *base branch's* guardian suites against the *new* schema
([`ci-cd.md`](ci-cd.md) §1.1). If that job passed for the release you are rolling back over,
the previous image runs on the current schema.

**Do not** run `migration:revert` against production. `down()` exists for local iteration and
`InitialSchema` says so.

---

## 6. Restore

> **Status: untested.** `../06` §11 requires *"backups verified by a restore drill"* and no
> drill has been performed. Neon takes its own backups; that is a provider claim, not
> evidence. Until a restore has actually been rehearsed on a throwaway branch and its data
> checked, treat this section as a plan rather than a procedure — and do not discover the
> gaps during an incident.

The drill, when it is run: restore to a new Neon branch, point a local API at it, run
`scripts/smoke.sh`, then verify a known sale and its audit events survived — the ledger is
the thing whose loss cannot be papered over.

---

## 7. What is not yet true

Recorded here rather than in a ticket, because a runbook that overstates its own coverage is
worse than a short one.

- **No alerting.** Nothing pages anyone. The signals in §2 are checked by hand.
- **No restore drill.** §6.
- **No production environment.** The production deploy job deliberately refuses to run until
  `../06` §11 is met ([`staging.md`](staging.md) §2).
- **On-call is one person.** §8 of `../06` assigns platform ops; today that is the owner.
