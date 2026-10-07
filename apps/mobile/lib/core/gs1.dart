/// Reading what a barcode scanner returns (FR-13, ADR-031).
///
/// Two kinds of code arrive at a pharmacy counter:
///
///   - the **retail barcode** on the box — EAN-13 mostly — which is just a product number
///     (a GTIN);
///   - the **GS1 DataMatrix** EFDA's traceability scheme is moving medicines to, which
///     carries the GTIN *and* the batch number and expiry date printed beside it.
///
/// Both identify the same product, and the second also fills in the two fields of a goods
/// receipt most likely to be mistyped. Everything here is pure and offline: a scan is
/// matched against the catalogue already on the phone.
library;

/// A barcode in the one form it is stored and compared in.
///
/// An all-digit code of 8, 12 or 13 digits is a GTIN with its leading zeros dropped, and is
/// padded to 14 — so the EAN-13 on a box and the GTIN inside its DataMatrix are one value.
/// Anything else is kept as read, trimmed.
///
/// Implemented a second time in TypeScript (`canonicalBarcode` in the contract), because
/// the server stores the links this matches against. `kBarcodeVectors` is run against both.
String canonicalBarcode(String raw) {
  final code = raw.trim();
  final isShortGtin =
      (code.length == 8 || code.length == 12 || code.length == 13) &&
          _digits.hasMatch(code);
  return isShortGtin ? code.padLeft(14, '0') : code;
}

final _digits = RegExp(r'^\d+$');

/// What one scan said.
class ScannedCode {
  const ScannedCode({required this.barcode, this.lot, this.expiry});

  /// The product's barcode, canonical — what a product's links are compared with.
  final String barcode;

  /// The batch/lot number, when the code carried one (GS1 AI 10).
  final String? lot;

  /// The expiry as an ISO calendar date, when the code carried one (GS1 AI 17).
  final String? expiry;

  /// Whether this came from a GS1 code with more than a product number in it.
  bool get hasBatch => lot != null || expiry != null;
}

/// The GS1 group separator a scanner puts after a variable-length field.
const _gs = '\u001d';

/// Application identifiers whose value has a fixed length (GS1 General Specifications,
/// "pre-defined length" table), by their first two digits: the value's length, AI excluded.
const _fixedLength = <String, int>{
  '00': 18,
  '01': 14,
  '02': 14,
  '03': 14,
  '04': 16,
  '11': 6,
  '12': 6,
  '13': 6,
  '14': 6,
  '15': 6,
  '16': 6,
  '17': 6,
  '18': 6,
  '19': 6,
  '20': 2,
  '31': 6,
  '32': 6,
  '33': 6,
  '34': 6,
  '35': 6,
  '36': 6,
  '41': 13,
};

/// Variable-length identifiers that have a two-digit AI. Everything else variable that
/// this app might meet has a three- or four-digit AI, and ends the parse (see below).
const _twoDigitVariable = {
  '10',
  '21',
  '22',
  '30',
  '37',
  '90',
  '91',
  '92',
  '93',
  '94',
  '95',
  '96',
  '97',
  '98',
  '99'
};

/// Reads a scanner's raw string.
///
/// Never throws and never returns null for a non-empty scan: a code this cannot take apart
/// is still a code, and is returned whole so it can be linked to a product as it is. The
/// worst outcome of an unreadable DataMatrix is "unknown barcode", never a wrong product.
ScannedCode? parseScan(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return null;

  // "(01)06291100080014(17)271231(10)LOT42" — the human-readable form, which some
  // scanners and most hand-typed tests produce.
  if (text.startsWith('(')) {
    final fields = <String, String>{
      for (final m in RegExp(r'\((\d{2,4})\)([^(]*)').allMatches(text))
        m.group(1)!: m.group(2)!.trim(),
    };
    final gtin = fields['01'];
    if (gtin != null && gtin.length == 14 && _digits.hasMatch(gtin)) {
      return ScannedCode(
          barcode: gtin,
          lot: _lot(fields['10']),
          expiry: _expiry(fields['17']));
    }
    return ScannedCode(barcode: canonicalBarcode(text));
  }

  // Symbology identifier some scanners prefix: "]d2" DataMatrix, "]C1" GS1-128, "]Q3" QR.
  if (text.startsWith(']') && text.length > 3) text = text.substring(3);
  // A leading FNC1, as a separator.
  while (text.startsWith(_gs)) {
    text = text.substring(1);
  }

  final looksGs1 = text.contains(_gs) ||
      (text.length > 16 &&
          text.startsWith('01') &&
          _digits.hasMatch(text.substring(0, 16)));
  if (!looksGs1) return ScannedCode(barcode: canonicalBarcode(text));

  String? gtin;
  String? lot;
  String? expiry;
  var i = 0;
  while (i + 2 <= text.length) {
    if (text[i] == _gs) {
      i++;
      continue;
    }
    final ai = text.substring(i, i + 2);
    String value;
    final fixed = _fixedLength[ai];
    if (fixed != null) {
      if (i + 2 + fixed > text.length) break;
      value = text.substring(i + 2, i + 2 + fixed);
      i += 2 + fixed;
    } else if (_twoDigitVariable.contains(ai)) {
      final end = text.indexOf(_gs, i + 2);
      value = text.substring(i + 2, end < 0 ? text.length : end);
      i = end < 0 ? text.length : end + 1;
    } else {
      // An identifier this does not know the shape of. Stop rather than guess where it
      // ends: everything read so far is sound, and a guess could turn part of a serial
      // number into an expiry date.
      break;
    }
    switch (ai) {
      case '01':
        gtin ??= value;
      case '10':
        lot ??= value;
      case '17':
        expiry ??= value;
    }
  }

  if (gtin == null || !_digits.hasMatch(gtin)) {
    return ScannedCode(barcode: canonicalBarcode(text.replaceAll(_gs, '')));
  }
  return ScannedCode(barcode: gtin, lot: _lot(lot), expiry: _expiry(expiry));
}

String? _lot(String? value) {
  final lot = value?.trim();
  return lot == null || lot.isEmpty || lot.length > 64 ? null : lot;
}

/// GS1 `YYMMDD` to an ISO date, or null if it is not a date.
///
/// Day `00` means "the month, no day" and is read as the month's **last** day, which is
/// what GS1 specifies and what a pharmacist means by "expires 12/27". The century follows
/// GS1's sliding window; for an expiry that is simply 20YY for decades to come.
String? _expiry(String? value) {
  if (value == null || value.length != 6 || !_digits.hasMatch(value)) {
    return null;
  }
  final yy = int.parse(value.substring(0, 2));
  final month = int.parse(value.substring(2, 4));
  var day = int.parse(value.substring(4, 6));
  if (month < 1 || month > 12 || day > 31) return null;

  final thisYear = DateTime.now().year;
  var year = (thisYear ~/ 100) * 100 + yy;
  if (year - thisYear >= 51) year -= 100;
  if (thisYear - year >= 50) year += 100;

  final lastDay = DateTime(year, month + 1, 0).day;
  if (day == 0) day = lastDay;
  if (day > lastDay) return null;
  return '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}'
      '-${day.toString().padLeft(2, '0')}';
}
