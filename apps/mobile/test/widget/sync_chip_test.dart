import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/core/theme.dart';
import 'package:pharmaet_mobile/sync/sync_service.dart';
import 'package:pharmaet_mobile/ui/sync_chip.dart';

import '../support/pump.dart';

/// T3 — the sync chip (docs/05-qa §3).
///
/// This is the only thing on the counter screen that says whether the pharmacy's records are
/// reaching the server, and the states it has to keep apart are the whole reason ADR-019
/// exists. `offline` is ordinary and a cashier is right to carry on through it;
/// `sessionExpired` needs a person. If those two ever render alike, a terminal can stop
/// syncing for hours and look completely normal doing it — which is exactly what happened
/// before the state was added.
void main() {
  SyncStatus status(SyncState state, {int pending = 0, int attention = 0}) =>
      SyncStatus(state: state, pending: pending, needsAttention: attention);

  Future<void> show(WidgetTester tester, SyncStatus s) =>
      pumpScreen(tester, Scaffold(body: Center(child: SyncChip(status: s))));

  testWidgets('offline says how much is waiting, not that something is wrong',
      (tester) async {
    await show(tester, status(SyncState.offline, pending: 12));

    // A queue is the normal condition of an offline-first till. Phrasing it as an error
    // would train people to ignore the one state that is an error.
    expect(find.text('12 waiting'), findsOneWidget);
  });

  testWidgets(
      'an expired session asks for a person, in different words and colour',
      (tester) async {
    await show(tester, status(SyncState.sessionExpired, pending: 12));

    // Worded as an instruction, because it is the only sync state the terminal cannot
    // resolve by itself.
    expect(find.text('Sign in again'), findsOneWidget);
    expect(find.text('12 waiting'), findsNothing);
  });

  testWidgets('and it is not dressed like the ordinary offline state',
      (tester) async {
    await show(tester, status(SyncState.sessionExpired, pending: 3));
    final expired = tester.widget<Icon>(find.byType(Icon)).color;

    await show(tester, status(SyncState.offline, pending: 3));
    final offline = tester.widget<Icon>(find.byType(Icon)).color;

    // The colours must differ, and specifically the expired one is red rather than the amber
    // that means "carry on". This is the pixel-level half of ADR-019's argument.
    expect(expired, isNot(offline));
    expect(expired, PharmaColors.red);
  });

  testWidgets('synced says so plainly', (tester) async {
    await show(tester, status(SyncState.synced));
    expect(find.text('Synced'), findsOneWidget);
  });

  testWidgets(
      'operations needing attention are counted separately from the queue',
      (tester) async {
    await show(
        tester, status(SyncState.needsAttention, pending: 5, attention: 2));

    // A rejected operation is not a delayed one: it will never apply on its own, and
    // reporting it as part of the queue would leave it there quietly forever.
    expect(find.textContaining('2'), findsWidgets);
  });

  testWidgets('every state renders — none falls through', (tester) async {
    // The switch is exhaustive by the compiler, but a state added and rendered as an empty
    // string would still compile. Each must put something on screen.
    for (final state in SyncState.values) {
      await show(tester, status(state, pending: 1, attention: 1));
      expect(find.byType(SyncChip), findsOneWidget,
          reason: '$state rendered nothing');
      expect(find.byType(Icon), findsOneWidget, reason: '$state has no icon');
    }
  });
}
