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
int lineTotalSantim({required int qty, required int unitPriceSantim}) =>
    qty * unitPriceSantim;

/// Parses what a person typed — `500`, `1,250.5`, `18,600.00` — into santim, without ever
/// passing through a `double` (guardian G4). Null when it is not an amount of money.
int? parseBirr(String text) {
  final cleaned = text.trim().replaceAll(',', '').replaceAll(' ', '');
  if (cleaned.isEmpty) return null;
  final parts = cleaned.split('.');
  if (parts.length > 2) return null;
  final birr = int.tryParse(parts[0].isEmpty ? '0' : parts[0]);
  if (birr == null || birr < 0) return null;
  if (parts.length == 1) return birr * 100;
  if (parts[1].isEmpty) return birr * 100;
  if (parts[1].length > 2 || int.tryParse(parts[1]) == null) return null;
  return birr * 100 + int.parse(parts[1].padRight(2, '0'));
}

/// `24,900` or `24,900.50` — birr, grouped, with santim only when there are some. For
/// tiles and rows where the currency is printed beside the number (prototype `.tile .v`).
String formatBirr(int santim) {
  final sign = santim < 0 ? '-' : '';
  final absolute = santim.abs();
  final cents = absolute % 100;
  final whole = '$sign${_group(absolute ~/ 100)}';
  return cents == 0 ? whole : '$whole.${cents.toString().padLeft(2, '0')}';
}

/// `ETB 42,180` — the headline form on Home and Reports.
String formatEtbShort(int santim) => 'ETB ${formatBirr(santim)}';

/// `9.00`, `18,740.00` — itemised amounts, always with santim, as on a receipt.
String formatMoney(int santim) {
  final sign = santim < 0 ? '-' : '';
  final absolute = santim.abs();
  return '$sign${_group(absolute ~/ 100)}.${(absolute % 100).toString().padLeft(2, '0')}';
}
