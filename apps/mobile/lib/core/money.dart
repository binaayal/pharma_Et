/// Money is an integer count of santim, everywhere (docs/04 §3, guardian G4).
///
/// There is no `double` in this file and there must not be one anywhere near money in this
/// app. A rounding drift of a few santim per sale is invisible for months and then the till
/// does not reconcile, which is an S1 defect class.
///
/// The division to birr happens exactly once, here, on the way to the screen — never in
/// state, never in a calculation, never on the way back to the server.
library;

String formatEtb(int santim) {
  final sign = santim < 0 ? '-' : '';
  final absolute = santim.abs();
  final birr = absolute ~/ 100;
  final cents = absolute % 100;
  final grouped = _group(birr);
  return '$sign$grouped.${cents.toString().padLeft(2, '0')} ETB';
}

String _group(int value) {
  final digits = value.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// Line total from quantity and unit price. Integer arithmetic only — the server and the
/// database both assert `lineTotal == qty * unitPrice`, so a client that computed it any
/// other way would have its sales rejected.
int lineTotalSantim({required int qty, required int unitPriceSantim}) => qty * unitPriceSantim;
