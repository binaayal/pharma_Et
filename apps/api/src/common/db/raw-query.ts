/**
 * Normalises TypeORM's raw-query return shape.
 *
 * For a plain SELECT the driver hands back the rows array, but for an INSERT/UPDATE with
 * RETURNING it hands back `[rows, affectedCount]`. Reading `result[0].value` therefore means
 * two different things depending on the statement — and the wrong one yields NaN, which for
 * a change sequence means a terminal silently stops receiving deltas.
 */
export function rowsOf<T = Record<string, unknown>>(result: unknown): T[] {
  if (!Array.isArray(result)) return [];
  const [first] = result;
  if (Array.isArray(first)) return first as T[];
  return result as T[];
}

export function firstRow<T = Record<string, unknown>>(result: unknown): T | undefined {
  return rowsOf<T>(result)[0];
}
