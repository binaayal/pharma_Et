// GENERATED FILE — DO NOT EDIT.
//
// Ethiopian-calendar conversion vectors, generated from
// packages/contracts/src/ethiopian-calendar.ts by `pnpm gen:contracts`.
//
// The algorithm is implemented separately in each language; this table is what proves the
// two agree. Cases are chosen for the places conversion actually breaks — the new-year
// boundary, Pagume 6, and Gregorian leap days.
//
// Contract version: 1.4.0

// ignore_for_file: lines_longer_than_80_chars

typedef CalendarVector = ({
  (int, int, int) gregorian,
  (int, int, int) ethiopian,
  String why,
});

const List<CalendarVector> kEthiopianVectors = <CalendarVector>[
  (
    gregorian: (2024, 9, 11),
    ethiopian: (2017, 1, 1),
    why: "Ethiopian New Year — Meskerem 1",
  ),
  (
    gregorian: (2024, 9, 10),
    ethiopian: (2016, 13, 5),
    why: "the day before: last of Pagume",
  ),
  (
    gregorian: (2023, 9, 12),
    ethiopian: (2016, 1, 1),
    why: "New Year slips to 12 Sep before a Gregorian leap year",
  ),
  (
    gregorian: (2023, 9, 11),
    ethiopian: (2015, 13, 6),
    why: "Pagume 6 — only exists in an Ethiopian leap year",
  ),
  (
    gregorian: (2026, 9, 11),
    ethiopian: (2019, 1, 1),
    why: "New Year back on 11 Sep",
  ),
  (
    gregorian: (2026, 9, 23),
    ethiopian: (2019, 1, 13),
    why: "an ordinary day early in the year",
  ),
  (
    gregorian: (2026, 1, 1),
    ethiopian: (2018, 4, 23),
    why: "Gregorian New Year falls mid-Tahsas",
  ),
  (
    gregorian: (2026, 12, 31),
    ethiopian: (2019, 4, 22),
    why: "Gregorian year end",
  ),
  (
    gregorian: (2000, 2, 29),
    ethiopian: (1992, 6, 21),
    why: "a Gregorian leap day",
  ),
  (
    gregorian: (2027, 9, 12),
    ethiopian: (2020, 1, 1),
    why: "New Year on 12 Sep again (2028 is a leap year)",
  ),
];
