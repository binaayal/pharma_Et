/**
 * The psychotropic dispensing rules (SRS FR-4 §4a, docs/04 §6.4) — **PROVISIONAL**.
 *
 * Every number here is SRS `[ASSUMPTION]` A-1: stated from the SRS, **not yet verified**
 * against the EFDA retail-pharmacy directive. They exist in code only because the owner
 * chose to build the regulated half ahead of verification (ADR-024), and they are inert
 * until the server's `CONTROLLED_DISPENSING` switch is turned on — which ADR-024 forbids
 * before A-1 is verified and recorded in `docs/compliance-sign-off.md`.
 *
 * One place, so verification changes one file. The Dart copy in
 * `apps/mobile/lib/core/compliance.dart` is checked against this one by a parity test.
 */
export const PSYCHOTROPIC_RULES = {
  status: 'provisional' as const,
  /** BR-4.2 / AC-4.2: a second psychotropic substance on one prescription is blocked. */
  maxPsychotropicSubstancesPerPrescription: 1,
  /** AC-4.3: a psychotropic prescription is valid this many days from issue. */
  psychotropicValidityDays: 15,
  /** FR-4 §4a: the standard validity, for comparison and for non-psychotropic controlled. */
  standardValidityDays: 30,
  /** FR-4 §4a: psychotropics require the dedicated prescription paper's number. */
  dedicatedPrescriptionRequired: true,
} as const;

/**
 * Whether a prescription is still valid on a dispensing day. Calendar dates, compared as
 * dates: a prescription issued on the 1st with 15 days of validity is good through the 16th.
 */
export function prescriptionValidOn(
  issuedOn: string,
  dispensedOn: string,
  validityDays: number = PSYCHOTROPIC_RULES.psychotropicValidityDays,
): { valid: boolean; daysUsed: number } {
  const day = (iso: string) => Date.UTC(+iso.slice(0, 4), +iso.slice(5, 7) - 1, +iso.slice(8, 10));
  const daysUsed = Math.round((day(dispensedOn) - day(issuedOn)) / 86_400_000);
  return { valid: daysUsed >= 0 && daysUsed <= validityDays, daysUsed };
}

/** Prescription numbers compare without case or spacing: "rx-psy 00417" is "RX-PSY-00417". */
export function normalisePrescriptionNumber(raw: string): string {
  return raw.toUpperCase().replace(/[^A-Z0-9]/g, '');
}
