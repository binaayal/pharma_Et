/**
 * Gregorian ↔ Ethiopian calendar conversion (FR-10, BR-10.2).
 *
 * The Ethiopian calendar is not a variant of the Gregorian one. It has **thirteen months** —
 * twelve of exactly thirty days, then Pagumē of five days, six in a leap year — and its year
 * begins on Meskerem 1, which falls on 11 September in most Gregorian years and 12 September
 * when the *following* Gregorian year is a leap year. It runs seven or eight years behind,
 * depending on which side of the new year a date sits.
 *
 * Every one of those facts is a place where an approximation silently produces a date that
 * is plausible and wrong — and on this product a wrong date is an expiry alert that fires a
 * year late, or a shift report attributed to the wrong day.
 *
 * So the conversion goes through the **Julian Day Number**, which both calendars define
 * exactly, rather than through any arithmetic relating the two directly. Storage stays UTC
 * ISO-8601 throughout (AC-10.2); this is a presentation concern and nothing here ever
 * reaches the database.
 */

/**
 * JDN of Ethiopian 1 Meskerem 1, **Amete Mihret** — the era in everyday civil use. The
 * anchor everything else derives from.
 *
 * Not 1723856. That is the *Amete Alem* epoch, which appears in much of the conversion
 * literature and is 365 days earlier; using it produces dates that are correct to the day
 * and month and wrong by exactly one year, which is the most plausible-looking error this
 * function can make.
 */
const ETHIOPIAN_EPOCH_JDN = 1724221;

export interface EthiopianDate {
  year: number;
  /** 1–13. Month 13 is Pagumē, the five- or six-day month. */
  month: number;
  day: number;
}

/** Month names, Amharic and transliterated. Pagumē is 13. */
export const ETHIOPIAN_MONTHS_AM = [
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
] as const;

export const ETHIOPIAN_MONTHS_EN = [
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
] as const;

/** Ethiopian leap year: every fourth, with the extra day falling in Pagumē. */
export function isEthiopianLeapYear(year: number): boolean {
  return year % 4 === 3;
}

/** Days in an Ethiopian month. Twelve thirties and a remainder — that is the whole calendar. */
export function ethiopianMonthLength(year: number, month: number): number {
  if (month < 1 || month > 13) throw new RangeError(`Ethiopian month out of range: ${month}`);
  if (month <= 12) return 30;
  return isEthiopianLeapYear(year) ? 6 : 5;
}

function gregorianToJdn(year: number, month: number, day: number): number {
  // Fliegel–Van Flandern. Integer arithmetic only: a floating-point JDN loses the day.
  const a = Math.floor((14 - month) / 12);
  const y = year + 4800 - a;
  const m = month + 12 * a - 3;
  return (
    day +
    Math.floor((153 * m + 2) / 5) +
    365 * y +
    Math.floor(y / 4) -
    Math.floor(y / 100) +
    Math.floor(y / 400) -
    32045
  );
}

function jdnToGregorian(jdn: number): { year: number; month: number; day: number } {
  const a = jdn + 32044;
  const b = Math.floor((4 * a + 3) / 146097);
  const c = a - Math.floor((146097 * b) / 4);
  const d = Math.floor((4 * c + 3) / 1461);
  const e = c - Math.floor((1461 * d) / 4);
  const m = Math.floor((5 * e + 2) / 153);
  return {
    day: e - Math.floor((153 * m + 2) / 5) + 1,
    month: m + 3 - 12 * Math.floor(m / 10),
    year: 100 * b + d - 4800 + Math.floor(m / 10),
  };
}

function ethiopianToJdn(year: number, month: number, day: number): number {
  return ETHIOPIAN_EPOCH_JDN + 365 * (year - 1) + Math.floor(year / 4) + 30 * (month - 1) + day - 1;
}

/**
 * Converts a Gregorian calendar date to Ethiopian.
 *
 * Takes plain numbers rather than a Date: a Date carries a time zone, and a date that
 * changes by a day depending on where the reader is standing is not a calendar date.
 */
export function toEthiopian(year: number, month: number, day: number): EthiopianDate {
  const jdn = gregorianToJdn(year, month, day);
  const daysSinceEpoch = jdn - ETHIOPIAN_EPOCH_JDN;

  // Four-year cycles of 1461 days (365 × 4 + 1).
  const cycles = Math.floor(daysSinceEpoch / 1461);
  const withinCycle = daysSinceEpoch % 1461;

  // Where each year of the cycle starts. NOT four equal 365-day steps: the THIRD year of
  // the cycle is the leap one (Ethiopian year ≡ 3 mod 4), so it is 366 days and every
  // offset after it shifts by one. Dividing by 365 instead — the obvious thing — places
  // the last day of a leap year's Pagumē into the following year, which is a date that is
  // wrong by a day for one day in four years and therefore never noticed in testing.
  const YEAR_START = [0, 365, 730, 1096];

  let yearInCycle = 3;
  while (yearInCycle > 0 && withinCycle < YEAR_START[yearInCycle]) yearInCycle--;
  const dayOfYear = withinCycle - YEAR_START[yearInCycle];

  return {
    year: cycles * 4 + yearInCycle + 1,
    month: Math.floor(dayOfYear / 30) + 1,
    day: (dayOfYear % 30) + 1,
  };
}

/** Converts an Ethiopian calendar date back to Gregorian. */
export function fromEthiopian(date: EthiopianDate): { year: number; month: number; day: number } {
  if (date.month < 1 || date.month > 13) {
    throw new RangeError(`Ethiopian month out of range: ${date.month}`);
  }
  if (date.day < 1 || date.day > ethiopianMonthLength(date.year, date.month)) {
    throw new RangeError(`${date.day} is not a valid day in month ${date.month} of ${date.year}`);
  }
  return jdnToGregorian(ethiopianToJdn(date.year, date.month, date.day));
}

/**
 * Converts a UTC instant for display.
 *
 * **UTC deliberately, not local time.** Every timestamp in this system is stored UTC
 * (AC-10.2), and Ethiopia is UTC+3 with no daylight saving, so a sale at 01:00 local is
 * 22:00 UTC the previous day. Rendering it in UTC keeps the displayed date consistent with
 * the date the reports group by — showing one and grouping by the other is how a shift
 * appears to be missing from its own day.
 */
export function instantToEthiopian(iso: string): EthiopianDate {
  const at = new Date(iso);
  if (Number.isNaN(at.getTime())) throw new RangeError(`not a valid instant: ${iso}`);
  return toEthiopian(at.getUTCFullYear(), at.getUTCMonth() + 1, at.getUTCDate());
}

/** `መስከረም 13፣ 2019` / `Meskerem 13, 2019`. */
export function formatEthiopian(date: EthiopianDate, locale: 'am' | 'en' = 'en'): string {
  const name =
    locale === 'am' ? ETHIOPIAN_MONTHS_AM[date.month - 1] : ETHIOPIAN_MONTHS_EN[date.month - 1];
  // U+1363 ETHIOPIC COMMA, not a Latin comma — the Amharic rendering should look Amharic.
  return locale === 'am'
    ? `${name} ${date.day}፣ ${date.year}`
    : `${name} ${date.day}, ${date.year}`;
}

/**
 * Cross-language test vectors.
 *
 * The algorithm is implemented twice — here and in Dart — because generating an algorithm
 * across languages is not something this codegen does, and hand-porting it is exactly how
 * two subtly different calendars come to exist in one product. So both implementations are
 * verified against **this** table, which is generated into Dart alongside the contract
 * types. A divergence fails a test rather than shipping a date that is off by a year.
 *
 * The cases are chosen for the places conversion actually breaks.
 */
export const ETHIOPIAN_TEST_VECTORS: ReadonlyArray<{
  gregorian: [number, number, number];
  ethiopian: [number, number, number];
  why: string;
}> = [
  { gregorian: [2024, 9, 11], ethiopian: [2017, 1, 1], why: 'Ethiopian New Year — Meskerem 1' },
  { gregorian: [2024, 9, 10], ethiopian: [2016, 13, 5], why: 'the day before: last of Pagume' },
  {
    gregorian: [2023, 9, 12],
    ethiopian: [2016, 1, 1],
    why: 'New Year slips to 12 Sep before a Gregorian leap year',
  },
  {
    gregorian: [2023, 9, 11],
    ethiopian: [2015, 13, 6],
    why: 'Pagume 6 — only exists in an Ethiopian leap year',
  },
  { gregorian: [2026, 9, 11], ethiopian: [2019, 1, 1], why: 'New Year back on 11 Sep' },
  { gregorian: [2026, 9, 23], ethiopian: [2019, 1, 13], why: 'an ordinary day early in the year' },
  { gregorian: [2026, 1, 1], ethiopian: [2018, 4, 23], why: 'Gregorian New Year falls mid-Tahsas' },
  { gregorian: [2026, 12, 31], ethiopian: [2019, 4, 22], why: 'Gregorian year end' },
  { gregorian: [2000, 2, 29], ethiopian: [1992, 6, 21], why: 'a Gregorian leap day' },
  {
    gregorian: [2027, 9, 12],
    ethiopian: [2020, 1, 1],
    why: 'New Year on 12 Sep again (2028 is a leap year)',
  },
];
