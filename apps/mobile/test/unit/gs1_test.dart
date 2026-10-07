import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/contracts/barcode_vectors.dart';
import 'package:pharmaet_mobile/core/gs1.dart';

/// FR-13 — reading a scan (ADR-031).
///
/// A scan that resolves to the wrong product charges the wrong price for the wrong
/// medicine, and a batch expiry read wrongly is an expired box on the shelf marked good.
/// So the rule this file holds is: read what is certainly there, and when in doubt return
/// less — an unknown barcode is an inconvenience, a confident misread is a defect.
void main() {
  const gs = '\u001d';

  group('canonical form — the same table the server is tested against', () {
    for (final (input, canonical) in kBarcodeVectors) {
      test('"$input" → $canonical', () {
        expect(canonicalBarcode(input), canonical);
      });
    }

    test('is idempotent', () {
      for (final (input, _) in kBarcodeVectors) {
        final once = canonicalBarcode(input);
        expect(canonicalBarcode(once), once);
      }
    });
  });

  group('a retail barcode', () {
    test('EAN-13 is the product number, padded to a GTIN-14', () {
      final scan = parseScan('6291100080014')!;
      expect(scan.barcode, '06291100080014');
      expect(scan.hasBatch, isFalse);
    });

    test('an in-house label is kept as read', () {
      expect(parseScan('SHELF-0042')!.barcode, 'SHELF-0042');
    });

    test('nothing scanned is nothing', () {
      expect(parseScan(''), isNull);
      expect(parseScan('   '), isNull);
    });
  });

  group('a GS1 DataMatrix', () {
    test('gives the product, the batch and the expiry', () {
      final scan = parseScan('010629110008001417271231${'10'}LOT42A')!;
      expect(scan.barcode, '06291100080014');
      expect(scan.expiry, '2027-12-31');
      expect(scan.lot, 'LOT42A');
    });

    test('is the same product as the EAN-13 printed on the same box', () {
      expect(parseScan('010629110008001417271231')!.barcode,
          parseScan('6291100080014')!.barcode);
    });

    test('reads the fields in whatever order the manufacturer wrote them', () {
      // Lot first, so it needs the separator to say where it ends.
      final scan = parseScan('0106291100080014${'10'}B7-22${gs}17280630')!;
      expect(scan.lot, 'B7-22');
      expect(scan.expiry, '2028-06-30');
    });

    test('skips a serial number and a manufacture date to reach the rest', () {
      final scan = parseScan(
          '0106291100080014${'21'}SN000123${gs}11250101${'17'}270131${'10'}L9')!;
      expect(scan.barcode, '06291100080014');
      expect(scan.expiry, '2027-01-31');
      expect(scan.lot, 'L9');
    });

    test('tolerates a symbology prefix and a leading separator', () {
      expect(parseScan(']d2010629110008001417271231')!.expiry, '2027-12-31');
      expect(parseScan('${gs}010629110008001417271231')!.barcode,
          '06291100080014');
    });

    test('reads the bracketed human-readable form', () {
      final scan = parseScan('(01)06291100080014(17)271231(10)LOT42A')!;
      expect(scan.barcode, '06291100080014');
      expect(scan.expiry, '2027-12-31');
      expect(scan.lot, 'LOT42A');
    });

    test('day 00 means the end of the month', () {
      expect(parseScan('010629110008001417271200')!.expiry, '2027-12-31');
      expect(parseScan('010629110008001417280200')!.expiry, '2028-02-29');
      expect(parseScan('010629110008001417270200')!.expiry, '2027-02-28');
    });
  });

  group('when in doubt, return less', () {
    test('an impossible date is no date — never a guessed one', () {
      final scan = parseScan('010629110008001417271340')!;
      expect(scan.barcode, '06291100080014');
      expect(scan.expiry, isNull);
      expect(parseScan('010629110008001417270230')!.expiry, isNull);
    });

    test('stops at an identifier it does not know, keeping what it had', () {
      // AI 240 (additional product id) is variable with a three-digit AI. What follows it
      // must not be read as an expiry.
      final scan = parseScan('0106291100080014${'10'}L9${gs}240ABC17991231')!;
      expect(scan.barcode, '06291100080014');
      expect(scan.lot, 'L9');
      expect(scan.expiry, isNull);
    });

    test('a truncated code keeps the product and drops the half-read field',
        () {
      final scan = parseScan('0106291100080014172712')!;
      expect(scan.barcode, '06291100080014');
      expect(scan.expiry, isNull);
    });

    test('a 16-digit number that merely starts with 01 is not taken apart', () {
      expect(parseScan('0112345678901234')!.barcode, '0112345678901234');
    });

    test('never throws on rubbish', () {
      for (final junk in [
        '01',
        '0',
        gs,
        '$gs$gs',
        '(01)',
        '()',
        ']d2',
        '17',
        '0199'
      ]) {
        expect(() => parseScan(junk), returnsNormally, reason: junk);
      }
    });
  });
}
