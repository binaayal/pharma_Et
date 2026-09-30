import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/ui/delete_account_screen.dart';
import 'package:pharmaet_mobile/ui/settings_screen.dart';

import '../support/pump.dart';
import '../support/terminal.dart';
import '../support/test_db.dart';

/// What Google Play and the App Store check before they publish (docs/store/README.md):
/// the privacy policy and account deletion are reachable from inside the app, not only from
/// the listing — and deletion is offered to the one person who may ask for it.
void main() {
  late LocalDb db;
  late Directory dir;

  setUp(() async {
    final opened = await openTestDb();
    db = opened.db;
    dir = opened.dir;
  });

  tearDown(() async {
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> openSettings(WidgetTester tester, String role) async {
    tester.view.physicalSize = const Size(1080, 3200);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final t = TestTerminal.build(db, role: role);
    await pumpTerminalScreen(
        tester, t.terminal, const Scaffold(body: SettingsScreen()));
  }

  testWidgets('an owner can reach the privacy policy and account deletion',
      (tester) async {
    await openSettings(tester, 'owner');
    expect(find.text('Privacy policy'), findsOneWidget);
    expect(find.text('Delete account'), findsOneWidget);
    expect(find.text('Help & user guide'), findsOneWidget);
  });

  testWidgets(
      'a cashier sees the privacy policy but cannot delete the pharmacy',
      (tester) async {
    await openSettings(tester, 'cashier');
    expect(find.text('Privacy policy'), findsOneWidget);
    expect(find.text('Delete account'), findsNothing);
  });

  testWidgets(
      'the deletion screen says what goes and what stays, in Amharic too',
      (tester) async {
    await pumpScreen(tester, const DeleteAccountScreen(), locale: 'am');
    expect(find.text('የሚሰረዙ'), findsOneWidget);
    expect(find.text('ሕግ በሚያስገድድበት ብቻ የሚቆዩ'), findsOneWidget);
    expect(find.text('መለያውን ለመሰረዝ ድጋፍን ይደውሉ'), findsOneWidget);
  });
}
