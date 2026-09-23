import type { ValueTransformer } from 'typeorm';

/**
 * Postgres `bigint` arrives from the driver as a string, because a bigint can exceed
 * Number.MAX_SAFE_INTEGER. Ours cannot — money in santim and change sequences stay far below
 * 2^53 — so we convert, but we assert rather than assume.
 *
 * Silently truncating a bigint would be a money error, which is an S1 (docs/05-qa §14).
 */
export const bigintTransformer: ValueTransformer = {
  to: (value: number | null | undefined): string | null => {
    if (value === null || value === undefined) return null;
    if (!Number.isInteger(value)) {
      throw new Error(`refusing to store a non-integer in a bigint column: ${value}`);
    }
    return String(value);
  },
  from: (value: string | number | null): number | null => {
    if (value === null || value === undefined) return null;
    const n = typeof value === 'number' ? value : Number(value);
    if (!Number.isSafeInteger(n)) {
      throw new Error(`bigint ${value} exceeds the safe integer range; refusing to truncate`);
    }
    return n;
  },
};
