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
 * (BR-10.2). The Ethiopian calendar rendering lands with FR-10 in Phase 1 — this is the
 * seam it will slot into, which is why the conversion lives here and not in a component.
 */
export function formatInstant(iso: string): string {
  return new Date(iso).toLocaleString('en-GB', {
    dateStyle: 'medium',
    timeStyle: 'short',
  });
}

/** How stale is this view? Owners need to know before they act on a number. */
export function relativeAge(iso: string): string {
  const seconds = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 1000));
  if (seconds < 60) return 'just now';
  if (seconds < 3600) return `${Math.floor(seconds / 60)} min ago`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)} h ago`;
  return `${Math.floor(seconds / 86400)} d ago`;
}
