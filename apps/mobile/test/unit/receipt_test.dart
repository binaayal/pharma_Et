import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pharmaet_mobile/core/receipt.dart';
import 'package:pharmaet_mobile/l10n/strings.dart';
import 'package:pharmaet_mobile/ui/receipt_output.dart';

/// FR-14 — the receipt a customer takes away.
///
/// A receipt is the one thing this app produces that leaves the shop, and the customer —
/// or an organisation's accounts office — will check it against the money they handed
/// over. So it must say exactly what the sale said: the same lines, the same integers,
/// in whichever language the till is set to, on paper and in a message alike.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 14:05 in Addis Ababa on 7 October 2026.
  final soldAt = DateTime.utc(2026, 10, 7, 11, 5);

  ReceiptDoc receipt({
    ReceiptTender tender = ReceiptTender.cash,
    int received = 30000,
  }) =>
      ReceiptDoc(
        shop: 'Bole Pharmacy',
        number: 'BOL-1A2B',
        soldAt: soldAt,
        cashier: 'Hana',
        lines: const [
          ReceiptLine(
              name: 'Paracetamol 500mg tablet',
              qty: 10,
              unit: 'tablet',
              unitPriceSantim: 500,
              totalSantim: 5000),
          // Sold by the pack (FR-11): two boxes at the box's own price.
          ReceiptLine(
              name: 'Amoxicillin 500mg capsule',
              qty: 2,
              unit: 'box',
              unitPriceSantim: 10000,
              totalSantim: 20000),
        ],
        totalSantim: 25000,
        tender: tender,
        receivedSantim: tender == ReceiptTender.cash ? received : 25000,
        changeSantim: tender == ReceiptTender.cash ? received - 25000 : 0,
      );

  group('a wholesale sale (FR-19)', () {
    ReceiptDoc wholesale(bool on) => ReceiptDoc(
          shop: 'Bole Pharmacy',
          number: 'BOL-1A2B',
          soldAt: soldAt,
          cashier: 'Hana',
          lines: const [
            ReceiptLine(
                name: 'Amoxicillin 500mg capsule',
                qty: 2,
                unit: 'box',
                unitPriceSantim: 8500,
                totalSantim: 17000),
          ],
          totalSantim: 17000,
          tender: ReceiptTender.cash,
          receivedSantim: 17000,
          changeSantim: 0,
          wholesale: on,
        );

    test('says so beside the sale number, in the till\'s language', () {
      expect(wholesale(true).toText(Strings.en),
          contains('#BOL-1A2B · Wholesale'));
      expect(wholesale(true).toText(Strings.am), contains('· ጅምላ'));
    });

    test('a retail slip says nothing about tiers', () {
      expect(wholesale(false).toText(Strings.en), isNot(contains('Wholesale')));
    });

    test('prints, on a roll and on cut paper', () async {
      for (final format in [PdfPageFormat.roll80, PdfPageFormat.a4]) {
        final bytes = await ReceiptOutput.pdf(wholesale(true), Strings.am,
            format: format);
        expect(bytes.length, greaterThan(1000));
      }
    });
  });

  group('the sale reference', () {
    test('is three letters of the branch and the tail of the sale id', () {
      expect(
          ReceiptDoc.numberFor(
              'Bole Pharmacy', '01930000-0000-7000-8000-00000000a1b2'),
          'BOL-A1B2');
    });

    test('copes with a branch named in Amharic, or hardly named at all', () {
      const id = '01930000-0000-7000-8000-00000000a1b2';
      expect(ReceiptDoc.numberFor('ቦሌ ፋርማሲ', id), 'A1B2');
      expect(ReceiptDoc.numberFor('B1', id), 'B-A1B2');
      expect(ReceiptDoc.numberFor('Bole', 'x'), 'BOL-X');
    });
  });

  group('shared as text', () {
    test('says what was sold, in the unit it was sold in, with its arithmetic',
        () {
      final text = receipt().toText(Strings.en);

      expect(text, contains('Bole Pharmacy'));
      expect(text, contains('Sale #BOL-1A2B'));
      expect(text, contains('Paracetamol 500mg tablet'));
      expect(text, contains('10 tablet × 5.00 = 50.00'));
      // Two boxes, not sixty capsules — and at the box price.
      expect(text, contains('2 box × 100.00 = 200.00'));
      expect(text, contains('Total: 250.00 ETB'));
    });

    test('a cash sale shows what was handed over and the change', () {
      final text = receipt().toText(Strings.en);
      expect(text, contains('Paid by: Cash'));
      expect(text, contains('Cash received: 300.00'));
      expect(text, contains('Change given: 50.00'));
    });

    test('a Telebirr sale shows no cash and no change', () {
      final text = receipt(tender: ReceiptTender.telebirr).toText(Strings.en);
      expect(text, contains('Paid by: Telebirr'));
      expect(text, isNot(contains('Cash received')));
      expect(text, isNot(contains('Change given')));
    });

    test('the lines add up to the total it prints (G4)', () {
      final doc = receipt();
      expect(doc.lines.fold<int>(0, (sum, l) => sum + l.totalSantim),
          doc.totalSantim);
      for (final line in doc.lines) {
        expect(line.qty * line.unitPriceSantim, line.totalSantim);
      }
    });

    test('carries both calendars: the customer reads one, accounts the other',
        () {
      final when = receipt().when(Strings.en);
      expect(when, contains('2026-10-07'));
      // 27 Meskerem 2019 in the Ethiopian calendar.
      expect(when, contains('2019'));
    });

    test('is in Amharic when the till is', () {
      final text = receipt().toText(Strings.am);
      expect(text, contains('ጠቅላላ: 250.00 ETB'));
      expect(text, contains('የተሰጠ መልስ: 50.00'));
      expect(text, contains('ያስተናገደው: Hana'));
      // Product names are data and stay as the owner typed them.
      expect(text, contains('Paracetamol 500mg tablet'));
      expect(text, isNot(contains('Total:')));
    });

    test('names the cashier by first name only and nothing about the customer',
        () {
      final text = receipt().toText(Strings.en);
      expect(text, contains('Served by: Hana'));
      // The receipt goes home with a stranger; it carries no account or device detail.
      expect(text, isNot(contains('01930000')));
    });
  });

  group('a sale on credit (FR-16)', () {
    // 250.00 sold; 100.00 paid now, 150.00 on Abebe's account.
    final onCredit = ReceiptDoc(
      shop: 'Bole Pharmacy',
      number: 'BOL-1A2B',
      soldAt: soldAt,
      cashier: 'Hana',
      lines: receipt().lines,
      totalSantim: 25000,
      tender: ReceiptTender.credit,
      receivedSantim: 10000,
      changeSantim: 0,
      creditSantim: 15000,
      customerName: 'Abebe Kebede',
    );

    test('says who it is on account for, what was paid now and what is owed',
        () {
      final text = onCredit.toText(Strings.en);
      expect(text, contains('Paid by: On credit (Abebe Kebede)'));
      expect(text, contains('Paid now: 100.00'));
      expect(text, contains('On account for this sale: 150.00'));
      // Not a cash sale: no "cash received", no change.
      expect(text, isNot(contains('Cash received')));
      expect(text, isNot(contains('Change given')));
    });

    test('every character it prints exists in a font the page is set in', () {
      // Found on a real phone: "On credit — Abebe" printed with an empty box where the
      // dash was. The page is set in Helvetica (Latin-1) with an Ethiopic fallback, so a
      // receipt line may use nothing outside those two. Product and customer names are
      // the owner's to type; this holds the words the app itself puts on the slip.
      bool printable(int rune) =>
          rune <= 0xFF || (rune >= 0x1200 && rune <= 0x139F);
      for (final s in [Strings.en, Strings.am]) {
        for (final doc in [
          onCredit,
          receipt(),
          receipt(tender: ReceiptTender.telebirr)
        ]) {
          final words = [
            for (final (label, value) in doc.settlement(s)) ...[label, value],
            s.get('receipt.sale'),
            s.get('receipt.total'),
            s.get('receipt.servedBy'),
            s.get('receipt.thanks'),
            doc.when(s),
            for (final line in doc.lines) ReceiptDoc.quantity(line),
          ].join(' ');
          for (final rune in words.runes) {
            expect(printable(rune), isTrue,
                reason:
                    '"${String.fromCharCode(rune)}" (U+${rune.toRadixString(16)}) in: $words');
          }
        }
      }
    });

    test('what was paid now and what is owed add up to the total (G4)', () {
      expect(onCredit.receivedSantim + onCredit.creditSantim,
          onCredit.totalSantim);
    });

    test('states the debt for this sale, not a balance it may only half know',
        () {
      // The phone's figure for the whole account can be missing another phone's sales.
      // The slip is the customer's record, so it says only what this sale added.
      final text = onCredit.toText(Strings.en);
      expect(text, isNot(contains('balance')));
      expect(text, isNot(contains('Balance')));
    });

    test('the printed page settles the sale the same way as the shared text',
        () async {
      final lines = onCredit.settlement(Strings.am);
      expect(lines.map((l) => l.$2).toList(),
          ['በዱቤ (Abebe Kebede)', '100.00', '150.00']);
      final bytes = await ReceiptOutput.pdf(onCredit, Strings.am);
      expect(ascii.decode(bytes.sublist(0, 5)), '%PDF-');
    });
  });

  group('printed as a page', () {
    test('renders a real PDF from the bundled font', () async {
      final bytes = await ReceiptOutput.pdf(receipt(), Strings.en);
      expect(ascii.decode(bytes.sublist(0, 5)), '%PDF-');
      // A slip, not a blank page: a page with text and an embedded font is well beyond
      // this, and an empty document is well under it.
      expect(bytes.length, greaterThan(3000));
    });

    test('renders in Amharic — the font is in the app bundle', () async {
      // The PDF library's own fonts have no Ethiopic glyphs. If the bundled font went
      // missing this would throw, and on a phone the receipt would print as boxes.
      final bytes = await ReceiptOutput.pdf(receipt(), Strings.am);
      expect(ascii.decode(bytes.sublist(0, 5)), '%PDF-');

      final regular =
          await rootBundle.load('assets/fonts/NotoSansEthiopic-Regular.ttf');
      expect(regular.lengthInBytes, greaterThan(100000));
    });

    test('the font really has the Ethiopic letters a receipt uses', () {
      // Read the font's character map directly: "it loaded" does not mean "it can draw
      // ጠ". Format-4 and format-12 cmap subtables both list the code points they cover.
      final font =
          File('assets/fonts/NotoSansEthiopic-Regular.ttf').readAsBytesSync();
      final covered = _codePoints(font);
      for (final rune in 'ጠቅላላ የተሰጠ መልስ ያስተናገደው እናመሰግናለን ብር'.runes) {
        if (rune == 0x20) continue;
        expect(covered.contains(rune), isTrue,
            reason: 'no glyph for ${String.fromCharCode(rune)}');
      }
    });

    test('is the fallback, because it has letters and no digits', () {
      // Found by this test: the font draws ጠ and not 0. So it cannot be the receipt's base
      // font — a price would print as boxes. Prices are set in the PDF library's own
      // Helvetica; this holds the reason in place if anyone tidies the fonts up.
      final font =
          File('assets/fonts/NotoSansEthiopic-Regular.ttf').readAsBytesSync();
      expect(_codePoints(font).contains('0'.codeUnitAt(0)), isFalse);
    });

    test('a long receipt on cut paper runs on, instead of off the page',
        () async {
      final long = ReceiptDoc(
        shop: 'Bole Pharmacy',
        number: 'BOL-LONG',
        soldAt: soldAt,
        cashier: 'Hana',
        lines: [
          for (var i = 0; i < 90; i++)
            ReceiptLine(
                name: 'Medicine number $i',
                qty: 1,
                unit: 'tablet',
                unitPriceSantim: 100,
                totalSantim: 100),
        ],
        totalSantim: 9000,
        tender: ReceiptTender.other,
        receivedSantim: 9000,
        changeSantim: 0,
      );
      final a4 =
          await ReceiptOutput.pdf(long, Strings.en, format: PdfPageFormat.a4);
      final roll = await ReceiptOutput.pdf(long, Strings.en);
      int pages(List<int> pdf) =>
          int.parse(RegExp(r'/Type/Pages/Kids\[[^\]]*\]/Count (\d+)')
              .firstMatch(latin1.decode(pdf))!
              .group(1)!);
      // Ninety lines do not fit one A4 sheet; on a roll they are one long slip.
      expect(pages(a4), greaterThan(1));
      expect(pages(roll), 1);
      expect(ascii.decode(roll.sublist(0, 5)), '%PDF-');
    });

    test('ships with its licence', () {
      expect(File('assets/fonts/OFL.txt').readAsStringSync(),
          contains('SIL Open Font License'));
    });
  });
}

/// The code points a TrueType font maps to a glyph, from its `cmap` table.
Set<int> _codePoints(List<int> f) {
  int u16(int o) => (f[o] << 8) | f[o + 1];
  int u32(int o) => (u16(o) << 16) | u16(o + 2);

  final tables = u16(4);
  var cmap = -1;
  for (var i = 0; i < tables; i++) {
    final record = 12 + i * 16;
    if (String.fromCharCodes(f.sublist(record, record + 4)) == 'cmap') {
      cmap = u32(record + 8);
    }
  }
  final found = <int>{};
  final subtables = u16(cmap + 2);
  for (var i = 0; i < subtables; i++) {
    final offset = cmap + u32(cmap + 4 + i * 8 + 4);
    final format = u16(offset);
    if (format == 12) {
      final groups = u32(offset + 12);
      for (var g = 0; g < groups; g++) {
        final start = u32(offset + 16 + g * 12);
        final end = u32(offset + 20 + g * 12);
        for (var c = start; c <= end; c++) {
          found.add(c);
        }
      }
    } else if (format == 4) {
      final segX2 = u16(offset + 6);
      final ends = offset + 14;
      final starts = ends + segX2 + 2;
      for (var s = 0; s < segX2; s += 2) {
        final start = u16(starts + s);
        final end = u16(ends + s);
        if (end == 0xFFFF) continue;
        for (var c = start; c <= end; c++) {
          found.add(c);
        }
      }
    }
  }
  return found;
}
