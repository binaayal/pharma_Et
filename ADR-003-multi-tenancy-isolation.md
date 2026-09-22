# ADR-003 — Multi-tenancy isolation model

**Status:** Accepted · **Date:** 2026-09-21

## Context

The system is multi-tenant SaaS targeting ~1,000 tenants (pharmacy businesses), each with
one or more branches. Isolation must be strong enough for a regulated domain (controlled-substance
records, financial data) while remaining operationally sane at 1,000 tenants. A tenant with
multiple branches also needs isolation *between its own branches* for scoped access, without
being a separate tenant.

## Decision

- **Single PostgreSQL database, shared schema, row-level isolation.** Every tenant-owned domain row carries `tenant_id` and, where applicable, `branch_id`.
- **Isolation is enforced at two layers:**
  1. **Database:** PostgreSQL **Row-Level Security (RLS)** policies keyed on the current tenant, so a query can never read across tenants even if application code is buggy.
  2. **Application:** a mandatory tenant/branch scoping guard in NestJS (e.g. request-scoped context injected into every query), so no repository method runs unscoped.
- **RBAC is tenant- *and* branch-scoped** (FR-2): a permission check answers "this user, in this tenant, at this/these branch(es), may do this."

## Rationale

- At 1,000 tenants, **DB-per-tenant** means 1,000 databases to migrate, back up, and monitor — operationally brutal for a small team, with no isolation benefit that RLS + app guard don't provide for this risk profile.
- **Schema-per-tenant** eases some isolation but makes migrations across 1,000 schemas fragile and slow.
- Shared-schema + RLS is the industry-standard sweet spot at this scale: one migration path, defense-in-depth isolation, straightforward cross-tenant platform analytics for the admin dashboard.
- Two-layer enforcement means a single missed `where tenant_id = ?` in code does not become a cross-tenant data breach — RLS is the backstop.

## Consequences

- Every domain table and query must include tenant (and branch, where relevant) scoping; this is enforced by convention **and** RLS, and must be covered by tests (a "no unscoped query" test is part of QA strategy).
- The web admin dashboard operates *above* tenant scope (it manages tenants); it uses a distinct, tightly controlled access path, not a tenant session.
- Backups and retention (ADR-004) operate on the shared database; per-tenant export for offboarding is an application-level concern, not a physical DB boundary.
- Noisy-neighbour risk is shared-infrastructure; acceptable at target scale, revisited if a tenant's load profile demands it.

## Alternatives rejected

- **Database-per-tenant** — rejected: operational cost at 1,000 tenants outweighs the isolation gain given RLS.
- **Schema-per-tenant** — rejected: migration fragility at scale.
- **Application-layer scoping only (no RLS)** — rejected: one code bug becomes a cross-tenant breach in a regulated domain. RLS is non-negotiable as the backstop.
