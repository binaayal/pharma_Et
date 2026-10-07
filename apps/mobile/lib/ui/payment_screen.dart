import 'package:flutter/material.dart';

import '../core/money.dart';
import '../data/customer_repository.dart';
import '../l10n/locale_store.dart';
import 'customers_screen.dart';
import 'kit.dart';
import 'receipt_screen.dart';
import 'terminal.dart';

enum Tender { cash, telebirr, other, credit }

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

  /// Who owes the part not paid now, when the sale is on credit (FR-16).
  LocalCustomer? _customer;

  /// What the customer is paying towards a credit sale right now. Empty means nothing:
  /// the whole sale goes on their account.
  final _paidNow = TextEditingController();

  @override
  void dispose() {
    _received.dispose();
    _paidNow.dispose();
    super.dispose();
  }

  Future<void> _chooseCustomer() async {
    final picked = await pickCustomer(context);
    if (picked != null && mounted) setState(() => _customer = picked);
  }

  Future<void> _complete() async {
    final t = TerminalScope.read(context);
    final due = t.cartTotal;
    final received =
        _tender == Tender.cash ? (parseBirr(_received.text) ?? due) : due;
    final credit = _tender == Tender.credit;
    final paidNow = credit ? (parseBirr(_paidNow.text) ?? 0) : 0;
    final customer = _customer;
    final lines = [
      for (final line in t.cart)
        (
          name: line.product.name,
          qty: line.qty,
          packName: line.pack?.name,
          unit: line.unitName,
          unitPriceSantim: line.unitPriceSantim,
          lineTotalSantim: line.lineTotalSantim
        )
    ];
    setState(() => _busy = true);
    final started = DateTime.now();
    final sale = await t.commit(
      // On credit, whatever is paid now is cash in the drawer.
      method: _tender == Tender.cash || credit ? 'cash' : 'other_recorded',
      customerId: credit ? customer?.id : null,
      creditSantim: credit ? due - paidNow : 0,
    );
    final elapsed = DateTime.now().difference(started).inMilliseconds;
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
      builder: (_) => ReceiptScreen(
        saleId: sale.saleId,
        totalSantim: sale.totalSantim,
        changeSantim: credit ? 0 : received - due,
        creditSantim: credit ? due - paidNow : 0,
        customerName: credit ? customer?.name : null,
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
    final credit = _tender == Tender.credit;
    final paidNow = parseBirr(_paidNow.text) ?? 0;
    // Something must stay on the account for this to be a credit sale at all; paying it
    // all now is a cash sale, and is rung up as one.
    final creditInvalid = credit &&
        (_customer == null ||
            (_paidNow.text.trim().isNotEmpty &&
                parseBirr(_paidNow.text) == null) ||
            paidNow >= due);

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
                if (t.canTakeCredit) (Tender.credit, context.t('pay.credit')),
              ],
              value: _tender,
              onChanged: (v) => setState(() => _tender = v),
            ),
            if (!cash && !credit)
              PNotice.text(
                  Tone.blue, Icons.info_outline, context.t('pay.manualNotice')),
            if (credit) ...[
              // On credit (FR-16): who owes it, and how much of it they are paying now.
              PRows(children: [
                PRow(
                  avatarIcon: Icons.person_outline,
                  avatarTone: _customer == null ? Tone.amber : Tone.green,
                  title: _customer?.name ?? context.t('credit.choose'),
                  subtitle: _customer == null
                      ? context.t('credit.chooseSub')
                      : _customer!.balanceSantim > 0
                          ? '${context.t('credit.alreadyOwes')} ${formatMoney(_customer!.balanceSantim)}'
                          : context.t('credit.owesNothing'),
                  chevron: true,
                  onTap: _chooseCustomer,
                ),
              ]),
              const SizedBox(height: 14),
              PField(
                label: context.t('credit.paidNow'),
                helper: context.t('credit.paidNowHint'),
                controller: _paidNow,
                hint: '0.00',
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
              ),
              PSummary(
                margin: false,
                lines: [
                  (context.t('pay.dueShort'), formatMoney(due)),
                  (context.t('credit.paidNow'), formatMoney(paidNow)),
                ],
                total: (
                  context.t('credit.goesOnAccount'),
                  paidNow >= due ? '—' : formatMoney(due - paidNow)
                ),
              ),
              if (paidNow >= due && due > 0)
                PNotice.text(Tone.amber, Icons.info_outline,
                    context.t('credit.nothingOwed'),
                    margin: const EdgeInsets.only(top: 14)),
            ],
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
            onPressed: _busy || short || creditInvalid || t.cart.isEmpty
                ? null
                : _complete,
          ),
        ),
      ]),
    );
  }
}
