import { BadRequestException, ParseUUIDPipe } from '@nestjs/common';

/**
 * Query-string validation for the handful of parameters that are not a contract body.
 *
 * Unvalidated, a malformed id reached Postgres as `WHERE branch_id = 'abc'`, failed the uuid
 * cast and came back as a 500 — an error page for a typo, and a stack trace in the log for
 * anyone probing. A limit of `1e9` asked for a billion rows.
 */
export const OPTIONAL_UUID = new ParseUUIDPipe({ optional: true });

export function boundedLimit(raw: string | undefined, fallback: number, max: number): number {
  if (raw === undefined || raw === '') return fallback;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 1 || n > max) {
    throw new BadRequestException(`limit must be a whole number between 1 and ${max}`);
  }
  return n;
}
