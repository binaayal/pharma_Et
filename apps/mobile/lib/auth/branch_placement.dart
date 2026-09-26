import '../contracts/contracts.dart';
import 'session.dart';

/// What the app has to do before the counter can open for [session].
sealed class Placement {
  const Placement();
}

/// Settled: this is the branch every operation on this terminal carries.
class Placed extends Placement {
  const Placed(this.branchId);
  final String branchId;
}

/// Somebody has to say which of these the device is standing in.
class ChooseBranch extends Placement {
  const ChooseBranch(this.branches);
  final List<BranchRef> branches;
}

/// The tenant has no branch this user may act in (AC-1.1: create one first).
class NoBranch extends Placement {
  const NoBranch();
}

/// The branch list could not be fetched. Only reachable on a first placement — a terminal
/// that has been placed before resolves from storage and never needs the network here.
class PlacementUnreachable extends Placement {
  const PlacementUnreachable();
}

/// Decides which branch a terminal acts in (SRS §2, BR-4.3).
///
/// Cheapest answer first, and the network last: a user with exactly one branch, or a
/// terminal already placed somewhere this user may act, opens offline as it always has.
/// Only an unplaced terminal under an all-branch or multi-branch user asks the server —
/// through the pull it already makes, whose `branches` the contract carries for exactly
/// this scope.
Future<Placement> placeTerminal({
  required CachedSession session,
  required Future<List<BranchRef>> Function() fetchBranches,
}) async {
  final settled = session.primaryBranchId;
  if (settled != null) return Placed(settled);

  final List<BranchRef> branches;
  try {
    branches = await fetchBranches();
  } catch (_) {
    return const PlacementUnreachable();
  }

  final allowed = session.scope.branchIds;
  final choices = branches
      .where((b) => b.deletedAt == null)
      .where((b) => allowed.isEmpty || allowed.contains(b.id))
      .toList();

  return switch (choices.length) {
    0 => const NoBranch(),
    1 => Placed(choices.single.id),
    _ => ChooseBranch(choices),
  };
}
