import { formatEthiopian, instantToEthiopian, toEthiopian } from '@pharmaet/contracts';

/**
 * Money arrives as an integer count of santim and is formatted only at the very edge
 * (docs/04 §3). The division happens here, in one place, on the way to the screen — never
 * in state, never in a calculation, never on the way back to the server.
 */
export function formatEtb(santim: number): string {
  const sign = santim < 0 ? '-' : '';
  const absolute = Math.abs(santim);
  const birr = Math.trunc(absolute / 100);
  const cents = absolute % 100;
  return `${sign}${birr.toLocaleString('en-ET')}.${cents.toString().padStart(2, '0')} ETB`;
}

/**
 * Timestamps are stored and transported as UTC; rendering is a presentation concern
 * (BR-10.2). The conversion lives here rather than in a component so there is one place
 * that decides what a date looks like.
 */
export function formatInstant(iso: string, calendar: Calendar = 'gregorian'): string {
  const at = new Date(iso);
  const time = at.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });

  if (calendar === 'ethiopian') {
    // UTC deliberately, matching the mobile client and the dates the reports group by.
    // Ethiopia is UTC+3, so rendering in local time would put a late-evening sale on the
    // following day here and the previous one in a report — and a shift would appear to be
    // missing from its own day.
    return `${formatEthiopian(instantToEthiopian(iso), 'en')} ${time}`;
  }
  return `${at.toLocaleDateString('en-GB', { dateStyle: 'medium' })} ${time}`;
}

/**
 * Which calendar the console renders in (FR-10, BR-10.2).
 *
 * Storage is always UTC ISO-8601 and never changes with this setting (AC-10.2). The
 * conversion itself comes from `@pharmaet/contracts`, the same module the mobile client's
 * Dart implementation is verified against — a console and a till that disagree about what
 * day it is would be worse than either being wrong alone.
 */
export type Calendar = 'gregorian' | 'ethiopian';

export function formatDateOnly(isoDate: string, calendar: Calendar): string {
  if (calendar === 'gregorian') return isoDate;
  const [year, month, day] = isoDate.split('-').map(Number);
  return formatEthiopian(toEthiopian(year, month, day), 'en');
}

/** How stale is this view? Owners need to know before they act on a number. */
export function relativeAge(iso: string): string {
  const seconds = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 1000));
  if (seconds < 60) return 'just now';
  if (seconds < 3600) return `${Math.floor(seconds / 60)} min ago`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)} h ago`;
  return `${Math.floor(seconds / 86400)} d ago`;
}

/** `+251921184477` → `+251 92 118 4477`, as people read it aloud on a verification call. */
export function formatPhone(e164: string): string {
  const m = /^\+251(\d{2})(\d{3})(\d{4})$/.exec(e164);
  return m ? `+251 ${m[1]} ${m[2]} ${m[3]}` : e164;
}
