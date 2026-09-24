import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/auth/branch_placement.dart';
import 'package:pharmaet_mobile/contracts/contracts.dart';
import 'package:pharmaet_mobile/ui/branch_picker_screen.dart';

import '../support/pump.dart';

/// T3 — placing a terminal at a branch (SRS §2, BR-4.3).
void main() {
  Future<String?> pick(WidgetTester tester, Placement placement) async {
    String? chosen;
    await pumpScreen(
      tester,
      BranchPickerScreen(
        placement: placement,
        onChosen: (id, _) => chosen = id,
        onRetry: () {},
        onSignOut: () {},
      ),
    );
    if (placement is ChooseBranch) {
      await tester.tap(find.text('Piassa Branch'));
      await tester.pump();
    }
    return chosen;
  }

  testWidgets('lists the branches and records the one tapped', (tester) async {
    final chosen = await pick(
      tester,
      const ChooseBranch([
        BranchRef(id: 'b1', name: 'Bole Branch', changeSeq: 1),
        BranchRef(id: 'b2', name: 'Piassa Branch', changeSeq: 2),
      ]),
    );
    expect(find.text('Bole Branch'), findsOneWidget);
    expect(chosen, 'b2');
  });

  testWidgets('with no network, says a connection is needed once',
      (tester) async {
    await pick(tester, const PlacementUnreachable());
    expect(find.textContaining('Connect to the internet once'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('with no branch, points at the owner console (AC-1.1)',
      (tester) async {
    await pick(tester, const NoBranch());
    expect(find.textContaining('no branch yet'), findsOneWidget);
  });
}
