import 'package:flutter/material.dart';

import '../core/money.dart';
import '../core/theme.dart';
import '../l10n/locale_store.dart';
import '../sync/sync_service.dart';
import 'kit.dart';
import 'payment_screen.dart';
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
  final List<({String name, int qty, int lineTotalSantim})> lines;
  final Tender tender;
  final int commitMs;

  @override
  Widget build(BuildContext context) {
    final t = TerminalScope.of(context);
    final synced = t.status.pending == 0 && t.status.state != SyncState.offline;
    final now = DateTime.now();
    final prefix = (t.branchName ?? t.session.tenantCode)
        .replaceAll(RegExp('[^A-Za-z]'), '')
        .toUpperCase();
    final number =
        '${prefix.length >= 3 ? prefix.substring(0, 3) : prefix}-${saleId.substring(saleId.length - 4).toUpperCase()}';

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
                  _line('${line.name} ×${line.qty}',
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
          child: PButtonRow(
            left: PButton(
              kind: BtnKind.plain,
              label: context.t('receipt.print'),
              onPressed: () => toast(context, context.t('receipt.noPrinter')),
            ),
            right: PButton(
              label: context.t('receipt.newSale'),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ),
      ]),
    );
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
