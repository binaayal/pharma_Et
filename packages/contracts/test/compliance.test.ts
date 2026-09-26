import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  normalisePrescriptionNumber,
  prescriptionValidOn,
  PSYCHOTROPIC_RULES,
} from '../src/compliance.js';

/**
 * The psychotropic rules exist twice — here, where the server reads them, and in Dart on the
 * till, where they must hold offline (docs/04 §6.4). A till and a server that disagree about
 * a validity window would accept a dispense at the counter that the server then refuses,
 * days later, with the medicine long gone. So the Dart copy is read and compared.
 *
 * When A-1 is verified, both change in the same commit or this fails.
 */
describe('psychotropic rules (provisional, ADR-024)', () => {
  const dart = readFileSync(
    resolve(__dirname, '../../../apps/mobile/lib/core/compliance.dart'),
    'utf8',
  );
  const dartConst = (name: string) => {
    const match = new RegExp(`static const ${name} = ([^;]+);`).exec(dart);
    if (!match) throw new Error(`${name} is missing from the Dart copy`);
    return match[1].trim().replace(/^'|'$/g, '');
  };

  it('the till carries exactly the server’s numbers', () => {
    expect(dartConst('status')).toBe(PSYCHOTROPIC_RULES.status);
    expect(Number(dartConst('maxPsychotropicSubstancesPerPrescription'))).toBe(
      PSYCHOTROPIC_RULES.maxPsychotropicSubstancesPerPrescription,
    );
    expect(Number(dartConst('psychotropicValidityDays'))).toBe(
      PSYCHOTROPIC_RULES.psychotropicValidityDays,
    );
    expect(Number(dartConst('standardValidityDays'))).toBe(
      PSYCHOTROPIC_RULES.standardValidityDays,
    );
    expect(dartConst('dedicatedPrescriptionRequired')).toBe(
      String(PSYCHOTROPIC_RULES.dedicatedPrescriptionRequired),
    );
  });

  it('stays marked provisional until A-1 is recorded as verified', () => {
    // Flipping this is the verification's job, in the same change as compliance-sign-off.md.
    expect(PSYCHOTROPIC_RULES.status).toBe('provisional');
  });

  it('counts validity in calendar days, inclusive of the last one', () => {
    const days = PSYCHOTROPIC_RULES.psychotropicValidityDays;
    expect(prescriptionValidOn('2026-09-01', '2026-09-01')).toEqual({ valid: true, daysUsed: 0 });
    expect(prescriptionValidOn('2026-09-01', `2026-09-${String(1 + days).padStart(2, '0')}`).valid).toBe(true);
    expect(prescriptionValidOn('2026-09-01', `2026-09-${String(2 + days).padStart(2, '0')}`).valid).toBe(false);
    expect(prescriptionValidOn('2026-09-10', '2026-09-09').valid).toBe(false);
  });

  it('reads one prescription paper however it is typed', () => {
    expect(normalisePrescriptionNumber('rx-psy 00417')).toBe('RXPSY00417');
    expect(normalisePrescriptionNumber('RX-PSY-00417')).toBe('RXPSY00417');
  });
});
