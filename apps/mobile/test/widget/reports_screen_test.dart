import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/ui/reports_screen.dart';

import '../support/terminal.dart';
import '../support/test_db.dart';

/// Reports — the headline an owner glances at (FR-8).
///
/// Found on a real phone: this tab is kept alive behind the others, loaded its figures
/// once, and went on showing "ETB 0 · 0 sales" after a sale had been rung up and synced.
/// A number that was true an hour ago, shown as today's, is worse than no number.
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

  testWidgets('reloads when the terminal\'s data moves, not only when opened',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 3600);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    var gross = 0;
    var summaryCalls = 0;
    final t =
        TestTerminal.build(db, role: 'owner', api: MockClient((request) async {
      if (request.url.path == '/reports/sales-summary') {
        summaryCalls++;
        return http.Response(
            jsonEncode({
              'from': '2026-10-07T00:00:00.000Z',
              'to': '2026-10-08T00:00:00.000Z',
              'branches': <Object>[],
              'total': {
                'saleCount': gross == 0 ? 0 : 1,
                'grossSantim': gross,
                'cashSantim': gross,
                'otherTenderSantim': 0,
                'creditSantim': 0,
                'itemsSold': gross == 0 ? 0 : 1,
              },
              'lastSyncedAt': null,
            }),
            200,
            headers: {'content-type': 'application/json'});
      }
      if (request.url.path == '/reports/cash-up') {
        return http.Response('[]', 200);
      }
      return http.Response('{}', 503);
    }));

    await pumpTerminalScreen(
        tester, t.terminal, const Scaffold(body: ReportsScreen()));
    await tester.pumpAndSettle();
    expect(find.text('ETB 0'), findsOneWidget);
    final atOpen = summaryCalls;

    // A sale is rung up and synced while this tab sits behind another.
    gross = 90000;
    await t.terminal.refresh();
    await tester.pumpAndSettle();

    expect(summaryCalls, greaterThan(atOpen));
    expect(find.text('ETB 900'), findsOneWidget);
    expect(find.text('ETB 0'), findsNothing);
  });
}
