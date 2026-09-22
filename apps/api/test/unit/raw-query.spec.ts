import { firstRow, rowsOf } from '../../src/common/db/raw-query';

/**
 * TypeORM returns raw-query results in two different shapes depending on the statement.
 * Reading the wrong one yields NaN for a change sequence, and a NaN cursor means a terminal
 * quietly stops receiving reference-data deltas — stale prices for days, with no error.
 */
describe('raw query shape', () => {
  it('reads a plain SELECT result', () => {
    expect(rowsOf([{ value: '7' }])).toEqual([{ value: '7' }]);
  });

  it('reads the [rows, affectedCount] shape that UPDATE ... RETURNING produces', () => {
    expect(firstRow([[{ value: '7' }], 1])).toEqual({ value: '7' });
  });

  it('returns undefined rather than throwing on an empty result', () => {
    expect(firstRow([])).toBeUndefined();
    expect(firstRow([[], 0])).toBeUndefined();
  });
});
