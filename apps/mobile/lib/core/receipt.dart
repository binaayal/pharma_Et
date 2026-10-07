import '../l10n/strings.dart';
import 'money.dart';

/// One line of a receipt, as it was rung up.
class ReceiptLine {
  const ReceiptLine({
    required this.name,
    required this.qty,
    required this.unit,
    required this.unitPriceSantim,
    required this.totalSantim,
  });

  final String name;
  final int qty;

  /// What one of [qty] is: "tablet", or the pack's name when sold by the pack (FR-11).
  final String unit;
  final int unitPriceSantim;
  final int totalSantim;
}

/// How the customer paid, as the receipt says it.
enum ReceiptTender { cash, telebirr, other, credit }

/// A sale as the customer should see it on paper or on their phone (FR-14).
///
/// Built once from the committed sale and rendered three ways — the text that is shared,
/// the page that is printed, and (later) the bytes a thermal printer takes — so the three
/// cannot disagree about what was sold or what it cost.
///
/// Everything here is already-decided fact: the totals are the integers the sale was
/// committed with (G4), never recomputed for display.
class ReceiptDoc {
  const ReceiptDoc({
    required this.shop,
    required this.number,
    required this.soldAt,
    required this.cashier,
    required this.lines,
    required this.totalSantim,
    required this.tender,
    required this.receivedSantim,
    required this.changeSantim,
    this.creditSantim = 0,
    this.customerName,
  });

  /// The name over the door, as far as this device knows it: the branch's name.
  final String shop;

  /// The short reference printed on the slip, e.g. `BOL-1A2B`.
  final String number;
  final DateTime soldAt;

  /// Who served — first name only; the receipt goes home with a stranger.
  final String cashier;
  final List<ReceiptLine> lines;
  final int totalSantim;
  final ReceiptTender tender;

  /// What was handed over. Equal to the total for anything but cash.
  final int receivedSantim;
  final int changeSantim;

  /// What of this sale was put on the customer's account (FR-16); zero otherwise.
  final int creditSantim;

  /// Whose account. Printed, because the slip is that customer's own record of the debt.
  final String? customerName;

  /// The short sale reference from a branch name and a sale id.
  static String numberFor(String branchOrTenant, String saleId) {
    final letters =
        branchOrTenant.replaceAll(RegExp('[^A-Za-z]'), '').toUpperCase();
    final prefix = letters.length >= 3 ? letters.substring(0, 3) : letters;
    final tail = saleId.length >= 4
        ? saleId.substring(saleId.length - 4).toUpperCase()
        : saleId.toUpperCase();
    return prefix.isEmpty ? tail : '$prefix-$tail';
  }

  /// When it was sold, in the Ethiopian calendar with the Gregorian date beside it. Both,
  /// because the customer reads one and an organisation's accounts are kept in the other.
  String when(Strings s) {
    final local = soldAt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final gregorian = '${local.year}-${two(local.month)}-${two(local.day)}';
    return '${s.date(soldAt)} · ${s.time(soldAt)} ($gregorian)';
  }

  String tenderName(Strings s) => switch (tender) {
        ReceiptTender.cash => s.get('pay.cash'),
        ReceiptTender.telebirr => 'Telebirr',
        ReceiptTender.other => s.get('pay.other'),
        ReceiptTender.credit => s.get('pay.credit'),
      };

  /// The lines that say how the sale was settled: label and amount, in order. One list,
  /// so the shared text and the printed page cannot settle the same sale differently.
  List<(String, String)> settlement(Strings s) => [
        (
          s.get('receipt.paidBy'),
          tender == ReceiptTender.credit && customerName != null
              ? '${tenderName(s)} — $customerName'
              : tenderName(s)
        ),
        if (tender == ReceiptTender.cash) ...[
          (s.get('receipt.received'), formatMoney(receivedSantim)),
          (s.get('receipt.change'), formatMoney(changeSantim)),
        ],
        if (tender == ReceiptTender.credit) ...[
          (s.get('credit.paidNow'), formatMoney(receivedSantim)),
          // What the customer still owes **for this sale** — not their whole balance,
          // which the phone may only partly know and the slip must not misstate.
          (s.get('receipt.onAccount'), formatMoney(creditSantim)),
        ],
      ];

  /// `2 box × 100.00` — the quantity in the unit it was sold in.
  static String quantity(ReceiptLine line) =>
      '${line.qty} ${line.unit} × ${formatMoney(line.unitPriceSantim)}';

  /// The receipt as plain text, for SMS, Telegram or anything else that takes words.
  ///
  /// No column alignment: a chat app shows this in a proportional font, where padded
  /// columns come out ragged. Each line carries its own arithmetic instead.
  String toText(Strings s) {
    final out = StringBuffer()
      ..writeln(shop)
      ..writeln('${s.get('receipt.sale')} #$number')
      ..writeln(when(s))
      ..writeln();
    for (final line in lines) {
      out
        ..writeln(line.name)
        ..writeln('  ${quantity(line)} = ${formatMoney(line.totalSantim)}');
    }
    out
      ..writeln()
      ..writeln('${s.get('receipt.total')}: ${formatEtb(totalSantim)}');
    for (final (label, value) in settlement(s)) {
      out.writeln('$label: $value');
    }
    out
      ..writeln()
      ..writeln('${s.get('receipt.servedBy')}: $cashier')
      ..write(s.get('receipt.thanks'));
    return out.toString();
  }
}
