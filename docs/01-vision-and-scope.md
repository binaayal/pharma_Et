# 01 — Vision & Scope

**Project:** Pharmacy System (working name)
**Document status:** ✅ Draft · owner: Bina
**Depends on:** nothing (this is the root document)
**Feeds:** `02-srs.md`, all ADRs

---

## 1. Business requirements

### 1.1 Problem

Independent pharmacies in Ethiopia — whether a single owner-operated shop or an owner
running several branches — manage their operations on paper, spreadsheets, or fragmented
tools. This produces four concrete, money-losing problems:

1. **Stock blindness** — owners don't know real-time stock levels, what's near expiry, or what's overselling, so they lose money to stockouts, dead stock, and expired drugs written off as waste.
2. **Cash leakage** — with staff handling cash at the counter and no per-shift reconciliation, shrinkage (error and theft) is invisible. This is the owner's single greatest operational fear.
3. **Compliance exposure** — controlled/psychotropic substances carry legal record-keeping and dispensing rules (EFDA). Paper records are hard to audit and easy to lose, creating regulatory and legal risk.
4. **No multi-branch visibility** — owners with more than one store cannot see consolidated stock, sales, or transfers across branches.

### 1.2 Business opportunity

The Ethiopian market has specific structural realities that a purpose-built product can
exploit and that generic foreign pharmacy software ignores:

- **Unreliable power and connectivity** — the counter must keep selling during outages. Offline-first is not a feature; it is the price of entry.
- **No mature payment-gateway integration path** — Telebirr/CBE integration is a 6+ month effort. A product that ships now with manual payment verification beats one that waits.
- **Language and calendar** — Amharic and the Ethiopian calendar are table stakes for adoption, not niceties.
- **Regulatory specificity** — EFDA controlled-substance rules are local; foreign products don't model them.

A product built *for these constraints* is one local pharmacies "can't say no to" — not
because it has the most features, but because it is the only one that keeps working when
the power cuts and that keeps the owner's cash honest.

### 1.3 Business objectives & success metrics

| Objective | V1 success metric |
|-----------|-------------------|
| Prove the core managerial loop is adopted | Paying tenants complete the daily loop (receive → sell → cash-up) on ≥ 80% of operating days |
| Prove offline reliability | Zero data loss across an offline period up to the supported window (see NFR), verified in the field |
| Prove cash control value | Owners report using the per-shift reconciliation report as their primary anti-shrinkage tool |
| Prove the SaaS model | Tenants renew the ETB 1,000/month subscription after the first paid month |
| Prove compliance defensibility | Controlled-substance ledger passes an internal audit dry-run against EFDA record requirements |

### 1.4 Vision statement

> *For* independent Ethiopian pharmacy owners and their staff
> *who* need to run inventory, sales, cash, and compliance reliably across one or many branches, even without power or internet,
> *the* Pharmacy System *is a* multi-tenant, offline-first mobile application (with a web admin dashboard)
> *that* runs the pharmacy's daily managerial workflow and keeps stock, cash, and controlled-substance records accurate and auditable.
> *Unlike* paper, spreadsheets, or generic foreign pharmacy software,
> *our product* is built for Ethiopian power, payment, language, and regulatory realities from the ground up.

---

## 2. Scope & limitations

The governing principle: **V1 is deep on the core loop and reliable offline, not broad.**
Breadth is sequenced into later releases. (See ADR-002 for why the hardest item — multi-writer
offline — is deferred.)

### 2.1 In scope for V1

The **core managerial loop**, delivered to a high standard of reliability and offline resilience:

- **FR-1 Tenant & Branch Management** — a tenant is a pharmacy business; branches belong to a tenant.
- **FR-2 Authentication & Authorization** — RBAC, scoped to tenant *and* branch.
- **FR-3 Inventory Management** — batch/lot with expiry tracking; standard-drug stock is mutable with a negative-stock (oversell-and-reconcile) policy; controlled substances use the immutable ledger (FR-6 / ADR-004).
- **FR-4 Point of Sale / Dispensing** — including psychotropic dispensing rules (dedicated prescription paper, one psychotropic substance per prescription, 15-day validity vs. 30-day standard).
- **FR-6 Controlled Substance Compliance** — append-only immutable audit ledger with regulated retention (ADR-004).
- **FR-7 Purchasing & Goods Receipt** — base purchasing and receipt only. (FR-7a usage-based ordering and FR-7b multi-wholesaler ordering are **deferred**.)
- **FR-8 Reporting & Analytics** — base reports only, **including per-shift cash reconciliation** (see §2.1.1). (FR-8a advanced/custom reporting and export is **deferred**.)
- **FR-9 Offline Sync Engine — single-writer tier only** (one terminal per branch, no concurrent writers; ADR-002).
- **FR-10 Localization** — Amharic/English, Ethiopian calendar.

#### 2.1.1 Additions folded into V1 (not in the original FR list — and they belong here)

These are core to the stated purpose ("the managerial workflow of a pharmacy owner") and
were missing by omission:

- **Per-shift cash reconciliation (cash-up / Z-report)** — counted cash vs. system-expected cash, per staff member, per shift. This is the owner's primary anti-shrinkage control and the strongest single reason to adopt. Treated as part of FR-8 base reporting.
- **General action audit log** — who did what, when (not only controlled substances). Owner trust in staff *is* the product. Treated as part of FR-6's infrastructure, generalized.

### 2.2 Deferred (built later, deliberately not in V1)

Each of these is deferred for a stated reason, not forgotten:

| Item | Deferred to | Why |
|------|-------------|-----|
| **FR-9 multi-writer offline + conflict resolution (NFR-2)** | V2 | Highest-risk piece in the system; most independent pharmacies run one terminal. Offline concurrent writes can *detect* but never *prevent* oversell — see ADR-002. |
| **FR-5 Inter-branch stock transfer** | V1.x, **online-only** | Fundamentally incompatible with a long offline window (you'd dispatch stock already consumed). It's a back-office act by the owner, not a counter transaction under a power cut. |
| **FR-7a usage-based ordering, FR-7b multi-wholesaler ordering** | V1.x / V2 | Analytics-grade features that need sales history to be useful; ship after the loop is proven. |
| **FR-8a advanced/custom reporting & export** | V1.x | Base reports validate the model; advanced reporting is polish. |
| **Desktop application** | V1.x / V2 (Flutter Desktop, Windows-first) | Counter and owner oversight both run on Android — the prototype puts Home, Reports and Branches & staff in the phone app, and the web console is the platform's (screens 20–26). See ADR-001. |
| **Telebirr / CBE payment integration** | Post-V1 (6+ month effort) | V1 uses manual screenshot verification via the web admin dashboard. |

### 2.3 Non-goals (explicitly out of scope, not merely deferred)

- **Prescription management integration** (doctor-to-pharmacy workflow). V1 handles dispensing-time *compliance rules* (FR-4), not e-prescription pipelines.
- **Customer lifecycle / loyalty / refill reminders.** The product serves the *owner's operations*, not end-customer engagement. (A simple customer *credit ledger* may be reconsidered later — credit sales are common in Ethiopian retail — but it is not a V1 goal.)
- **End-customer-facing app.** The system is used only by pharmacy owners and their staff.

---

## 3. Users & stakeholders

| Persona | Surface | Needs | Notes |
|---------|---------|-------|-------|
| **Pharmacist / counter staff** | Mobile (Flutter) | Fast, offline-capable POS; dispensing that enforces compliance rules without slowing them down | Primary daily user; must work under power cuts; Android is the primary device |
| **Pharmacy owner** | Mobile + web dashboard | Consolidated stock/sales/cash visibility; per-shift reconciliation; multi-branch view | The buyer. Adoption decision is theirs. |
| **Branch manager** (multi-branch tenants) | Mobile + web | Branch-scoped operations and reporting | A branch-scoped subset of owner capability |
| **Platform admin (us)** | Web admin dashboard | Onboard tenants, verify payment screenshots, unlock/suspend subscriptions | Operates the SaaS; the human in the manual-payment loop |

RBAC must express: *this user, in this tenant, at this/these branch(es), may do these things.*
Tenant scope and branch scope are **both** enforced (ADR-003).

---

## 4. Business context — Ethiopian constraints

These are hard constraints. Every downstream decision must respect them.

- **Power & connectivity:** intermittent. Supported offline window is defined in the SRS (NFR). The counter must never stop selling because the network is down.
- **Payment:** no gateway integration in V1. Tenants pay ETB 1,000/month; they submit a payment screenshot; platform admin verifies it on the web dashboard and unlocks/renews the subscription. `[ASSUMPTION]` this manual flow is acceptable to early tenants — validate in pilot.
- **Regulatory:** controlled/psychotropic substances are governed by EFDA rules, including dispensing constraints (FR-4) and record retention (ADR-004). See §7 — these are `[ASSUMPTION]` pending compliance verification.
- **Language & calendar:** Amharic and English; Ethiopian calendar in all user-facing dates. Storage remains UTC ISO-8601; conversion is a presentation concern.

---

## 5. Product decisions locked (V1)

These are settled. Rationale and rejected alternatives live in the ADRs.

- **Stack:** Flutter (mobile: Android primary target, iOS from same codebase) · NestJS + PostgreSQL backend · web admin dashboard · desktop deferred. → **ADR-001**
- **Offline:** single-writer per terminal in V1; multi-writer + conflict engine deferred to V2. → **ADR-002**
- **Multi-tenancy:** single PostgreSQL, row-level isolation on `tenant_id` + `branch_id`, enforced at both the database (RLS) and application layers. → **ADR-003**
- **Controlled substances:** append-only, event-sourced immutable ledger with tombstone deletes and regulated retention; the rest of inventory is standard mutable state with soft-delete. → **ADR-004**
- **Pricing/billing:** ETB 1,000/month, manual screenshot verification via web admin dashboard.

---

## 6. Guiding principles (the quality bar)

1. **The daily loop never breaks.** Offline resilience of receive → sell → cash-up outranks every feature.
2. **Never lose a regulated record.** Controlled-substance and financial records are append-only / soft-delete; the sync layer treats deletes as tombstones, never physical removals.
3. **Sequence by risk, not by excitement.** Build the sync spine (a walking skeleton) before breadth.
4. **Scope discipline is a feature.** Every deferred item has a written reason; nothing is smuggled into V1.
5. **Documentation is executable intent.** These docs bind engineers and Claude Code alike; an ADR is not a suggestion.

---

## 7. Assumptions, risks & open questions

| ID | Type | Statement | Owner | Resolution |
|----|------|-----------|-------|------------|
| A-1 | `[ASSUMPTION]` | EFDA directive No. 1121/2025 requires ≥ 5-year retention for controlled-substance records; psychotropic dispensing rules are as stated in FR-4. **Must be verified by a compliance/legal review before build.** ⛔ Still unverified — directive **872/2022** was reviewed on 2026-09-23 and covers import/export/wholesale, not retail dispensing (`compliance-sign-off.md` §2). | Bina | Before SRS freeze |
| A-4 | `[ASSUMPTION]` → ✅ **verified** | Electronic records satisfy EFDA record-keeping duties. Confirmed by directive 872/2022 Art. 29 §1(l): records may be kept "in a paper copy **or electronically**". | Bina | Closed 2026-09-23 |
| A-2 | `[ASSUMPTION]` | Manual screenshot payment verification is acceptable to early tenants. | Bina | Pilot |
| A-3 | `[ASSUMPTION]` | The large majority of target pharmacies operate a single POS terminal per branch (validates single-writer V1). | Bina | Pilot / market check |
| R-1 | Risk | Offline sync of conservation-law inventory is the project's dominant technical risk. | Eng | De-risk via walking-skeleton spike before breadth |
| R-2 | Risk | iOS ships from the shared Flutter codebase but adds Apple account/review/device test overhead for a small Ethiopian user share. Android is the priority build/test target. | Eng | Track cost in delivery plan |
| O-1 | `[OPEN]` | Exact supported offline window (candidate: up to 7 days) and what "supported" guarantees. | Eng + Bina | SRS (NFR) |
| O-2 | `[OPEN]` | Does a V1 tenant need a customer credit ledger for credit sales? | Bina | Post-pilot |

---

## 8. Release strategy

- **V1 (core loop, single-writer offline):** FR-1–4, FR-6, FR-7 (base), FR-8 (base + cash reconciliation), FR-9 (single-writer), FR-10. Mobile + web admin. **Preceded by a walking-skeleton spike** proving the offline sync spine end-to-end for one tenant/branch/terminal.
- **V1.x:** inter-branch transfer (online-only, FR-5), advanced/custom reporting (FR-8a), desktop app.
- **V2:** multi-writer offline + conflict-resolution engine (FR-9 full + NFR-2), usage-based & multi-wholesaler ordering (FR-7a/b).
- **Post-V1 track (parallel):** Telebirr/CBE payment integration.
