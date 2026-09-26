import 'package:flutter/material.dart';

import '../core/money.dart';
import '../l10n/locale_store.dart';
import 'kit.dart';
import 'receipt_screen.dart';
import 'terminal.dart';

enum Tender { cash, telebirr, other }

/// Payment (prototype screen 09; FR-4).
///
/// Cash is the V1 tender. Telebirr and the rest are recorded by hand — there is no live
/// integration — and they are recorded as `other_recorded`, so they never count toward the
/// cash expected in the drawer at close (BR-8.2). The sale commits to the device first and
/// syncs after; nothing here waits for a network.
class PaymentScreen extends StatefulWidget {
  const PaymentScreen({super.key});

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen> {
  Tender _tender = Tender.cash;
  final _received = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _received.dispose();
    super.dispose();
  }

  Future<void> _complete() async {
    final t = TerminalScope.read(context);
    final due = t.cartTotal;
    final received =
        _tender == Tender.cash ? (parseBirr(_received.text) ?? due) : due;
    final lines = [
      for (final line in t.cart)
        (
          name: line.product.name,
          qty: line.qty,
          lineTotalSantim: line.lineTotalSantim
        )
    ];
    setState(() => _busy = true);
    final started = DateTime.now();
    final sale = await t.commit(
        method: _tender == Tender.cash ? 'cash' : 'other_recorded');
    final elapsed = DateTime.now().difference(started).inMilliseconds;
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
      builder: (_) => ReceiptScreen(
        saleId: sale.saleId,
        totalSantim: sale.totalSantim,
        changeSantim: received - due,
        lines: lines,
        tender: _tender,
        commitMs: elapsed,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final t = TerminalScope.of(context);
    final due = t.cartTotal;
    final received = parseBirr(_received.text);
    final cash = _tender == Tender.cash;
    // An empty field means "exact amount": the commonest case at a counter is one tap.
    final short = cash && received != null && received < due;

    return Scaffold(
      body: Column(children: [
        PTopBar(
            title: context.t('pay.title'),
            onBack: () => Navigator.of(context).pop()),
        Expanded(
          child: PBody(children: [
            PSummary(
                margin: false,
                lines: const [],
                total: (context.t('pay.due'), formatEtbShort(due))),
            PSection(context.t('pay.method')),
            PSegmented<Tender>(
              options: [
                (Tender.cash, context.t('pay.cash')),
                (Tender.telebirr, 'Telebirr'),
                (Tender.other, context.t('pay.other')),
              ],
              value: _tender,
              onChanged: (v) => setState(() => _tender = v),
            ),
            if (!cash)
              PNotice.text(
                  Tone.blue, Icons.info_outline, context.t('pay.manualNotice')),
            if (cash) ...[
              PField(
                label: context.t('pay.received'),
                controller: _received,
                hint: formatMoney(due),
                large: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
              ),
              PSummary(
                lines: [
                  (
                    context.t('pay.receivedShort'),
                    formatMoney(received ?? due)
                  ),
                  (context.t('pay.dueShort'), formatMoney(due)),
                ],
                total: (
                  context.t('pay.change'),
                  short ? '—' : formatMoney((received ?? due) - due)
                ),
              ),
              if (short)
                PNotice.text(
                    Tone.red, Icons.error_outline, context.t('pay.notEnough'),
                    margin: const EdgeInsets.only(top: 14)),
            ],
          ]),
        ),
        PFooter(
          child: PButton(
            label: _busy ? context.t('pay.saving') : context.t('pay.complete'),
            onPressed: _busy || short || t.cart.isEmpty ? null : _complete,
          ),
        ),
      ]),
    );
  }
}
