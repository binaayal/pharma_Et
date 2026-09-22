import { z } from 'zod';

/**
 * Primitive value conventions (docs/04-system-design.md §3).
 *
 * These are not stylistic preferences. Money as float, or a clock-based ordering key, are
 * each an S1 defect class in this system, so the contract refuses them at the boundary.
 */

/**
 * UUIDv7 — client-generated (ADR-006). Time-ordered, so it sorts usefully, and mintable
 * offline, so a write is complete before the terminal has ever seen the server.
 *
 * Validated as a UUID with version nibble 7; the variant nibble must be 8, 9, a or b.
 */
export const uuidv7 = z
  .string()
  .regex(
    /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i,
    'must be a UUIDv7 (ADR-006)',
  )
  .describe('Client-generated UUIDv7 identifier');

/**
 * Money, always as an integer count of santim (1 ETB = 100 santim).
 *
 * Stored as bigint in Postgres and read as int in Dart. Carried as a JSON number, which is
 * exact below 2^53 — about 90 trillion ETB, comfortably beyond any pharmacy's till.
 * No floating point touches money anywhere, in any language (guardian suite G4).
 */
export const santim = z
  .number()
  .int('money must be an integer count of santim, never a decimal (G4)')
  .describe('Money in santim (1 ETB = 100 santim)');

/** A quantity in the product's base unit. May be negative on an adjustment. */
export const quantity = z.number().int().describe('Integer quantity in the base unit');

/**
 * An instant, always UTC ISO-8601. The Ethiopian calendar is a presentation concern and
 * never reaches the contract, the domain, or the database (BR-10.2).
 */
export const utcTimestamp = z
  .string()
  .datetime({ offset: false })
  .describe('UTC ISO-8601 timestamp');

/** A calendar date with no time component, e.g. a batch expiry date. */
export const isoDate = z
  .string()
  .regex(/^\d{4}-\d{2}-\d{2}$/, 'must be an ISO date (YYYY-MM-DD)')
  .describe('ISO-8601 calendar date');

/**
 * Per-terminal monotonic write counter (ADR-006). Ordering comes from this, NOT from a
 * wall clock: offline terminals have skewed clocks and produce ties at equal timestamps.
 */
export const terminalSeq = z
  .number()
  .int()
  .nonnegative()
  .describe('Monotonic per-terminal sequence number; the ordering key');

/** Server-assigned per-tenant change counter; the delta-pull cursor (docs/04 §7.2). */
export const changeSeq = z
  .number()
  .int()
  .nonnegative()
  .describe('Server-assigned monotonic per-tenant change sequence');
