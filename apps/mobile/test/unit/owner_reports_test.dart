import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/core/owner_reports.dart';
import 'package:pharmaet_mobile/l10n/strings.dart';

/// FR-17 — what the owner reads when they are not in the shop.
///
/// The server adds the day up and is tested for that. This is the last step, where numbers
/// become sentences an owner acts on: a shortage must read as a shortage, an overage must
/// not hide it, and an audit entry must say who did what to which medicine — not print an
/// identifier, and not go quiet when it meets an event it does not recognise.
void main() {
  Map<String, dynamic> day({
    int shortage = 0,
    int overage = 0,
    int open = 0,
    List<Map<String, dynamic>>? shifts,
    int lowCount = 0,
    List<Map<String, dynamic>> low = const [],
    Map<String, int> attention = const {},
  }) =>
      {
        'from': '2026-10-06T21:00:00.000Z',
        'to': '2026-10-07T21:00:00.000Z',
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
              shifts?.where((s) => s['varianceSantim'] != null).length ?? 0,
          'countedSantim': 0,
          'shortageSantim': shortage,
          'overageSantim': overage,
          'openShifts': open,
        },
        'shifts': shifts ?? const <Map<String, dynamic>>[],
        'credit': {
          'repaidSantim': 80000,
          'owedSantim': 540000,
          'customersOwing': 3
        },
        'stock': {
          'lowCount': lowCount,
          'low': low,
          'expiringBatches': 0,
          'oversoldBatches': 0,
        },
        'attention': {
          'priceChanges': attention['priceChanges'] ?? 0,
          'stockWriteOffs': attention['stockWriteOffs'] ?? 0,
          'expiredDispenses': attention['expiredDispenses'] ?? 0,
        },
        'lastSyncedAt': '2026-10-07T15:00:00.000Z',
      };

  Map<String, dynamic> shift(String name, int? variance,
          {bool closed = true}) =>
      {
        'shiftId': 's',
        'branchName': 'Bole',
        'userName': name,
        'openedAt': '2026-10-07T05:00:00.000Z',
        'closedAt': closed ? '2026-10-07T15:00:00.000Z' : null,
        'countedSantim': variance == null ? null : 2150000 + variance,
        'expectedSantim': variance == null ? null : 2150000,
        'varianceSantim': variance,
      };

  String text(Map<String, dynamic> json, [Strings s = Strings.en]) =>
      DailySummary.fromJson(json)
          .toText(s, shop: 'Bole Pharmacy', day: '7 Oct');

  group('the summary as a message', () {
    test('leads with whose day it is and what was sold', () {
      final t = text(day());
      expect(t.split('\n').first, 'Bole Pharmacy — 7 Oct');
      expect(t, contains('Sales: 42 · ETB 12,400'));
      expect(
          t,
          contains(
              'Cash 9,100.00 · Telebirr & other 2,000.00 · On credit 1,300.00'));
    });

    test('a shortage is said plainly, with who was on', () {
      final t = text(day(shortage: 5000, shifts: [shift('Hana', -5000)]));
      expect(t, contains('Cash is short by 50.00.'));
      expect(t, contains('On shift: Hana'));
      expect(t, isNot(contains('none short')));
    });

    test('an overage elsewhere does not turn a shortage into good news', () {
      final t = text(day(
          shortage: 5000,
          overage: 3000,
          shifts: [shift('Hana', -5000), shift('Dawit', 3000)]));
      expect(t, contains('Cash is short by 50.00.'));
      expect(t, contains('Cash is over by 30.00.'));
      // Never a net figure.
      expect(t, isNot(contains('20.00')));
      expect(t, contains('On shift: Hana, Dawit'));
    });

    test('tills that balanced are said to have balanced — zero is the news',
        () {
      final t = text(day(shifts: [shift('Hana', 0), shift('Dawit', 0)]));
      expect(t, contains('2 tills counted, none short.'));
    });

    test('a till left open is reported, not skipped', () {
      final t =
          text(day(open: 1, shifts: [shift('Hana', null, closed: false)]));
      expect(t, contains('1 tills are still open and have not been counted.'));
    });

    test('a day with no till says so', () {
      expect(text(day()), contains('No till was opened.'));
    });

    test('names each person on shift once', () {
      final t = text(day(shifts: [shift('Hana', 0), shift('Hana', 0)]));
      expect(t, contains('On shift: Hana'));
      expect(t, isNot(contains('Hana, Hana')));
    });

    test('says what is owed and what came in against it', () {
      expect(text(day()),
          contains('Owed to you: 5,400.00 from 3 customers · repaid 800.00'));
    });

    test('lists what is running low, with how many are left', () {
      final t = text(day(lowCount: 6, low: [
        {
          'productId': 'a',
          'productName': 'Amoxicillin 500mg',
          'unit': 'capsule',
          'onHand': 3
        },
        {'productId': 'b', 'productName': 'ORS', 'unit': 'sachet', 'onHand': 0},
      ]));
      expect(t, contains('Running low: 6 — Amoxicillin 500mg (3), ORS (0)'));
    });

    test(
        'mentions what an owner should have been told, only when there is some',
        () {
      expect(text(day()), isNot(contains('price changes')));
      final t = text(day(attention: {
        'priceChanges': 2,
        'stockWriteOffs': 1,
        'expiredDispenses': 1,
      }));
      expect(t, contains('2 price changes'));
      expect(t, contains('1 stock write-offs'));
      expect(t, contains('1 sales of expired stock'));
    });

    test('is in Amharic when the phone is', () {
      final t =
          text(day(shortage: 5000, shifts: [shift('Hana', -5000)]), Strings.am);
      expect(t, contains('ጥሬ ገንዘቡ በ50.00 ጎድሏል።'));
      expect(t, isNot(contains('Cash is short')));
    });
  });

  group('whether the day needs a look', () {
    DailySummary of(Map<String, dynamic> j) => DailySummary.fromJson(j);

    test('a clean day does not', () {
      expect(of(day(shifts: [shift('Hana', 0)])).needsAttention, isFalse);
    });

    test('one santim short does', () {
      expect(of(day(shortage: 1, shifts: [shift('Hana', -1)])).needsAttention,
          isTrue);
    });

    test('a till left open does; an overage alone does not', () {
      expect(of(day(open: 1)).needsAttention, isTrue);
      expect(
          of(day(overage: 3000, shifts: [shift('Hana', 3000)])).needsAttention,
          isFalse);
    });

    test('a write-off or an expired sale does', () {
      expect(of(day(attention: {'stockWriteOffs': 1})).needsAttention, isTrue);
      expect(
          of(day(attention: {'expiredDispenses': 1})).needsAttention, isTrue);
    });
  });

  group('an audit entry, as a sentence', () {
    AuditEntry entry(String type, Map<String, dynamic> payload) =>
        AuditEntry.fromJson({
          'eventType': type,
          'occurredAt': '2026-10-07T20:00:00.000Z',
          'actorName': 'Hana',
          'payload': payload,
        });

    String? names(String id) => id == 'p1' ? 'Paracetamol 500mg' : null;

    test('a price change says the medicine, the old price and the new', () {
      final e = entry('audit.price_changed', {
        'productName': 'Paracetamol 500mg',
        'previousPriceSantim': 600,
        'priceSantim': 500,
      });
      expect(e.describe(Strings.en),
          'Price of Paracetamol 500mg changed from 6.00 to 5.00');
      expect(e.kind, AuditKind.prices);
    });

    test('a price made cheaper is flagged; one made dearer is not', () {
      expect(
          entry('audit.price_changed',
              {'previousPriceSantim': 600, 'priceSantim': 500}).flagged,
          isTrue);
      expect(
          entry('audit.price_changed',
              {'previousPriceSantim': 500, 'priceSantim': 600}).flagged,
          isFalse);
    });

    test('a write-off names the medicine from this phone\'s catalogue, and why',
        () {
      final e = entry('audit.stock_adjusted', {
        'productId': 'p1',
        'delta': -12,
        'reason': 'theft_or_loss',
        'note': 'box missing after delivery',
      });
      expect(e.describe(Strings.en, productName: names),
          '12 of Paracetamol 500mg taken off the count — theft or loss');
      expect(e.flagged, isTrue);
      expect(e.note, 'box missing after delivery');
      expect(e.kind, AuditKind.stock);
    });

    test('an ordinary recount, or stock found, is not flagged', () {
      expect(
          entry('audit.stock_adjusted',
              {'productId': 'p1', 'delta': -1, 'reason': 'recount'}).flagged,
          isFalse);
      final found = entry('audit.stock_adjusted',
          {'productId': 'p1', 'delta': 4, 'reason': 'receipt_correction'});
      expect(found.flagged, isFalse);
      expect(found.describe(Strings.en, productName: names),
          '4 of Paracetamol 500mg added to the count — receipt entered wrongly');
    });

    test('a product this phone does not know is "a product", never an id', () {
      final e = entry('audit.stock_adjusted', {
        'productId': '01930000-0000-7000-8000-00000000000z',
        'delta': -2,
        'reason': 'damage',
      });
      final said = e.describe(Strings.en, productName: names);
      expect(said, '2 of a product taken off the count — damaged');
      expect(said, isNot(contains('01930000')));
    });

    test('an expired sale says whether anybody authorised it', () {
      final authorised = entry('audit.expired_dispense', {
        'productId': 'p1',
        'qty': 2,
        'lotNo': 'LOT-7',
        'authorisedBy': 'u1'
      });
      final nobody = entry('audit.expired_dispense', {
        'productId': 'p1',
        'qty': 2,
        'lotNo': 'LOT-7',
        'authorisedBy': null
      });
      expect(authorised.describe(Strings.en, productName: names),
          '2 of Paracetamol 500mg sold from expired lot LOT-7, authorised');
      expect(nobody.describe(Strings.en, productName: names),
          contains('nobody authorised it'));
      expect(authorised.flagged, isTrue);
      expect(nobody.flagged, isTrue);
    });

    test('staff changes say who and as what', () {
      expect(
          entry('audit.user_created', {'username': 'dawit', 'role': 'cashier'})
              .describe(Strings.en),
          'dawit added as Cashier');
      expect(
          entry('audit.user_deactivated',
              {'username': 'dawit', 'role': 'cashier'}).describe(Strings.en),
          'dawit deactivated');
      expect(entry('audit.user_created', {}).kind, AuditKind.staff);
    });

    test('an event from a newer server is shown by name, not hidden', () {
      // An audit trail does not get to skip the entries it has no sentence for.
      final e = entry('audit.something_new', {'x': 1});
      expect(e.describe(Strings.en), 'something new');
      expect(e.flagged, isFalse);
      expect(e.kind, AuditKind.account);
    });

    test('every sentence exists in Amharic too', () {
      final e = entry('audit.price_changed', {
        'productName': 'Paracetamol 500mg',
        'previousPriceSantim': 600,
        'priceSantim': 500,
      });
      expect(
          e.describe(Strings.am), 'የParacetamol 500mg ዋጋ ከ6.00 ወደ 5.00 ተቀይሯል');
    });

    test('a blank note is no note', () {
      expect(entry('audit.stock_adjusted', {'note': '  '}).note, isNull);
      expect(entry('audit.stock_adjusted', {}).note, isNull);
    });
  });
}
