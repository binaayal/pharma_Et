import '../contracts/permissions.dart';

export '../contracts/permissions.dart'
    show Capability, Grant, grantFor, isAllowed;

/// Convenience wrappers over the generated FR-2 matrix.
///
/// AC-2.1 requires a capability denial at **both** the app and the API layer. The app half
/// is not a security boundary — anybody can talk to the API directly, and the server
/// enforces the same table independently — but it is a correctness boundary. An app that
/// offers an action the server will refuse produces a user who believes the product is
/// broken, and a support conversation that starts three steps away from the real answer.
///
/// So the rule here is: **if the matrix denies it, do not render the control at all.**
/// Showing a disabled button teaches people to hunt for the way to enable it.
extension CapabilityChecks on String {
  /// `role.can(Capability.catalogManage)`
  bool can(String capability) => isAllowed(this, capability);

  /// The reach of a capability for this role, when it matters where it applies.
  Grant reach(String capability) => grantFor(this, capability);
}

/// Whether a role may act in a branch for a capability.
///
/// A `tenant` grant reaches every branch; a `branch` or `own` grant reaches only the
/// branches the user is assigned to. The server checks this again — the client's copy
/// exists to keep the UI honest, not to be trusted.
bool canActInBranch({
  required String role,
  required String capability,
  required String branchId,
  required List<String> assignedBranchIds,
}) {
  switch (grantFor(role, capability)) {
    case Grant.denied:
      return false;
    case Grant.tenant:
      return true;
    case Grant.branch:
    case Grant.own:
      return assignedBranchIds.contains(branchId);
  }
}
