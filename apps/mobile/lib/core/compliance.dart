/// The psychotropic dispensing rules (SRS FR-4 §4a) — **PROVISIONAL**, A-1 unverified.
///
/// A copy of `packages/contracts/src/compliance.ts`, which is the source; a parity test in
/// the contracts package fails if the two disagree. They run here, on the till, so the rules
/// hold with no network (docs/04 §6.4); the server checks them again on sync (ADR-024).
abstract final class PsychotropicRules {
  static const status = 'provisional';
  static const maxPsychotropicSubstancesPerPrescription = 1;
  static const psychotropicValidityDays = 15;
  static const standardValidityDays = 30;
  static const dedicatedPrescriptionRequired = true;
}

/// Whether a prescription issued on [issuedOn] is still valid on [dispensedOn] — calendar
/// dates, both `YYYY-MM-DD`. Issued on the 1st with 15 days, it is good through the 16th.
({bool valid, int daysUsed}) prescriptionValidOn(
    String issuedOn, String dispensedOn,
    {int validityDays = PsychotropicRules.psychotropicValidityDays}) {
  DateTime day(String iso) => DateTime.utc(int.parse(iso.substring(0, 4)),
      int.parse(iso.substring(5, 7)), int.parse(iso.substring(8, 10)));
  final daysUsed = day(dispensedOn).difference(day(issuedOn)).inDays;
  return (valid: daysUsed >= 0 && daysUsed <= validityDays, daysUsed: daysUsed);
}

/// "rx-psy 00417" and "RX-PSY-00417" are the same prescription paper.
String normalisePrescriptionNumber(String raw) =>
    raw.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');

/// Today's calendar date in Ethiopia (UTC+3 all year), where every prescription is written.
String addisDate(DateTime instant) => instant
    .toUtc()
    .add(const Duration(hours: 3))
    .toIso8601String()
    .substring(0, 10);
