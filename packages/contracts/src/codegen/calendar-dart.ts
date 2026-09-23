import { ETHIOPIAN_TEST_VECTORS } from '../ethiopian-calendar.js';

/**
 * Emits the Ethiopian-calendar test vectors as Dart.
 *
 * The conversion algorithm itself is implemented twice — once in TypeScript, once in Dart —
 * because this codegen translates data, not algorithms, and hand-porting arithmetic is
 * exactly how two subtly different calendars come to exist inside one product.
 *
 * What is shared is the **evidence**. Both implementations are verified against this table,
 * so a divergence fails a test rather than shipping an expiry alert that is a year out.
 */
export function emitCalendarVectorsDart(contractVersion: string): string {
  const rows = ETHIOPIAN_TEST_VECTORS.map(
    (v) =>
      `  (\n` +
      `    gregorian: (${v.gregorian.join(', ')}),\n` +
      `    ethiopian: (${v.ethiopian.join(', ')}),\n` +
      `    why: ${JSON.stringify(v.why)},\n` +
      `  ),`,
  ).join('\n');

  return `// GENERATED FILE — DO NOT EDIT.
//
// Ethiopian-calendar conversion vectors, generated from
// packages/contracts/src/ethiopian-calendar.ts by \`pnpm gen:contracts\`.
//
// The algorithm is implemented separately in each language; this table is what proves the
// two agree. Cases are chosen for the places conversion actually breaks — the new-year
// boundary, Pagume 6, and Gregorian leap days.
//
// Contract version: ${contractVersion}

// ignore_for_file: lines_longer_than_80_chars

typedef CalendarVector = ({
  (int, int, int) gregorian,
  (int, int, int) ethiopian,
  String why,
});

const List<CalendarVector> kEthiopianVectors = <CalendarVector>[
${rows}
];
`;
}
