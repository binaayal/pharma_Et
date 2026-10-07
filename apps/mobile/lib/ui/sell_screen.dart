import 'package:flutter/material.dart';

import '../core/gs1.dart';
import '../core/money.dart';
import '../core/permissions.dart';
import '../contracts/contracts.dart';
import '../core/theme.dart';
import '../data/catalog_repository.dart';
import '../l10n/locale_store.dart';
import 'dispense_screen.dart';
import 'kit.dart';
import 'payment_screen.dart';
import 'scan_screen.dart';
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

  /// Rings up by scanning (FR-13). The camera stays open for the whole basket: each box
  /// is matched against the catalogue on this phone and added exactly as a tap would add
  /// it — same FEFO batch, same expired-stock warning, same refusal of a controlled item.
  Future<void> _scan() async {
    final t = TerminalScope.read(context);
    final unknown = context.t('scan.unknown');
    final added = context.l10n;
    await BarcodeScanner.many(
      context,
      title: context.t('sell.scan'),
      onCode: (raw) async {
        final scan = parseScan(raw);
        final product = scan == null ? null : t.productForBarcode(scan.barcode);
        // Not found is said, and nothing is added. Guessing a near match would put the
        // wrong medicine in the bag at the wrong price.
        if (product == null) return ScanFeedback(unknown, ok: false);
        if (!mounted) return ScanFeedback(unknown, ok: false);
        final before = t.cartItems;
        await _add(product);
        if (t.cartItems == before) {
          // A controlled item, or a denied capability: _add already said why.
          return ScanFeedback(product.name, ok: false);
        }
        return ScanFeedback(added.f('scan.added', {'name': product.name}));
      },
    );
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
        // Compared in base units: one box of thirty oversells a shelf holding ten.
        if (line.baseQty > (t.cartOnHand[line.product.id] ?? 0)) line,
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
                    onScan: t.can(Capability.saleCreate) ? _scan : null,
                    scanTooltip: context.t('sell.scan'),
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
                              : Text(
                                  // The packs it also sells in, so the cashier knows a
                                  // box is one tap away before adding the line.
                                  [
                                    '${context.t('pos.perUnit')} ${p.unit}',
                                    for (final pack in p.packs) pack.name,
                                  ].join(' · '),
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
            if (line.product.packs.isNotEmpty) ...[
              const SizedBox(height: 8),
              // Break-bulk (FR-11): the same medicine leaves as a tablet, a strip or a
              // box. One line, and the unit is a tap — never arithmetic at the counter.
              Wrap(spacing: 6, runSpacing: 6, children: [
                _UnitChip(
                  label: line.product.unit,
                  price: line.product.priceSantim,
                  selected: line.pack == null,
                  onTap: () => t.setPack(index, null),
                ),
                for (final pack in line.product.packs)
                  _UnitChip(
                    label: pack.name,
                    price: pack.priceSantim,
                    selected: _samePack(line.pack, pack),
                    onTap: () => t.setPack(index, pack),
                  ),
              ]),
            ],
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

bool _samePack(ProductPack? a, ProductPack b) =>
    a != null && a.size == b.size && a.name == b.name;

/// One of the units a cart line can be sold in, with what one of them costs.
class _UnitChip extends StatelessWidget {
  const _UnitChip({
    required this.label,
    required this.price,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final int price;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        label: '$label ${formatMoney(price)}',
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
            decoration: BoxDecoration(
              color: selected ? PharmaColors.green : Colors.white,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                  color:
                      selected ? PharmaColors.green : const Color(0xFFDDE5E1)),
            ),
            child: Text('$label · ${formatMoney(price)}',
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: selected ? Colors.white : PharmaColors.ink)),
          ),
        ),
      );
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
      required this.onChanged,
      required this.scanTooltip,
      this.onScan});
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final ValueChanged<String> onChanged;
  final String scanTooltip;

  /// Opens the camera scanner (FR-13). Null hides the button.
  final VoidCallback? onScan;

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
          if (onScan != null)
            IconButton(
              tooltip: scanTooltip,
              icon: const Icon(Icons.qr_code_scanner,
                  size: 22, color: PharmaColors.green),
              onPressed: onScan,
            ),
        ]),
      );
}
