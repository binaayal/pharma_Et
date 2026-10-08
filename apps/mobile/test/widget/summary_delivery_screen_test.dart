import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/ui/kit.dart';
import 'package:pharmaet_mobile/ui/settings_screen.dart';
import 'package:pharmaet_mobile/ui/summary_delivery_screen.dart';

import '../support/terminal.dart';
import '../support/test_db.dart';

/// FR-17 — the daily summary on Telegram, as the owner sets it up (ADR-039).
///
/// The server decides who gets what, and its guardian suite holds that. What is held here
/// is that the screen never claims a connection it has not been told about, never asks the
/// owner to type an address, and says so plainly when the service has no bot at all.
void main() {
  late LocalDb db;
  late Directory dir;

  setUp(() async {
    final opened = await openTestDb();
    db = opened.db;
    dir = opened.dir;
  });

  tearDown(() async {
    debugOpenTelegram = null;
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(720, 1520);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
  }

  /// A server whose state the test can move, recording what was asked of it.
  ({
    MockClient client,
    List<String> calls,
    void Function(Map<String, Object?>) set
  }) server(Map<String, Object?> initial, {bool sendWorks = true}) {
    var state = {...initial};
    final calls = <String>[];
    final client = MockClient((request) async {
      final path = request.url.path;
      calls.add('${request.method} $path');
      http.Response json(Object body, [int code = 200]) =>
          http.Response(jsonEncode(body), code,
              headers: {'content-type': 'application/json'});
      if (path == '/notifications/telegram' && request.method == 'GET') {
        return json(state);
      }
      if (path == '/notifications/telegram/link' && request.method == 'POST') {
        return json({
          'url': 'https://t.me/pharmaet_bot?start=CODE123',
          'expiresAt': '2026-10-07T18:00:00.000Z',
          'asked': jsonDecode(request.body),
        }, 201);
      }
      if (path == '/notifications/telegram/link' &&
          request.method == 'DELETE') {
        state = {...state, 'linked': false, 'linkedAt': null};
        return json({'linked': false});
      }
      if (path == '/notifications/telegram/test') {
        return json({'sent': sendWorks});
      }
      return http.Response('{}', 503);
    });
    return (client: client, calls: calls, set: (s) => state = {...state, ...s});
  }

  const notLinked = {
    'available': true,
    'botUsername': 'pharmaet_bot',
    'linked': false,
    'linkedAt': null,
    'lastSentFor': null,
  };
  const linked = {
    'available': true,
    'botUsername': 'pharmaet_bot',
    'linked': true,
    'linkedAt': '2026-10-07T12:00:00.000Z',
    'lastSentFor': '2026-10-06',
  };

  Future<void> open(WidgetTester tester, http.Client api,
      {String locale = 'en'}) async {
    phone(tester);
    final owner = TestTerminal.build(db, role: 'owner', api: api);
    await pumpTerminalScreen(
        tester, owner.terminal, const SummaryDeliveryScreen(),
        locale: locale);
    await tester.pumpAndSettle();
  }

  PButton button(WidgetTester tester, String label) =>
      tester.widget<PButton>(find.widgetWithText(PButton, label));

  testWidgets('says plainly when the service has no bot, and offers nothing',
      (tester) async {
    final s = server({...notLinked, 'available': false, 'botUsername': null});
    await open(tester, s.client);

    expect(find.textContaining('has not been switched on'), findsOneWidget);
    expect(find.text('Connect Telegram'), findsNothing);
  });

  testWidgets('offline, it says so instead of showing a state it does not know',
      (tester) async {
    await open(
        tester, MockClient((_) async => throw const SocketException('x')));
    expect(find.textContaining('needs a connection'), findsOneWidget);
    expect(find.text('Connect Telegram'), findsNothing);
    expect(find.text('Connected'), findsNothing);
  });

  testWidgets('connecting opens the one-time link, in the till’s language',
      (tester) async {
    final s = server(notLinked);
    Uri? opened;
    debugOpenTelegram = (link) async => opened = link;
    await open(tester, s.client, locale: 'am');

    await tester.tap(find.byType(PButton).first);
    await tester.pumpAndSettle();

    expect('$opened', 'https://t.me/pharmaet_bot?start=CODE123');
    expect(s.calls, contains('POST /notifications/telegram/link'));
  });

  testWidgets('does not say Connected until the server says so',
      (tester) async {
    final s = server(notLinked);
    debugOpenTelegram = (_) async {};
    await open(tester, s.client);
    await tester.tap(find.text('Connect Telegram'));
    await tester.pumpAndSettle();

    // Telegram was opened; nothing has confirmed anything yet.
    expect(find.textContaining('Waiting for you to tap Start'), findsOneWidget);
    expect(find.text('Connected'), findsNothing);

    // Checking before Start was tapped is told the truth.
    await tester.tap(find.textContaining('I tapped Start'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Not connected yet'), findsOneWidget);

    // Start is tapped in Telegram; the server now knows the chat.
    s.set(linked);
    await tester.tap(find.textContaining('I tapped Start'));
    await tester.pumpAndSettle();
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('@pharmaet_bot'), findsOneWidget);
    expect(find.textContaining('Waiting for you'), findsNothing);
  });

  testWidgets('coming back from Telegram looks again without being asked',
      (tester) async {
    final s = server(notLinked);
    debugOpenTelegram = (_) async {};
    await open(tester, s.client);
    await tester.tap(find.text('Connect Telegram'));
    await tester.pumpAndSettle();

    s.set(linked);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Connected'), findsOneWidget);
  });

  testWidgets('connected: says since when, and what was last sent',
      (tester) async {
    await open(tester, server(linked).client);
    expect(find.textContaining('Last sent for 2026-10-06'), findsOneWidget);
    expect(find.text('Connect Telegram'), findsNothing);
  });

  testWidgets('"send it now" reports what happened, either way',
      (tester) async {
    await open(tester, server(linked).client);
    await tester.tap(find.text('Send today’s summary now'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Look in Telegram'), findsOneWidget);
  });

  testWidgets('a send that did not go is not reported as sent', (tester) async {
    await open(tester, server(linked, sendWorks: false).client);
    await tester.tap(find.text('Send today’s summary now'));
    await tester.pumpAndSettle();
    expect(find.textContaining('could not be sent'), findsOneWidget);
    expect(find.textContaining('Look in Telegram'), findsNothing);
  });

  testWidgets('stopping it stops it, and the screen goes back to Connect',
      (tester) async {
    final s = server(linked);
    await open(tester, s.client);
    await tester.tap(find.text('Stop sending it'));
    await tester.pumpAndSettle();

    expect(s.calls, contains('DELETE /notifications/telegram/link'));
    expect(find.textContaining('Nothing more will be sent'), findsOneWidget);
    expect(button(tester, 'Connect Telegram').onPressed, isNotNull);
  });

  testWidgets('tells the owner the figures travel through Telegram',
      (tester) async {
    await open(tester, server(notLinked).client);
    expect(find.textContaining('Telegram carries it'), findsOneWidget);
  });

  group('who is offered it', () {
    testWidgets('the owner, from Settings', (tester) async {
      phone(tester);
      final owner = TestTerminal.build(db, role: 'owner');
      await pumpTerminalScreen(
          tester, owner.terminal, const Scaffold(body: SettingsScreen()));
      expect(find.text('Daily summary on Telegram'), findsOneWidget);
    });

    testWidgets('not a manager, and not a cashier', (tester) async {
      phone(tester);
      for (final role in ['branch_manager', 'cashier']) {
        final t = TestTerminal.build(db, role: role);
        await pumpTerminalScreen(
            tester, t.terminal, const Scaffold(body: SettingsScreen()));
        expect(find.text('Daily summary on Telegram'), findsNothing,
            reason: role);
      }
    });
  });

  testWidgets('in Amharic (AC-10.1)', (tester) async {
    await open(tester, server(notLinked).client, locale: 'am');
    expect(find.text('የዕለቱ ማጠቃለያ በቴሌግራም'), findsOneWidget);
    expect(find.text('Connect Telegram'), findsNothing);
  });
}
