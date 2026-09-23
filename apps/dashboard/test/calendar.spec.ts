import { describe, expect, it } from 'vitest';
import { ETHIOPIAN_TEST_VECTORS, toEthiopian, fromEthiopian } from '@pharmaet/contracts';
import { formatDateOnly, formatInstant } from '../src/lib/format';

/**
 * FR-10 / BR-10.2 — Ethiopian calendar in the console.
 *
 * The same vectors the mobile client's Dart implementation is verified against. A console
 * and a till that disagree about what day it is would be worse than either being wrong
 * alone: the owner would be reconciling two reports that cannot be reconciled.
 */
describe('Ethiopian calendar', () => {
  it.each(ETHIOPIAN_TEST_VECTORS)('$gregorian → $ethiopian: $why', ({ gregorian, ethiopian }) => {
    const got = toEthiopian(...gregorian);
    expect([got.year, got.month, got.day]).toEqual(ethiopian);

    const back = fromEthiopian({ year: ethiopian[0], month: ethiopian[1], day: ethiopian[2] });
    expect([back.year, back.month, back.day]).toEqual(gregorian);
  });

  it('round-trips every day of a decade', () => {
    let day = Date.UTC(2020, 0, 1);
    const end = Date.UTC(2030, 0, 1);
    let checked = 0;
    while (day < end) {
      const d = new Date(day);
      const e = toEthiopian(d.getUTCFullYear(), d.getUTCMonth() + 1, d.getUTCDate());
      const back = fromEthiopian(e);
      expect([back.year, back.month, back.day]).toEqual([
        d.getUTCFullYear(),
        d.getUTCMonth() + 1,
        d.getUTCDate(),
      ]);
      day += 86_400_000;
      checked++;
    }
    expect(checked).toBeGreaterThan(3600);
  });
});

describe('rendering', () => {
  it('renders an instant in either calendar without changing the instant', () => {
    const iso = '2026-09-23T12:00:00.000Z';
    expect(formatInstant(iso, 'ethiopian')).toContain('Meskerem 13, 2019');
    expect(formatInstant(iso, 'gregorian')).toContain('2026');
    // AC-10.2: the stored value is untouched by how it is displayed.
    expect(new Date(iso).toISOString()).toBe(iso);
  });

  it('converts an expiry date without inventing a time zone', () => {
    // A plain calendar date has no instant, so it must not be routed through Date parsing
    // that would place it at midnight in somebody's local zone and shift the day.
    expect(formatDateOnly('2026-12-31', 'ethiopian')).toBe('Tahsas 22, 2019');
    expect(formatDateOnly('2026-12-31', 'gregorian')).toBe('2026-12-31');
  });
});
