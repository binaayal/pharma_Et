import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/auth/branch_placement.dart';
import 'package:pharmaet_mobile/auth/session.dart';
import 'package:pharmaet_mobile/contracts/contracts.dart';

/// Which branch a terminal acts in (SRS §2, BR-4.3).
///
/// Found on a phone: an owner is all-branch by role, so their scope carries no branch, and
/// the counter opened with an empty branch id. The pull was refused on the spot, and every
/// sale they rang up would have been refused at push — sitting in the outbox, looking
/// queued, never arriving.
void main() {
  const bole = '01930000-0000-7000-8000-0000000000b1';
  const piassa = '01930000-0000-7000-8000-0000000000b2';
  const closed = '01930000-0000-7000-8000-0000000000b3';

  CachedSession session(List<String> branchIds, {String? placed}) =>
      CachedSession(
        accessToken: 'token',
        refreshToken: 'refresh',
        tenantCode: 'abay',
        offlineValidUntil: DateTime.now().add(const Duration(days: 3)),
        terminalBranchId: placed,
        scope: AuthScope(
          userId: '01930000-0000-7000-8000-000000000003',
          tenantId: '01930000-0000-7000-8000-000000000001',
          role: branchIds.isEmpty ? 'owner' : 'cashier',
          displayName: 'Test',
          branchIds: branchIds,
        ),
      );

  BranchRef branch(String id, {bool deleted = false}) => BranchRef(
        id: id,
        name: id,
        changeSeq: 1,
        deletedAt: deleted ? '2026-01-01T00:00:00.000Z' : null,
      );

  Future<List<BranchRef>> offline() async =>
      throw StateError('the network must not be needed here');

  test('a user with one branch is placed there, without asking the network',
      () async {
    final p =
        await placeTerminal(session: session([bole]), fetchBranches: offline);
    expect((p as Placed).branchId, bole);
  });

  test('a placed terminal opens offline for an owner the next morning',
      () async {
    final p = await placeTerminal(
        session: session([], placed: piassa), fetchBranches: offline);
    expect((p as Placed).branchId, piassa);
  });

  test('an owner with one branch is placed without being asked', () async {
    final p = await placeTerminal(
        session: session([]),
        fetchBranches: () async =>
            [branch(bole), branch(closed, deleted: true)]);
    expect((p as Placed).branchId, bole);
  });

  test('an owner with several branches is asked, and never guessed for',
      () async {
    final p = await placeTerminal(
        session: session([]),
        fetchBranches: () async => [branch(bole), branch(piassa)]);
    expect((p as ChooseBranch).branches.map((b) => b.id), [bole, piassa]);
  });

  test('staff are only offered branches they may act in', () async {
    // A cashier assigned to two branches used to be placed in whichever came first.
    final p = await placeTerminal(
        session: session([bole, piassa]),
        fetchBranches: () async =>
            [branch(bole), branch(piassa), branch(closed)]);
    expect((p as ChooseBranch).branches.map((b) => b.id), [bole, piassa]);
  });

  test('a placement this user may not act in is not honoured', () async {
    final s = session([bole], placed: piassa);
    expect(s.primaryBranchId, bole);
  });

  test('no branch at all says so (AC-1.1)', () async {
    final p = await placeTerminal(
        session: session([]), fetchBranches: () async => []);
    expect(p, isA<NoBranch>());
  });

  test('an unplaced terminal with no network says so rather than guessing',
      () async {
    final p = await placeTerminal(session: session([]), fetchBranches: offline);
    expect(p, isA<PlacementUnreachable>());
  });
}
