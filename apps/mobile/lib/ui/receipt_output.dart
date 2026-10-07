import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../core/money.dart';
import '../core/receipt.dart';
import '../l10n/strings.dart';

/// Getting a receipt out of the phone (FR-14): shared as text, or printed as a page.
///
/// **Sharing** hands plain text to whatever the phone has — SMS, Telegram, WhatsApp, email.
/// It needs no network of its own and no printer, and it is how a customer in Addis keeps
/// a record anyway.
///
/// **Printing** goes through the phone's own print system: any printer the phone has a
/// print service for (most Wi-Fi printers, and thermal printers whose maker ships one),
/// and "Save as PDF" where there is none. The page is laid out narrow, like a till slip,
/// so it prints sensibly on an 80mm roll and on A4 alike.
///
/// Printing straight to a Bluetooth thermal printer, with no print service in between, is
/// a separate piece of work: it needs the printer in hand (ADR-032).
abstract final class ReceiptOutput {
  /// For tests: replaces the platform share sheet.
  static Future<void> Function(String text, String subject)? debugShare;

  /// For tests: replaces the platform print dialog. Receives the rendered PDF.
  static Future<void> Function(Uint8List pdf, String name)? debugPrint;

  static Future<void> share(ReceiptDoc doc, Strings s) async {
    final text = doc.toText(s);
    final subject = '${doc.shop} · ${s.get('receipt.sale')} #${doc.number}';
    final override = debugShare;
    if (override != null) return override(text, subject);
    await SharePlus.instance.share(ShareParams(text: text, subject: subject));
  }

  static Future<void> print(ReceiptDoc doc, Strings s) async {
    final name = 'receipt-${doc.number}';
    final override = debugPrint;
    if (override != null) return override(await pdf(doc, s), name);
    await Printing.layoutPdf(
      name: name,
      // The dialog tells us the paper; the receipt is laid out to it.
      onLayout: (format) => pdf(doc, s, format: format),
    );
  }

  static pw.Font? _ethiopic;

  /// The font a receipt's Amharic is set in.
  ///
  /// Noto Sans Ethiopic, bundled. The PDF library's built-in fonts have no Ethiopic
  /// glyphs, so without it an Amharic receipt prints as a row of empty boxes — and a
  /// font fetched at print time would fail in exactly the shop this is built for.
  ///
  /// It is the **fallback**, not the base: it has the Ethiopic letters and no digits, so
  /// prices, product names and the date are set in the library's Helvetica and only the
  /// Amharic words fall through to this.
  static Future<pw.Font> _ethiopicFont({AssetBundle? bundle}) async =>
      _ethiopic ??= pw.Font.ttf(await (bundle ?? rootBundle)
          .load('assets/fonts/NotoSansEthiopic-Regular.ttf'));

  /// The widest a receipt is drawn, whatever the paper: an 80mm roll's printable width.
  static const double _slipWidth = 72 * PdfPageFormat.mm;

  /// Renders the receipt as a PDF.
  ///
  /// One column, as wide as a till roll and no wider — on A4 it sits at the top left like
  /// a slip stapled to a page, which is what an organisation's accounts office expects to
  /// file. Every figure is the integer the sale was committed with (G4).
  static Future<Uint8List> pdf(
    ReceiptDoc doc,
    Strings s, {
    PdfPageFormat? format,
    AssetBundle? bundle,
  }) async {
    final ethiopic = await _ethiopicFont(bundle: bundle);
    final page = format ?? PdfPageFormat.roll80;
    final document = pw.Document(
      title: '${doc.shop} #${doc.number}',
      theme: pw.ThemeData.withFont(
        base: pw.Font.helvetica(),
        bold: pw.Font.helveticaBold(),
        fontFallback: [ethiopic],
      ),
    );

    const small = pw.TextStyle(fontSize: 8.5, color: PdfColors.grey800);
    const body = pw.TextStyle(fontSize: 9.5);
    const strong = pw.TextStyle(fontSize: 10.5, fontWeight: pw.FontWeight.bold);

    pw.Widget row(String left, String right, {pw.TextStyle? style}) => pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(child: pw.Text(left, style: style ?? body)),
            pw.SizedBox(width: 6),
            pw.Text(right, style: style ?? body),
          ],
        );
    pw.Widget rule() => pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 5),
          child: pw.Divider(height: 1, thickness: 0.6),
        );

    final margin = pw.EdgeInsets.all(page.width > 100 * PdfPageFormat.mm
        ? 14 * PdfPageFormat.mm
        : 4 * PdfPageFormat.mm);
    final slip = pw.SizedBox(
      width: _slipWidth,
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Text(doc.shop,
              style: const pw.TextStyle(
                  fontSize: 13, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 2),
          pw.Text(
              doc.wholesale
                  ? '${s.get('receipt.sale')} #${doc.number} · ${s.get('tier.wholesale')}'
                  : '${s.get('receipt.sale')} #${doc.number}',
              style: body),
          pw.Text(doc.when(s), style: small),
          rule(),
          for (final line in doc.lines) ...[
            pw.Text(line.name, style: body),
            row('  ${ReceiptDoc.quantity(line)}',
                formatMoney(line.totalSantim)),
            pw.SizedBox(height: 3),
          ],
          rule(),
          row(s.get('receipt.total'), formatEtb(doc.totalSantim),
              style: strong),
          pw.SizedBox(height: 2),
          for (final (label, value) in doc.settlement(s)) row(label, value),
          rule(),
          pw.Text('${s.get('receipt.servedBy')}: ${doc.cashier}', style: small),
          pw.SizedBox(height: 2),
          pw.Text(s.get('receipt.thanks'), style: small),
        ],
      ),
    );

    if (page.height.isFinite) {
      // Cut paper: a long receipt runs on to a second sheet rather than off the first.
      document.addPage(pw.MultiPage(
          pageFormat: page, margin: margin, build: (context) => [slip]));
    } else {
      // A roll has no page height; the slip is as long as the sale.
      document.addPage(
          pw.Page(pageFormat: page, margin: margin, build: (context) => slip));
    }
    return document.save();
  }
}
