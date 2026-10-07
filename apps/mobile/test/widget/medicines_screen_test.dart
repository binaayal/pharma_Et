import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/data/medicine_catalogue.dart';
import 'package:pharmaet_mobile/ui/kit.dart';
import 'package:pharmaet_mobile/ui/medicines_screen.dart';
import 'package:pharmaet_mobile/ui/stock_screen.dart';

import '../support/terminal.dart';
import '../support/test_db.dart';

/// FR-12 — the ready-made medicines list, as something an owner can see and tick.
///
/// The list shipped in V2 only as suggestions under a name being typed, and the owner
/// said, on a phone, that they had not seen it. So what is held here is that it can be
/// *found* without typing a letter, that a shop can be stocked by ticking, and that the
/// one thing the list cannot supply — a price — is asked for and never invented.
void main() {
  late LocalDb db;
  late Directory dir;

  final list = MedicineCatalogue('test', const [
    MedicineEntry(name: 'Amoxicillin 250mg capsule', unit: 'capsule'),
    MedicineEntry(name: 'Amoxicillin 500mg capsule', unit: 'capsule'),
    MedicineEntry(name: 'Metformin 500mg tablet', unit: 'tablet'),
    MedicineEntry(name: 'Paracetamol 500mg tablet', unit: 'tablet'),
    MedicineEntry(name: 'Salbutamol 100mcg inhaler', unit: 'inhaler'),
  ]);

  setUp(() async {
    final opened = await openTestDb();
    db = opened.db;
    dir = opened.dir;
    MedicineCatalogue.debugSet(list);
  });

  tearDown(() async {
    MedicineCatalogue.debugSet(null);
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(720, 1520);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
  }

  PButton footer(WidgetTester tester) =>
      tester.widgetList<PButton>(find.byType(PButton)).last;

  /// Records what was posted; fails every request once [failAfter] have succeeded.
  ({MockClient client, List<Map<String, dynamic>> posted, void Function() heal})
      server({int? failAfter}) {
    final posted = <Map<String, dynamic>>[];
    var limit = failAfter;
    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/products') {
        if (limit != null && posted.length >= limit!) {
          return http.Response('{"message":"no connection"}', 503);
        }
        posted.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response('{"id":"x"}', 201);
      }
      return http.Response('{}', 503);
    });
    return (client: client, posted: posted, heal: () => limit = null);
  }

  group('finding the list', () {
    testWidgets('the add button offers the list first, typing second',
        (tester) async {
      phone(tester);
      final owner = TestTerminal.build(db, role: 'owner');
      owner.addProduct('p1', 'Paracetamol 500mg tablet');
      await pumpTerminalScreen(tester, owner.terminal, const StockScreen());
      await tester.tap(find.byTooltip('Add product'));
      await tester.pumpAndSettle();

      expect(find.text('Pick from the medicines list'), findsOneWidget);
      expect(find.text('Type a product yourself'), findsOneWidget);

      await tester.tap(find.text('Pick from the medicines list'));
      await tester.pumpAndSettle();
      expect(find.text('Medicines list'), findsOneWidget);
    });

    testWidgets('an empty shop is shown the list without pressing anything',
        (tester) async {
      phone(tester);
      final owner = TestTerminal.build(db, role: 'owner');
      await pumpTerminalScreen(tester, owner.terminal, const StockScreen());
      await tester.pump();

      expect(find.textContaining('Start by ticking'), findsOneWidget);
      await tester
          .tap(find.widgetWithText(PButton, 'Pick from the medicines list'));
      await tester.pumpAndSettle();
      expect(find.text('Medicines list'), findsOneWidget);
    });

    testWidgets('a cashier, who cannot add products, is not shown it',
        (tester) async {
      phone(tester);
      final cashier = TestTerminal.build(db, role: 'cashier');
      await pumpTerminalScreen(tester, cashier.terminal, const StockScreen());
      await tester.pump();
      expect(find.text('Pick from the medicines list'), findsNothing);
    });
  });

  group('ticking', () {
    Future<TestTerminal> open(WidgetTester tester, {http.Client? api}) async {
      phone(tester);
      final owner = TestTerminal.build(db, role: 'owner', api: api);
      owner.addProduct('p1', 'Paracetamol 500mg tablet');
      await pumpTerminalScreen(tester, owner.terminal, const MedicinesScreen());
      await tester.pump();
      return owner;
    }

    testWidgets('shows the whole list before a letter is typed',
        (tester) async {
      await open(tester);
      expect(find.text('Amoxicillin 250mg capsule'), findsOneWidget);
      expect(find.text('Salbutamol 100mcg inhaler'), findsOneWidget);
      expect(find.textContaining('5 medicines'), findsOneWidget);
      // Nothing ticked: nothing to go on with.
      expect(footer(tester).onPressed, isNull);
    });

    testWidgets('typing narrows it, in any word order', (tester) async {
      await open(tester);
      await tester.enterText(find.byType(TextField), '500 amox');
      await tester.pump();
      expect(find.text('Amoxicillin 500mg capsule'), findsOneWidget);
      expect(find.text('Amoxicillin 250mg capsule'), findsNothing);
      expect(find.textContaining('1 medicines'), findsOneWidget);
    });

    testWidgets('what the shop already sells is marked, and cannot be re-added',
        (tester) async {
      await open(tester);
      expect(find.text('Already in your shop'), findsOneWidget);
      await tester.tap(find.text('Paracetamol 500mg tablet'));
      await tester.pump();
      expect(footer(tester).onPressed, isNull);
    });

    testWidgets('ticks are counted, kept through a search, and can be undone',
        (tester) async {
      await open(tester);
      await tester.tap(find.text('Amoxicillin 500mg capsule'));
      await tester.tap(find.text('Metformin 500mg tablet'));
      await tester.pump();
      expect(footer(tester).label, 'Set prices for 2');

      await tester.enterText(find.byType(TextField), 'salb');
      await tester.pump();
      expect(footer(tester).label, 'Set prices for 2');

      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      await tester.tap(find.text('Metformin 500mg tablet'));
      await tester.pump();
      expect(footer(tester).label, 'Set prices for 1');
    });
  });

  group('pricing and adding', () {
    Future<void> toPrices(WidgetTester tester, http.Client api) async {
      phone(tester);
      final owner = TestTerminal.build(db, role: 'owner', api: api);
      await pumpTerminalScreen(tester, owner.terminal, const MedicinesScreen());
      await tester.pump();
      await tester.tap(find.text('Amoxicillin 500mg capsule'));
      await tester.tap(find.text('Metformin 500mg tablet'));
      await tester.tap(find.text('Paracetamol 500mg tablet'));
      await tester.pump();
      await tester.tap(find.byType(PButton).last);
      await tester.pumpAndSettle();
    }

    testWidgets('nothing is added until every medicine has a price',
        (tester) async {
      final s = server();
      await toPrices(tester, s.client);

      expect(find.text('Your prices'), findsOneWidget);
      expect(footer(tester).label, '3 still need a price');
      expect(footer(tester).onPressed, isNull);

      await tester.enterText(find.byType(TextField).at(0), '4');
      await tester.enterText(find.byType(TextField).at(1), '0');
      await tester.pump();
      // Zero is not a price, and neither is an empty field.
      expect(footer(tester).label, '2 still need a price');
      expect(s.posted, isEmpty);
    });

    testWidgets('adds each with the list\'s name and unit and the typed price',
        (tester) async {
      final s = server();
      await toPrices(tester, s.client);
      await tester.enterText(find.byType(TextField).at(0), '4');
      await tester.enterText(find.byType(TextField).at(1), '2.50');
      await tester.enterText(find.byType(TextField).at(2), '1');
      await tester.pump();
      expect(footer(tester).label, 'Add 3 to my shop');
      footer(tester).onPressed!();
      await tester.pumpAndSettle();

      expect(s.posted.map((p) => p['name']), [
        'Amoxicillin 500mg capsule',
        'Metformin 500mg tablet',
        'Paracetamol 500mg tablet',
      ]);
      expect(s.posted.first['unit'], 'capsule');
      // 2.50 birr, as integer santim (G4).
      expect(s.posted[1]['priceSantim'], 250);
      // The list never marks anything controlled: that is a regulatory fact, not a name.
      expect(s.posted.every((p) => p['isControlled'] == false), isTrue);
      // Done: the price step has closed behind it.
      expect(find.text('Your prices'), findsNothing);
    });

    testWidgets('one taken off the batch is not added', (tester) async {
      final s = server();
      await toPrices(tester, s.client);
      await tester.tap(find.byTooltip('Remove').at(1));
      await tester.pump();
      await tester.enterText(find.byType(TextField).at(0), '4');
      await tester.enterText(find.byType(TextField).at(1), '1');
      await tester.pump();
      footer(tester).onPressed!();
      await tester.pumpAndSettle();

      expect(s.posted.map((p) => p['name']),
          ['Amoxicillin 500mg capsule', 'Paracetamol 500mg tablet']);
    });

    testWidgets(
        'a connection lost halfway leaves exactly what was not added, and trying again adds nothing twice',
        (tester) async {
      final s = server(failAfter: 1);
      await toPrices(tester, s.client);
      await tester.enterText(find.byType(TextField).at(0), '4');
      await tester.enterText(find.byType(TextField).at(1), '2.50');
      await tester.enterText(find.byType(TextField).at(2), '1');
      await tester.pump();
      footer(tester).onPressed!();
      await tester.pumpAndSettle();

      expect(s.posted.length, 1);
      expect(find.textContaining('1 added'), findsOneWidget);
      expect(find.textContaining('Stopped before these were added'),
          findsOneWidget);
      // The one that went through is off the screen; the two that did not are still on
      // it, with the prices already typed.
      expect(find.text('Amoxicillin 500mg capsule'), findsNothing);
      expect(find.text('Metformin 500mg tablet'), findsOneWidget);
      expect(footer(tester).label, 'Add 2 to my shop');

      s.heal();
      footer(tester).onPressed!();
      await tester.pumpAndSettle();
      expect(s.posted.map((p) => p['name']), [
        'Amoxicillin 500mg capsule',
        'Metformin 500mg tablet',
        'Paracetamol 500mg tablet',
      ]);
    });
  });

  testWidgets('in Amharic (AC-10.1)', (tester) async {
    phone(tester);
    final owner = TestTerminal.build(db, role: 'owner');
    await pumpTerminalScreen(tester, owner.terminal, const MedicinesScreen(),
        locale: 'am');
    await tester.pump();
    expect(find.text('የመድኃኒት ዝርዝር'), findsOneWidget);
    expect(find.text('Medicines list'), findsNothing);
    expect(find.textContaining('Tick the medicines'), findsNothing);
  });
}
