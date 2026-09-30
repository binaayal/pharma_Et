import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/ui/help_screen.dart';
import 'package:pharmaet_mobile/ui/subscription_screens.dart';

import '../support/pump.dart';
import '../support/terminal.dart';
import '../support/test_db.dart';

/// T3 — the user guide and the pay-to accounts (FR-10, Vision §4).
///
/// Both exist for a person who is stuck: one cannot work out the app, the other has a
/// lapsed subscription and does not know where to send the money.
void main() {
  group('help & user guide', () {
    testWidgets('opens without a session, in English', (tester) async {
      await pumpScreen(tester, const HelpScreen());
      expect(find.text('Help & user guide'), findsOneWidget);
      expect(find.text('Getting started'), findsOneWidget);
    });

    testWidgets('reads in Amharic (AC-10.1)', (tester) async {
      await pumpScreen(tester, const HelpScreen(), locale: 'am');
      expect(find.text('እገዛና የአጠቃቀም መመሪያ'), findsOneWidget);
      expect(find.text('መጀመሪያ'), findsOneWidget);
    });

    testWidgets('search narrows the topics to what was asked', (tester) async {
      await pumpScreen(tester, const HelpScreen());
      await tester.enterText(find.byType(TextField), 'telebirr');
      await tester.pump();
      expect(find.text('Subscription and payment'), findsOneWidget);
      expect(find.text('Getting started'), findsNothing);
    });

    testWidgets('can open straight onto the payment topic', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await pumpScreen(tester, const HelpScreen(initialTopic: 'payment'));
      await tester.scrollUntilVisible(find.textContaining('1000473026922'), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.textContaining('1000473026922'), findsOneWidget);
    });
  });

  group('paying the subscription', () {
    late LocalDb db;
    late Directory dir;
    late TestTerminal t;

    setUp(() async {
      final opened = await openTestDb();
      db = opened.db;
      dir = opened.dir;
      t = TestTerminal.build(db, role: 'owner');
    });

    tearDown(() async {
      await db.close();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    testWidgets('shows the CBE account, name and a copy button',
        (tester) async {
      await pumpTerminalScreen(tester, t.terminal, const PaymentProofScreen());
      expect(find.text('1000473026922'), findsOneWidget);
      expect(find.text('Account name: Binyam Ayalneh Zerihun'), findsOneWidget);
      expect(find.byTooltip('Copy account number'), findsOneWidget);
    });

    testWidgets('switches to the Telebirr account', (tester) async {
      await pumpTerminalScreen(tester, t.terminal, const PaymentProofScreen());
      await tester.tap(find.text('Telebirr'));
      await tester.pump();
      expect(find.text('0902432346'), findsOneWidget);
      expect(find.text('1000473026922'), findsNothing);
    });

    testWidgets('copies the number to the clipboard', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      await pumpTerminalScreen(tester, t.terminal, const PaymentProofScreen());
      await tester.tap(find.byTooltip('Copy account number'));
      await tester.pump();
      expect(copied, '1000473026922');
    });
  });
}
