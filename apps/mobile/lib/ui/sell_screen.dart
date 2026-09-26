import 'package:flutter/material.dart';

import '../core/money.dart';
import '../core/permissions.dart';
import '../core/theme.dart';
import '../data/catalog_repository.dart';
import '../l10n/locale_store.dart';
import 'dispense_screen.dart';
import 'kit.dart';
import 'payment_screen.dart';
import 'sync_chip.dart';
import 'terminal.dart';
import 'till.dart';

/// New sale (prototype screen 08; FR-4, FR-3).
///
/// The rule this screen exists to honour: **a sale is never blocked.** Not by a stock count,
/// not by a missing network, not by a stale catalog. FEFO picks the first-to-expire batch;
/// selling past zero is allowed, shown, and flagged for reconciliation.
class SellScreen extends StatefulWidget {
  const SellScreen({super.key});

  @override
  State<SellScreen> createState() => _SellScreenState();
}

class _SellScreenState extends State<SellScreen> {
  final _search = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // Focusing the search box offers the catalog, so a second product is one tap away
    // rather than a typed name away.
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _add(LocalProduct product) async {
    final t = TerminalScope.read(context);
    if (!t.can(Capability.saleCreate)) return;

    // Controlled substances go through the immutable ledger with dispensing rules that
    // arrive behind the A-1 compliance gate (prototype screen 11). Refusing here is honest;
    // selling one through the standard path would put an unauditable record in the system.
    if (product.isControlled) {
      if (t.controlledEnabled && t.can(Capability.controlledDispense)) {
        await Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => DispenseScreen(product: product)));
      } else {
        toast(context, context.t('pos.controlledLater'));
      }
      return;
    }

    // FEFO picks the batch (AC-3.2). No batch does NOT stop the sale (BR-3.2).
    var batch = await t.catalog.fefoBatch(product.id, t.branchId);
    String? overrideBy;
    if (batch == null) {
      // "No stock" and "only expired stock" are different things to the person about to
      // take a box off the shelf (E-4.2, ADR-020).
      final expired =
          await t.catalog.expiredFallbackBatch(product.id, t.branchId);
      if (!mounted) return;
      if (expired != null && await _confirmExpired(product, expired)) {
        batch = expired;
        overrideBy = t.session.scope.userId;
      }
    }
    final onHand = await t.catalog.onHand(product.id, t.branchId);
    if (!mounted) return;
    t.addLine(product, batch: batch, overrideBy: overrideBy, onHand: onHand);
    _search.clear();
    FocusScope.of(context).unfocus();
  }

  /// The only stock is expired (E-4.2, ADR-020). True only when someone who *may*
  /// authorise it has done so; a cashier is warned, has no button, and can still sell.
  Future<bool> _confirmExpired(LocalProduct product, LocalBatch expired) async {
    final t = TerminalScope.read(context);
    final mayOverride = t.can(Capability.expiryOverride);
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (d) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded,
            color: PharmaColors.red, size: 36),
        title: Text(d.t('expired.title')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              d.tf('expired.body', {
                'product': product.name,
                'lot': expired.lotNo,
                'date': d.l10n.calendarDate(expired.expiryDate),
              }),
              style: const TextStyle(fontSize: 14.5, height: 1.4),
            ),
            const SizedBox(height: 12),
            Text(
              d.t(mayOverride
                  ? 'expired.mayOverride'
                  : 'expired.cannotOverride'),
              style: const TextStyle(
                  fontSize: 13.5, height: 1.4, color: PharmaColors.muted),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(d).pop(false),
            child: Text(d.t(mayOverride ? 'expired.doNot' : 'common.continue')),
          ),
          if (mayOverride)
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: PharmaColors.red),
              onPressed: () => Navigator.of(d).pop(true),
              child: Text(d.t('expired.authorise')),
            ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final t = TerminalScope.of(context);
    final q = _search.text.trim().toLowerCase();
    final results = q.isEmpty
        ? (t.cart.isEmpty || _focus.hasFocus
            ? t.products
            : const <LocalProduct>[])
        : t.products.where((p) => p.name.toLowerCase().contains(q)).toList();
    final short = [
      for (final line in t.cart)
        if (line.qty > (t.cartOnHand[line.product.id] ?? 0)) line,
    ];

    return Scaffold(
      body: Column(
        children: [
          PTopBar(
            tone: BarTone.green,
            title: context.t('sell.title'),
            subtitle:
                '${t.branchName ?? t.session.tenantCode} · ${t.firstName}',
            onBack: () => Navigator.of(context).pop(),
            trailing: [SyncChip(status: t.status, onTap: t.sync)],
          ),
          Expanded(
            child: PBody(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
                children: [
                  _SearchBox(
                    controller: _search,
                    focusNode: _focus,
                    hint: context.t('sell.search'),
                    onChanged: (_) => setState(() {}),
                  ),
                  if (t.shift == null && t.can(Capability.saleCreate))
                    GestureDetector(
                      onTap: () => openTill(context),
                      child: PNotice.text(
                          Tone.amber,
                          Icons.point_of_sale_outlined,
                          '${context.t('shift.noTill')} — ${context.t('shift.tapToOpen')}'),
                    ),
                  if (t.products.isEmpty)
                    PNotice.text(Tone.blue, Icons.info_outline,
                        '${context.t('pos.noCatalog')}. ${context.t('pos.noCatalogHint')}'),
                  if (results.isNotEmpty) ...[
                    PRows(children: [
                      for (final p in results)
                        PRow(
                          avatar: p.name.characters.first.toUpperCase(),
                          avatarTone: p.isControlled ? Tone.blue : Tone.green,
                          title: p.name,
                          subtitleWidget: p.isControlled
                              ? Row(children: [
                                  PBadge(context.t('stock.controlled'),
                                      tone: Tone.blue),
                                  const SizedBox(width: 6),
                                  Text(context.t('stock.ledgerTracked'),
                                      style: const TextStyle(
                                          fontSize: 12.5,
                                          color: PharmaColors.muted)),
                                ])
                              : Text('${context.t('pos.perUnit')} ${p.unit}',
                                  style: const TextStyle(
                                      fontSize: 12.5,
                                      color: PharmaColors.muted)),
                          value: formatMoney(p.priceSantim),
                          valueCaption: 'ETB',
                          onTap: () => _add(p),
                        ),
                    ]),
                    if (t.cart.isNotEmpty) const SizedBox(height: 10),
                  ],
                  for (var i = 0; i < t.cart.length; i++)
                    _cartLine(context, t, i),
                  for (final line in short)
                    PNotice(
                      tone: Tone.amber,
                      icon: Icons.error_outline,
                      margin: const EdgeInsets.only(top: 14),
                      child: Text.rich(TextSpan(children: [
                        TextSpan(
                            text: line.product.name,
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)),
                        TextSpan(
                            text: ' ${context.tf('sell.oversell', {
                              'n': t.cartOnHand[line.product.id] ?? 0
                            })}'),
                      ])),
                    ),
                  if (t.cart.isNotEmpty)
                    PSummary(
                      lines: [
                        (context.t('sell.subtotal'), formatMoney(t.cartTotal)),
                        (context.t('sell.items'), '${t.cartItems}'),
                      ],
                      total: (
                        context.t('sell.totalEtb'),
                        formatMoney(t.cartTotal)
                      ),
                    ),
                ]),
          ),
          PFooter(
            child: PButton(
              label: t.cart.isEmpty
                  ? context.t('sell.addToStart')
                  : '${context.t('sell.charge')} ${formatEtbShort(t.cartTotal)}',
              onPressed: t.cart.isEmpty
                  ? null
                  : () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => const PaymentScreen())),
            ),
          ),
        ],
      ),
    );
  }

  /// `.cart-line` — name, the batch FEFO chose, and a quantity stepper.
  Widget _cartLine(BuildContext context, Terminal t, int index) {
    final line = t.cart[index];
    final batch = t.cartBatch[line.product.id];
    final detail = batch == null
        ? context.t('sell.noBatch')
        : '${context.t('stock.lot')} ${batch.lotNo} · ${context.t('stock.exp')} ${context.l10n.calendarDate(batch.expiryDate)}'
            '${line.expiryOverrideBy != null ? ' · ${context.t('sell.expiredAuthorised')}' : ' · FEFO'}';
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 13),
      decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xFFE7ECE9)))),
      child: Row(children: [
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(line.product.name,
                style: const TextStyle(
                    fontSize: 14.5, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(detail,
                style: TextStyle(
                    fontSize: 12,
                    color: line.expiryOverrideBy != null
                        ? PharmaColors.red
                        : PharmaColors.muted)),
          ]),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(11),
            boxShadow: cardShadow,
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            _Step(
                label: '−',
                semantics: context.t('sell.less'),
                onTap: () => t.setQty(index, line.qty - 1)),
            SizedBox(
              width: 28,
              child: Text('${line.qty}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontFeatures: [FontFeature.tabularFigures()])),
            ),
            _Step(
                label: '＋',
                semantics: context.t('sell.more'),
                onTap: () => t.setQty(index, line.qty + 1)),
          ]),
        ),
      ]),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step(
      {required this.label, required this.semantics, required this.onTap});
  final String label;
  final String semantics;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: semantics,
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
            child: Text(label,
                style: const TextStyle(
                    fontSize: 17,
                    color: PharmaColors.green,
                    fontWeight: FontWeight.w700)),
          ),
        ),
      );
}

/// `.search`.
class _SearchBox extends StatelessWidget {
  const _SearchBox(
      {required this.controller,
      required this.focusNode,
      required this.hint,
      required this.onChanged});
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.symmetric(horizontal: 13),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(13),
          boxShadow: cardShadow,
        ),
        child: Row(children: [
          const Icon(Icons.search, size: 19, color: PharmaColors.faint),
          const SizedBox(width: 9),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              onChanged: onChanged,
              style: const TextStyle(fontSize: 15),
              decoration: InputDecoration(
                hintText: hint,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
              ),
            ),
          ),
        ]),
      );
}
