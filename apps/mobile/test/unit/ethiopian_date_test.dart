import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/contracts/calendar_vectors.dart';
import 'package:pharmaet_mobile/core/ethiopian_date.dart';

/// FR-10 / BR-10.2 — Ethiopian calendar conversion.
///
/// The vectors come from `packages/contracts`, generated, and the TypeScript implementation
/// is verified against the same table. That is the whole point: the algorithm exists twice
/// because codegen translates data and not arithmetic, so the evidence has to be shared or
/// the two calendars quietly diverge.
void main() {
  group('shared vectors (identical to the TypeScript side)', () {
    for (final v in kEthiopianVectors) {
      test('${v.gregorian} → ${v.ethiopian}: ${v.why}', () {
        final (gy, gm, gd) = v.gregorian;
        final (ey, em, ed) = v.ethiopian;
        expect(toEthiopian(gy, gm, gd), EthiopianDate(ey, em, ed));
        final back = fromEthiopian(EthiopianDate(ey, em, ed));
        expect((back.year, back.month, back.day), (gy, gm, gd));
      });
    }
  });

  test('round-trips every day over a decade', () {
    // Ten years is ~3,650 chances for an off-by-one to show itself, including two Gregorian
    // leap days and two or three Ethiopian ones.
    var day = DateTime.utc(2020, 1, 1);
    final end = DateTime.utc(2030, 1, 1);
    var checked = 0;
    while (day.isBefore(end)) {
      final ethiopian = toEthiopian(day.year, day.month, day.day);
      final back = fromEthiopian(ethiopian);
      expect(
        (back.year, back.month, back.day),
        (day.year, day.month, day.day),
        reason: 'round trip failed for $day via $ethiopian',
      );
      day = day.add(const Duration(days: 1));
      checked++;
    }
    expect(checked, greaterThan(3600));
  });

  group('the calendar itself', () {
    test('has twelve thirty-day months and a remainder', () {
      // 2018 EC is not a leap year (2018 % 4 == 2), so Pagume is five days. Picking the
      // year matters here: 2019 % 4 == 3 and would have six, which is the mistake this
      // assertion was written wrong the first time.
      for (var m = 1; m <= 12; m++) {
        expect(ethiopianMonthLength(2018, m), 30);
      }
      expect(ethiopianMonthLength(2018, 13), 5);
      expect(ethiopianMonthLength(2019, 13), 6,
          reason: '2019 % 4 == 3, so it is leap');
    });

    test('Pagume gains a sixth day every fourth year', () {
      expect(isEthiopianLeapYear(2015), isTrue);
      expect(ethiopianMonthLength(2015, 13), 6);
      expect(isEthiopianLeapYear(2016), isFalse);
      expect(ethiopianMonthLength(2016, 13), 5);
    });

    test('refuses Pagume 6 in a year that does not have one', () {
      // Accepting it would convert to a real Gregorian date and silently shift everything
      // after it by a day.
      expect(() => fromEthiopian(const EthiopianDate(2016, 13, 6)),
          throwsRangeError);
      expect(fromEthiopian(const EthiopianDate(2015, 13, 6)), isNotNull);
    });

    test('refuses a month outside 1–13', () {
      expect(() => ethiopianMonthLength(2019, 14), throwsRangeError);
      expect(() => fromEthiopian(const EthiopianDate(2019, 0, 1)),
          throwsRangeError);
    });

    test('every day of a leap year converts and comes back', () {
      // 2015 EC is leap: 12 × 30 + 6 = 366 days, and the 366th is the one that breaks
      // naive implementations.
      var total = 0;
      for (var m = 1; m <= 13; m++) {
        for (var d = 1; d <= ethiopianMonthLength(2015, m); d++) {
          final g = fromEthiopian(EthiopianDate(2015, m, d));
          expect(
              toEthiopian(g.year, g.month, g.day), EthiopianDate(2015, m, d));
          total++;
        }
      }
      expect(total, 366);
    });
  });

  group('display', () {
    test('renders an instant in UTC, not local time', () {
      // Ethiopia is UTC+3, so a sale at 01:00 local is 22:00 UTC the previous day. The
      // reports group by the UTC date; showing the local one makes a shift look missing
      // from its own day.
      final instant = DateTime.utc(2026, 9, 23, 22, 30);
      expect(instantToEthiopian(instant), const EthiopianDate(2019, 1, 13));
    });

    test('formats in Amharic and English', () {
      const date = EthiopianDate(2019, 1, 13);
      expect(formatEthiopian(date, locale: 'am'), 'መስከረም 13፣ 2019');
      expect(formatEthiopian(date), 'Meskerem 13, 2019');
    });

    test('names Pagume correctly in both', () {
      const pagume = EthiopianDate(2015, 13, 6);
      expect(formatEthiopian(pagume, locale: 'am'), startsWith('ጳጉሜ'));
      expect(formatEthiopian(pagume), startsWith('Pagume'));
    });
  });
}
