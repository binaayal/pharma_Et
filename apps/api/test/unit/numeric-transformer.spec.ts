import { bigintTransformer } from '../../src/common/transformers/numeric.transformer';

/**
 * T1 — the bigint boundary (docs/05-qa §3).
 *
 * Every money value in the system crosses this transformer. A silent truncation here is a
 * money error, which is an S1 — so the transformer refuses rather than rounds.
 */
describe('bigintTransformer', () => {
  it('reads a driver string back as a number', () => {
    expect(bigintTransformer.from('13993')).toBe(13993);
  });

  it('passes null through in both directions', () => {
    expect(bigintTransformer.from(null)).toBeNull();
    expect(bigintTransformer.to(null)).toBeNull();
  });

  it('refuses to store a fractional value rather than rounding it', () => {
    expect(() => bigintTransformer.to(19.99)).toThrow(/non-integer/);
  });

  it('refuses to read a value beyond the safe integer range rather than truncating', () => {
    expect(() => bigintTransformer.from('9007199254740993')).toThrow(/safe integer/);
  });

  it('round-trips the values money actually takes', () => {
    for (const value of [0, 1, 150, 1999, 13993, 100_000_000]) {
      expect(bigintTransformer.from(bigintTransformer.to(value))).toBe(value);
    }
  });
});
