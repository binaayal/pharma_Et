import { CAPABILITIES, PERMISSION_MATRIX } from '../permissions.js';

/**
 * Emits the FR-2 permission matrix as Dart.
 *
 * Generated rather than hand-written for the same reason the sync envelope is (ADR-010):
 * AC-2.1 requires the denial at both the app and the API layer, two layers enforcing one
 * table means two copies, and two copies drift — usually in the direction where the app
 * offers something the server refuses, which a user reads as the product being broken.
 */
export function emitPermissionsDart(contractVersion: string): string {
  const roles = Object.keys(PERMISSION_MATRIX) as Array<keyof typeof PERMISSION_MATRIX>;

  const capabilityConsts = CAPABILITIES.map(
    (c) => `  static const String ${dartName(c)} = '${c}';`,
  ).join('\n');

  const matrix = roles
    .map((role) => {
      const cells = CAPABILITIES.map(
        (c) => `    '${c}': Grant.${PERMISSION_MATRIX[role][c]},`,
      ).join('\n');
      return `  '${role}': <String, Grant>{\n${cells}\n  },`;
    })
    .join('\n');

  return `// GENERATED FILE — DO NOT EDIT.
//
// The FR-2 permission matrix, generated from packages/contracts/src/permissions.ts by
// \`pnpm gen:contracts\`. Edit it there; CI fails if this file is stale (ADR-010).
//
// AC-2.1 requires a denial at both the app and the API layer. Both read this one table, so
// the app cannot offer something the server will refuse.
//
// Contract version: ${contractVersion}

// ignore_for_file: lines_longer_than_80_chars

/// How far a capability reaches for a role.
///
/// The distinction between [tenant] and [branch] is the one that matters and the one that
/// gets lost: both mean "allowed", and treating them alike lets a branch manager act across
/// a tenant they only partly run.
///
/// [own] is narrower still — the actor's own records only — and cannot be decided from the
/// role alone, because the grant knows the role and the data knows the owner.
enum Grant { tenant, branch, own, denied }

/// Capability names, matching the server's exactly.
abstract final class Capability {
${capabilityConsts}
}

const Map<String, Map<String, Grant>> kPermissionMatrix = <String, Map<String, Grant>>{
${matrix}
};

/// The grant a role holds for a capability. Unknown role or capability is [Grant.denied] —
/// failing closed, because an unrecognised name is far more likely to be a typo than a
/// reason to allow something.
Grant grantFor(String role, String capability) =>
    kPermissionMatrix[role]?[capability] ?? Grant.denied;

/// Whether a role may do something at all. Use [grantFor] when the scope matters.
bool isAllowed(String role, String capability) => grantFor(role, capability) != Grant.denied;
`;
}

function dartName(capability: string): string {
  return capability.replace(/[.](\w)/g, (_, c: string) => c.toUpperCase());
}
