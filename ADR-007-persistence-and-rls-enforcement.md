# ADR-007 — Persistence access via TypeORM with per-request Postgres RLS

**Status:** Accepted · **Date:** 2026-09-21

## Context
ADR-003 requires tenant isolation enforced at **both** the application layer and the
database, with Postgres Row-Level Security (RLS) as the backstop so a single missed scope
in code cannot leak across tenants. RLS policies read the current tenant from a **session
setting** (`current_setting('app.current_tenant')`). For this to be correct, the `SET` and
the queries **must run on the same connection**, which means the data-access layer must give
us explicit connection/transaction control — a hard requirement in a pooled environment.

## Decision
- **ORM: TypeORM** on NestJS.
- **Per-request scoping:** a request-scoped interceptor opens a transaction, executes `SET LOCAL app.current_tenant = $tenantId` (and `app.current_user`, `app.current_branch`), and binds all repository access for that request to that transaction's `EntityManager`. `SET LOCAL` is transaction-scoped, so it cannot leak to another request reusing the pooled connection.
- **RLS policies** on every tenant-scoped table: `USING (tenant_id = current_setting('app.current_tenant')::uuid)`.
- **Platform Admin** access runs through a **separate, least-privilege path** with explicit cross-tenant policies for platform tables only; any admin read of tenant data is explicit and audited (BR-2.2). No blanket `BYPASSRLS` for ordinary code paths.

## Rationale
- TypeORM's QueryRunner/transaction model gives the direct connection control the `SET LOCAL` + RLS pattern needs.
- Prisma is workable but adds friction with pooled connections and session-scoped settings, and abstracts SQL more than is ideal next to the event store and projections.
- Two-layer enforcement (app guard + RLS) means the isolation guarantee survives an application bug.

## Consequences
- **All** domain data access must go through the request-scoped `EntityManager`; direct/unscoped repository use is prohibited and enforced by a lint rule + a "no unscoped access" test (QA gate).
- The event store and projections (ADR-004) use the same scoped access.
- Connection pooling config must respect the one-transaction-per-request pattern.

## Alternatives rejected
- **Prisma** — RLS + session-variable friction with pooling; heavier SQL abstraction.
- **Application-layer scoping only** — rejected by ADR-003; one bug becomes a breach.
- **A tenant-id column filter with no RLS** — same objection; no backstop.
