/// Gregorian ↔ Ethiopian calendar conversion (FR-10, BR-10.2).
///
/// The Ethiopian calendar has **thirteen months** — twelve of exactly thirty days, then
/// Pagumē of five days, six in a leap year — and its year begins on Meskerem 1, which falls
/// on 11 September in most Gregorian years and 12 September when the *following* Gregorian
/// year is a leap year. It runs seven or eight years behind depending on which side of the
/// new year a date sits.
///
/// Every one of those is a place where an approximation produces a date that is plausible
/// and wrong, and on this product a wrong date is an expiry alert that fires a year late.
///
/// The conversion goes through the **Julian Day Number**, which both calendars define
/// exactly. Storage stays UTC ISO-8601 (AC-10.2); nothing here ever reaches the database.
///
/// This is implemented separately from the TypeScript version in `packages/contracts`,
/// because the codegen translates data, not algorithms. What the two share is the evidence:
/// both are verified against `kEthiopianVectors` from that same file.
library;

/// A date in the Ethiopian calendar. Month 13 is Pagumē.
class EthiopianDate {
  const EthiopianDate(this.year, this.month, this.day);

  final int year;
  final int month;
  final int day;

  @override
  bool operator ==(Object other) =>
      other is EthiopianDate &&
      other.year == year &&
      other.month == month &&
      other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() => '$year-$month-$day';
}

/// JDN of Ethiopian 1 Meskerem 1, **Amete Mihret** — the era in everyday civil use.
///
/// Not 1723856. That is the *Amete Alem* epoch, 365 days earlier, and it appears in much of
/// the conversion literature; using it yields dates correct to the day and month and wrong
/// by exactly one year, which is the most plausible-looking error this code can make.
const int _ethiopianEpochJdn = 1724221;

const List<String> kEthiopianMonthsAm = [
  'መስከረም',
  'ጥቅምት',
  'ኅዳር',
  'ታኅሣሥ',
  'ጥር',
  'የካቲት',
  'መጋቢት',
  'ሚያዝያ',
  'ግንቦት',
  'ሰኔ',
  'ሐምሌ',
  'ነሐሴ',
  'ጳጉሜ',
];

const List<String> kEthiopianMonthsEn = [
  'Meskerem',
  'Tikimt',
  'Hidar',
  'Tahsas',
  'Tir',
  'Yekatit',
  'Megabit',
  'Miazia',
  'Ginbot',
  'Sene',
  'Hamle',
  'Nehase',
  'Pagume',
];

/// Every fourth Ethiopian year is leap, with the extra day falling in Pagumē.
bool isEthiopianLeapYear(int year) => year % 4 == 3;

int ethiopianMonthLength(int year, int month) {
  if (month < 1 || month > 13) {
    throw RangeError('Ethiopian month out of range: $month');
  }
  if (month <= 12) return 30;
  return isEthiopianLeapYear(year) ? 6 : 5;
}

int _gregorianToJdn(int year, int month, int day) {
  // Fliegel–Van Flandern. Integer arithmetic throughout: a floating-point JDN loses the day.
  final a = (14 - month) ~/ 12;
  final y = year + 4800 - a;
  final m = month + 12 * a - 3;
  return day +
      (153 * m + 2) ~/ 5 +
      365 * y +
      y ~/ 4 -
      y ~/ 100 +
      y ~/ 400 -
      32045;
}

({int year, int month, int day}) _jdnToGregorian(int jdn) {
  final a = jdn + 32044;
  final b = (4 * a + 3) ~/ 146097;
  final c = a - (146097 * b) ~/ 4;
  final d = (4 * c + 3) ~/ 1461;
  final e = c - (1461 * d) ~/ 4;
  final m = (5 * e + 2) ~/ 153;
  return (
    day: e - (153 * m + 2) ~/ 5 + 1,
    month: m + 3 - 12 * (m ~/ 10),
    year: 100 * b + d - 4800 + m ~/ 10,
  );
}

int _ethiopianToJdn(int year, int month, int day) =>
    _ethiopianEpochJdn +
    365 * (year - 1) +
    year ~/ 4 +
    30 * (month - 1) +
    day -
    1;

/// Converts a Gregorian calendar date to Ethiopian.
///
/// Takes plain numbers rather than a [DateTime]: a DateTime carries a time zone, and a date
/// that changes by a day depending on where the reader is standing is not a calendar date.
EthiopianDate toEthiopian(int year, int month, int day) {
  final daysSinceEpoch = _gregorianToJdn(year, month, day) - _ethiopianEpochJdn;

  final cycles = daysSinceEpoch ~/ 1461;
  final withinCycle = daysSinceEpoch % 1461;

  // Where each year of the four-year cycle starts. NOT four equal 365-day steps: the THIRD
  // year is the leap one (Ethiopian year ≡ 3 mod 4), so it is 366 days and every offset
  // after it shifts by one. Dividing by 365 instead — the obvious thing — pushes the last
  // day of a leap year's Pagumē into the following year: wrong for one day in four years,
  // and therefore never noticed by hand.
  const yearStart = [0, 365, 730, 1096];

  var yearInCycle = 3;
  while (yearInCycle > 0 && withinCycle < yearStart[yearInCycle]) {
    yearInCycle--;
  }
  final dayOfYear = withinCycle - yearStart[yearInCycle];

  return EthiopianDate(
    cycles * 4 + yearInCycle + 1,
    dayOfYear ~/ 30 + 1,
    dayOfYear % 30 + 1,
  );
}

/// Converts an Ethiopian calendar date back to Gregorian.
({int year, int month, int day}) fromEthiopian(EthiopianDate date) {
  if (date.month < 1 || date.month > 13) {
    throw RangeError('Ethiopian month out of range: ${date.month}');
  }
  if (date.day < 1 || date.day > ethiopianMonthLength(date.year, date.month)) {
    throw RangeError(
      '${date.day} is not a valid day in month ${date.month} of ${date.year}',
    );
  }
  return _jdnToGregorian(_ethiopianToJdn(date.year, date.month, date.day));
}

/// Converts a stored instant for display.
///
/// **UTC deliberately, not local time.** Every timestamp is stored UTC (AC-10.2), and
/// Ethiopia is UTC+3 with no daylight saving, so a sale at 01:00 local is 22:00 UTC the
/// previous day. Rendering in UTC keeps the displayed date consistent with the date the
/// reports group by — showing one and grouping by the other is how a shift appears to be
/// missing from its own day.
EthiopianDate instantToEthiopian(DateTime instant) {
  final utc = instant.toUtc();
  return toEthiopian(utc.year, utc.month, utc.day);
}

/// `መስከረም 13፣ 2019` / `Meskerem 13, 2019`.
String formatEthiopian(EthiopianDate date, {String locale = 'en'}) {
  final name = locale == 'am'
      ? kEthiopianMonthsAm[date.month - 1]
      : kEthiopianMonthsEn[date.month - 1];
  // U+1363 ETHIOPIC COMMA, not a Latin one — the Amharic rendering should look Amharic.
  return locale == 'am'
      ? '$name ${date.day}፣ ${date.year}'
      : '$name ${date.day}, ${date.year}';
}
