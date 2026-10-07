import 'package:flutter/material.dart';

import '../core/money.dart';
import '../core/receipt.dart';
import '../core/theme.dart';
import '../l10n/locale_store.dart';
import '../sync/sync_service.dart';
import 'kit.dart';
import 'payment_screen.dart';
import 'receipt_output.dart';
import 'sync_chip.dart';
import 'terminal.dart';

/// Sale complete (prototype screen 10; NFR-1).
///
/// The receipt exists whether or not there is a network. The chip and the notice keep the
/// sync state honest to the cashier: "queued" until the server has acknowledged it.
class ReceiptScreen extends StatelessWidget {
  const ReceiptScreen({
    super.key,
    required this.saleId,
    required this.totalSantim,
    required this.changeSantim,
    required this.lines,
    required this.tender,
    required this.commitMs,
  });

  final String saleId;
  final int totalSantim;
  final int changeSantim;
  final List<
      ({
        String name,
        int qty,
        String? packName,
        String unit,
        int unitPriceSantim,
        int lineTotalSantim
      })> lines;
  final Tender tender;
  final int commitMs;

  @override
  Widget build(BuildContext context) {
    final t = TerminalScope.of(context);
    final synced = t.status.pending == 0 && t.status.state != SyncState.offline;
    final now = DateTime.now();
    final shop = t.branchName ?? t.session.tenantCode;
    final number = ReceiptDoc.numberFor(shop, saleId);
    // The one description of this sale that the share text and the printed page are both
    // rendered from, so the two cannot disagree (FR-14).
    final doc = ReceiptDoc(
      shop: shop,
      number: number,
      soldAt: now,
      cashier: t.firstName,
      lines: [
        for (final line in lines)
          ReceiptLine(
            name: line.name,
            qty: line.qty,
            unit: line.unit,
            unitPriceSantim: line.unitPriceSantim,
            totalSantim: line.lineTotalSantim,
          ),
      ],
      totalSantim: totalSantim,
      tender: switch (tender) {
        Tender.cash => ReceiptTender.cash,
        Tender.telebirr => ReceiptTender.telebirr,
        Tender.other => ReceiptTender.other,
      },
      receivedSantim: totalSantim + changeSantim,
      changeSantim: changeSantim,
    );

    return Scaffold(
      body: Column(children: [
        PTopBar(
          title: context.t('receipt.title'),
          trailing: [SyncChip(status: t.status, onTap: t.sync)],
        ),
        Expanded(
          child: PBody(children: [
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: const [
                  BoxShadow(
                      color: Color(0x140D3B2B),
                      blurRadius: 26,
                      offset: Offset(0, 8))
                ],
              ),
              child: Column(children: [
                const PMark(icon: Icons.check_rounded),
                const SizedBox(height: 12),
                Text(
                    '${formatEtbShort(totalSantim)} ${context.t('receipt.paid')}',
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(
                    '${context.t('receipt.sale')} #$number · ${context.l10n.date(now)}, ${context.l10n.time(now)}',
                    style: const TextStyle(
                        fontSize: 12.5, color: PharmaColors.muted)),
                const SizedBox(height: 16),
                for (final line in lines)
                  _line(
                      // "×2 box" when sold by the pack, so the paper says what was
                      // handed over rather than leaving "×2" to mean two tablets.
                      line.packName == null
                          ? '${line.name} ×${line.qty}'
                          : '${line.name} ×${line.qty} ${line.packName}',
                      formatMoney(line.lineTotalSantim)),
                if (tender == Tender.cash)
                  _line(context.t('receipt.change'), formatMoney(changeSantim),
                      last: true)
                else
                  _line(
                      context.t('receipt.paidBy'),
                      tender == Tender.telebirr
                          ? 'Telebirr'
                          : context.t('pay.other'),
                      last: true),
              ]),
            ),
            const SizedBox(height: 14),
            synced
                ? PNotice.text(Tone.green, Icons.cloud_done_outlined,
                    context.t('receipt.synced'))
                : PNotice.text(Tone.amber, Icons.schedule,
                    '${context.t('receipt.queued')} ($commitMs ms)'),
          ]),
        ),
        PFooter(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            PButtonRow(
              left: PButton(
                kind: BtnKind.plain,
                icon: Icons.ios_share,
                label: context.t('receipt.share'),
                onPressed: () => _send(
                    context, () => ReceiptOutput.share(doc, context.l10n)),
              ),
              right: PButton(
                kind: BtnKind.plain,
                icon: Icons.print_outlined,
                label: context.t('receipt.print'),
                onPressed: () => _send(
                    context, () => ReceiptOutput.print(doc, context.l10n)),
              ),
            ),
            const SizedBox(height: 10),
            PButton(
              label: context.t('receipt.newSale'),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ]),
        ),
      ]),
    );
  }

  /// Shares or prints, and says so if the phone could not. The sale is already committed
  /// and queued by the time this screen exists: a receipt that fails to print costs a
  /// piece of paper, never the sale, so a failure here is a message and nothing more.
  Future<void> _send(
      BuildContext context, Future<void> Function() action) async {
    final failed = context.t('receipt.outputFailed');
    try {
      await action();
    } catch (_) {
      if (context.mounted) toast(context, failed);
    }
  }

  Widget _line(String left, String right, {bool last = false}) => Container(
        padding: const EdgeInsets.symmetric(vertical: 7),
        decoration: BoxDecoration(
          border: last
              ? null
              : const Border(
                  bottom: BorderSide(color: PharmaColors.line, width: 0.8)),
        ),
        child: Row(children: [
          Expanded(child: Text(left, style: const TextStyle(fontSize: 13))),
          Text(right,
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
        ]),
      );
}
