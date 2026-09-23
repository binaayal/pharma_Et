# Architecture Decision Records

An ADR records a significant, hard-to-reverse decision: its **context**, the **decision**,
the **rationale**, the **consequences**, and the **alternatives we rejected and why**.

ADRs are **binding**. Changing one requires a new ADR that supersedes it — you do not
quietly work around an accepted ADR in code.

| ADR | Title | Status |
|-----|-------|--------|
| [ADR-001](ADR-001-platform-and-stack.md) | Platform & technology stack | Accepted |
| [ADR-002](ADR-002-offline-single-writer-first.md) | Single-writer offline in V1; multi-writer deferred to V2 | Accepted |
| [ADR-003](ADR-003-multi-tenancy-isolation.md) | Multi-tenancy isolation model | Accepted |
| [ADR-004](ADR-004-controlled-substance-ledger.md) | Controlled-substance immutable ledger | Accepted |
| [ADR-005](ADR-005-sync-protocol.md) | Sync protocol: hand-rolled REST behind a SyncService seam | Accepted |
| [ADR-006](ADR-006-identifiers-and-offline-writes.md) | Client-generated UUIDv7 identifiers & idempotent offline writes | Accepted |
| [ADR-007](ADR-007-persistence-and-rls-enforcement.md) | Persistence via TypeORM with per-request Postgres RLS | Accepted |
| [ADR-008](ADR-008-risk-tiered-testing.md) | Risk-tiered testing; guardian invariant suites are the CI gate | Accepted |
| [ADR-009](ADR-009-sync-backward-compatibility.md) | Sync API backward-compatibility window for offline clients | Accepted |
| [ADR-010](ADR-010-repository-layout-and-tooling.md) | Repository layout, workspace tooling & contract codegen | Accepted |
| [ADR-011](ADR-011-solo-maintainer-change-control.md) | Change control for a single maintainer | Accepted |
| [ADR-012](ADR-012-extending-the-sync-envelope.md) | Extending the sync envelope; terminal vs server computation | Accepted |
| [ADR-013](ADR-013-permission-matrix-as-contract.md) | The FR-2 permission matrix is a contract artifact | Accepted |
| [ADR-014](ADR-014-calendar-implemented-twice.md) | The Ethiopian calendar is implemented twice, verified once | Accepted |
| [ADR-015](ADR-015-audit-log-before-a1.md) | Event store and audit log built before A-1; the regulated subset is not | Accepted |
| [ADR-016](ADR-016-what-suspension-blocks.md) | What a suspended subscription blocks — management writes only | Accepted |

Status values: Proposed · Accepted · Superseded (by ADR-nnn) · Deprecated
