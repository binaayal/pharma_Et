import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/ui/kit.dart';
import 'package:pharmaet_mobile/ui/owner_screens.dart';

import '../support/terminal.dart';
import '../support/test_db.dart';

/// FR-17 — the two screens an absent owner opens in the evening.
void main() {
  late LocalDb db;
  late Directory dir;

  setUp(() async {
    final opened = await openTestDb();
    db = opened.db;
    dir = opened.dir;
  });

  tearDown(() async {
    debugShareSummary = null;
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 4400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  Map<String, dynamic> shift(String name, int? variance) => {
        'shiftId': 's-$name',
        'branchName': 'Bole',
        'userName': name,
        'openedAt': '2026-10-07T05:00:00.000Z',
        'closedAt': variance == null ? null : '2026-10-07T15:00:00.000Z',
        'countedSantim': variance == null ? null : 2150000 + variance,
        'expectedSantim': variance == null ? null : 2150000,
        'varianceSantim': variance,
      };

  Map<String, dynamic> summary(
          {int shortage = 0,
          int overage = 0,
          int open = 0,
          List<Map<String, dynamic>> shifts = const []}) =>
      {
        'sales': {
          'saleCount': 42,
          'grossSantim': 1240000,
          'cashSantim': 910000,
          'otherTenderSantim': 200000,
          'creditSantim': 130000,
          'itemsSold': 96,
        },
        'cash': {
          'countedShifts':
              shifts.where((s) => s['varianceSantim'] != null).length,
          'countedSantim': 0,
          'shortageSantim': shortage,
          'overageSantim': overage,
          'openShifts': open,
        },
        'shifts': shifts,
        'credit': {
          'repaidSantim': 80000,
          'owedSantim': 540000,
          'customersOwing': 3
        },
        'stock': {
          'lowCount': 1,
          'low': [
            {
              'productId': 'a',
              'productName': 'Amoxicillin 500mg',
              'unit': 'capsule',
              'onHand': 3
            },
          ],
          'expiringBatches': 2,
          'oversoldBatches': 0,
        },
        'attention': {
          'priceChanges': 1,
          'stockWriteOffs': 0,
          'expiredDispenses': 0
        },
        'lastSyncedAt': '2026-10-07T15:00:00.000Z',
      };

  group('today\'s summary', () {
    Future<List<Uri>> open(WidgetTester tester, Map<String, dynamic>? body,
        {String role = 'owner', String locale = 'en'}) async {
      tall(tester);
      final asked = <Uri>[];
      final t =
          TestTerminal.build(db, role: role, api: MockClient((request) async {
        asked.add(request.url);
        if (body == null) return http.Response('{}', 503);
        return http.Response(jsonEncode(body), 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }));
      await pumpTerminalScreen(tester, t.terminal,
          DailySummaryScreen(today: DateTime(2026, 10, 7, 19)),
          locale: locale);
      await tester.pumpAndSettle();
      return asked;
    }

    testWidgets('asks the server for the shop\'s own day, midnight to midnight',
        (tester) async {
      final asked = await open(tester, summary());
      final from = DateTime.parse(asked.single.queryParameters['from']!);
      final to = DateTime.parse(asked.single.queryParameters['to']!);

      expect(asked.single.path, '/reports/daily-summary');
      expect(from.toLocal(), DateTime(2026, 10, 7));
      expect(to.difference(from), const Duration(days: 1));
    });

    testWidgets('a balanced day says so', (tester) async {
      await open(
          tester, summary(shifts: [shift('Hana', 0), shift('Dawit', 0)]));

      expect(find.text('Tills counted, none short: 2.'), findsOneWidget);
      expect(find.text('exact'), findsNWidgets(2));
      expect(find.text('Amoxicillin 500mg'), findsOneWidget);
      expect(find.text('Price changes: 1'), findsOneWidget);
    });

    testWidgets('a shortage leads, and an overage does not soften it',
        (tester) async {
      await open(
          tester,
          summary(
              shortage: 5000,
              overage: 3000,
              shifts: [shift('Hana', -5000), shift('Dawit', 3000)]));

      expect(find.text('Cash is short by 50.00.'), findsOneWidget);
      expect(find.text('none short'), findsNothing);
      // Each till on its own line, with its own figure.
      expect(find.text('-50.00'), findsOneWidget);
      expect(find.text('short'), findsOneWidget);
      expect(find.text('30.00'), findsOneWidget);
      expect(find.text('over'), findsOneWidget);
    });

    testWidgets('a till nobody counted is shown as still open', (tester) async {
      await open(tester, summary(open: 1, shifts: [shift('Hana', null)]));
      expect(find.textContaining('still open and not counted'), findsOneWidget);
      expect(find.text('still open'), findsOneWidget);
    });

    testWidgets('says how fresh it is', (tester) async {
      await open(tester, summary());
      // Reports reflect synced data (BR-8.1); the screen must not pass as live.
      expect(find.byIcon(Icons.schedule), findsWidgets);
    });

    testWidgets('yesterday asks for the day before', (tester) async {
      final asked = await open(tester, summary());
      await tester.tap(find.text('Yesterday'));
      await tester.pumpAndSettle();

      final from = DateTime.parse(asked.last.queryParameters['from']!);
      expect(from.toLocal(), DateTime(2026, 10, 6));
    });

    testWidgets('shares the day as text', (tester) async {
      String? shared;
      debugShareSummary = (text) async => shared = text;
      await open(
          tester, summary(shortage: 5000, shifts: [shift('Hana', -5000)]));

      await tester.tap(find.text('Share this summary'));
      await tester.pump();

      expect(shared, contains('Bole — '));
      expect(shared, contains('Sales: 42 · ETB 12,400'));
      expect(shared, contains('Cash is short by 50.00.'));
      expect(shared, contains('On shift: Hana'));
    });

    testWidgets('with no connection it says so, and offers nothing to share',
        (tester) async {
      await open(tester, null);
      expect(find.textContaining('needs a connection'), findsOneWidget);
      expect(find.text('Share this summary'), findsNothing);
    });

    testWidgets('in Amharic (AC-10.1)', (tester) async {
      await open(
          tester, summary(shortage: 5000, shifts: [shift('Hana', -5000)]),
          locale: 'am');
      expect(find.text('የዛሬ ማጠቃለያ'), findsOneWidget);
      expect(find.text('ጥሬ ገንዘቡ በ50.00 ጎድሏል።'), findsOneWidget);
    });
  });

  group('the activity log', () {
    final entries = [
      {
        'eventType': 'audit.price_changed',
        'occurredAt': '2026-10-07T20:00:00.000Z',
        'actorName': 'Hana',
        'payload': {
          'productName': 'Paracetamol 500mg',
          'previousPriceSantim': 600,
          'priceSantim': 500,
        },
      },
      {
        'eventType': 'audit.stock_adjusted',
        'occurredAt': '2026-10-07T18:00:00.000Z',
        'actorName': 'Dawit',
        'payload': {
          'productId': 'p1',
          'delta': -12,
          'reason': 'damage',
          'note': 'dropped a box',
        },
      },
      {
        'eventType': 'audit.user_created',
        'occurredAt': '2026-10-06T09:00:00.000Z',
        'actorName': null,
        'payload': {'username': 'selam', 'role': 'cashier'},
      },
      {
        'eventType': 'audit.price_changed',
        'occurredAt': '2026-10-05T09:00:00.000Z',
        'actorName': 'Hana',
        'payload': {
          'productName': 'Amoxicillin 500mg',
          'previousPriceSantim': 400,
          'priceSantim': 450,
        },
      },
    ];

    Future<void> open(WidgetTester tester, {bool online = true}) async {
      tall(tester);
      final t = TestTerminal.build(db,
          role: 'owner',
          api: MockClient((request) async => online
              ? http.Response(jsonEncode(entries), 200,
                  headers: {'content-type': 'application/json; charset=utf-8'})
              : http.Response('{}', 503)));
      t.addProduct('p1', 'Cetirizine 10mg');
      await pumpTerminalScreen(tester, t.terminal, const AuditScreen());
      await tester.pumpAndSettle();
    }

    List<String> sentences(WidgetTester tester) =>
        tester.widgetList<PRow>(find.byType(PRow)).map((r) => r.title).toList();

    testWidgets('reads as sentences, newest first, with who did it',
        (tester) async {
      await open(tester);

      expect(sentences(tester), [
        'Price of Paracetamol 500mg changed from 6.00 to 5.00',
        // The product id resolved from this phone's catalogue.
        '12 of Cetirizine 10mg taken off the count — damaged',
        'selam added as Cashier',
        'Price of Amoxicillin 500mg changed from 4.00 to 4.50',
      ]);
      expect(find.textContaining('Hana · '), findsNWidgets(2));
      expect(find.textContaining('“dropped a box”'), findsOneWidget);
      // Done by the platform, not by one of their own people — and said so.
      expect(find.textContaining('PharmaEt · '), findsOneWidget);
    });

    testWidgets('can be narrowed to prices, stock or staff', (tester) async {
      await open(tester);
      await tester.tap(find.text('Stock'));
      await tester.pump();
      expect(sentences(tester),
          ['12 of Cetirizine 10mg taken off the count — damaged']);

      await tester.tap(find.text('Staff'));
      await tester.pump();
      expect(sentences(tester), ['selam added as Cashier']);
    });

    testWidgets('can show only what is worth a second look', (tester) async {
      await open(tester);
      await tester.tap(find.textContaining('worth a second look'));
      await tester.pump();

      // The price that went down and the write-off — not the price that went up, and
      // not the new member of staff.
      expect(sentences(tester), [
        'Price of Paracetamol 500mg changed from 6.00 to 5.00',
        '12 of Cetirizine 10mg taken off the count — damaged',
      ]);
    });

    testWidgets('says it cannot be edited, and offers no way to try',
        (tester) async {
      await open(tester);
      expect(find.textContaining('cannot be edited or deleted by anyone'),
          findsOneWidget);
      expect(find.byType(PButton), findsNothing);
      expect(find.byIcon(Icons.delete_outline), findsNothing);
    });

    testWidgets(
        'with no connection it says so rather than showing an empty log',
        (tester) async {
      await open(tester, online: false);
      expect(find.textContaining('needs a connection'), findsOneWidget);
      // "Nothing to show" here would read as "nobody did anything".
      expect(find.text('Nothing to show here.'), findsNothing);
    });
  });

  group('who is offered what', () {
    testWidgets('the activity log is the owner\'s alone', (tester) async {
      final owner = TestTerminal.build(db, role: 'owner');
      final manager = TestTerminal.build(db, role: 'branch_manager');
      expect(canReadAudit(owner.terminal), isTrue);
      // The server refuses a manager too (ADR-015): a manager reading the record of
      // their own staff is a different thing from an owner reviewing the business.
      expect(canReadAudit(manager.terminal), isFalse);
      expect(canReadAudit(TestTerminal.build(db, role: 'cashier').terminal),
          isFalse);
    });
  });
}
