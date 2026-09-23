import { describe, expect, it } from 'vitest';
import { formatEtb } from '../src/lib/format';

/**
 * Money formatting is the ONE place santim becomes a decimal (docs/04 §3). If this division
 * leaks anywhere else, floats enter money math — a G4 violation and an S1 defect class.
 */
describe('formatEtb', () => {
  it('renders santim as ETB without floating-point arithmetic', () => {
    expect(formatEtb(1999)).toBe('19.99 ETB');
    expect(formatEtb(150)).toBe('1.50 ETB');
    expect(formatEtb(5)).toBe('0.05 ETB');
    expect(formatEtb(0)).toBe('0.00 ETB');
  });

  it('renders a negative amount with the sign outside the value', () => {
    expect(formatEtb(-2550)).toBe('-25.50 ETB');
  });

  it('keeps large totals exact', () => {
    expect(formatEtb(123456789)).toBe('1,234,567.89 ETB');
  });
});
