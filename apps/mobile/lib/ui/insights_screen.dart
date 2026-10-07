import 'dart:async';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../core/money.dart';
import '../core/theme.dart';
import '../data/catalog_repository.dart';
import '../data/insights_repository.dart';
import '../l10n/locale_store.dart';
import '../l10n/strings.dart';
import 'kit.dart';
import 'terminal.dart';

/// For tests: replaces the platform share sheet for a reorder or return list.
Future<void> Function(String text)? debugShareInsight;

enum _Tab { reorder, earning, dead, returns }

/// Where the money is (FR-7a, FR-8a, FR-18's return list; ADR-036).
///
/// Four questions an owner asks about stock, each one screenful: what should I buy, what
/// is earning, what is sitting dead, and what can I send back before it expires.
///
/// Worked out on the phone from its own records — instant, and with no network. The price
/// of that is said at the bottom of every tab: these are **this phone's** sales and
/// deliveries.
class InsightsScreen extends StatefulWidget {
  const InsightsScreen({super.key});

  @override
  State<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends State<InsightsScreen> {
  _Tab _tab = _Tab.reorder;
  List<ProductInsight>? _products;
  List<SupplierReturns> _returns = const [];
  bool _started = false;

  Future<void> _load() async {
    final t = TerminalScope.read(context);
    final products = await t.insights.products(t.branchId);
    final returns = await t.insights.returns(t.branchId);
    if (mounted) {
      setState(() {
        _products = products;
        _returns = returns;
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      unawaited(_load());
    }
  }

  Future<void> _share(String text) async {
    final override = debugShareInsight;
    if (override != null) return override(text);
    await SharePlus.instance.share(ShareParams(text: text));
  }

  @override
  Widget build(BuildContext context) {
    final t = TerminalScope.of(context);
    final all = _products;
    final shop = t.branchName ?? t.session.tenantCode;
    return Scaffold(
      body: Column(children: [
        PTopBar(
          title: context.t('insights.title'),
          onBack: () => Navigator.of(context).pop(),
        ),
        Expanded(
          child: PBody(children: [
            PSegmented<_Tab>(
              options: [
                (_Tab.reorder, context.t('insights.tab.reorder')),
                (_Tab.earning, context.t('insights.tab.earning')),
                (_Tab.dead, context.t('insights.tab.dead')),
                (_Tab.returns, context.t('insights.tab.returns')),
              ],
              value: _tab,
              onChanged: (v) => setState(() => _tab = v),
            ),
            if (all == null)
              const Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: CircularProgressIndicator()),
              )
            else
              ...switch (_tab) {
                _Tab.reorder => _reorder(context, all, shop),
                _Tab.earning => _earning(context, all),
                _Tab.dead => _dead(context, all),
                _Tab.returns => _returnsList(context, shop),
              },
            const SizedBox(height: 14),
            // The honest caveat on every figure here (ADR-036).
            PNotice.text(Tone.blue, Icons.phone_android,
                context.t('insights.thisPhone')),
          ]),
        ),
      ]),
    );
  }

  // ---------------------------------------------------------------- what to buy

  List<Widget> _reorder(
      BuildContext context, List<ProductInsight> all, String shop) {
    final list = InsightsRepository.reorder(all);
    if (list.isEmpty) {
      return [
        PNotice.text(Tone.green, Icons.check_circle_outline,
            context.t('insights.reorder.none'),
            margin: EdgeInsets.zero)
      ];
    }
    return [
      PRows(children: [
        for (final s in list)
          PRow(
            avatarIcon: Icons.shopping_cart_outlined,
            avatarTone: s.insight.onHand <= 0 ? Tone.red : Tone.amber,
            title: s.insight.product.name,
            subtitle: context.tf('insights.reorder.why', {
              'left': s.insight.onHand,
              'unit': s.insight.product.unit,
              'days': s.insight.daysOfCover ?? 0,
              'sold': s.insight.unitsSold,
            }),
            value: s.pack == null
                ? '${s.suggestedBaseQty}'
                : '${s.packs} ${s.pack!.name}',
            valueCaption: s.pack == null
                ? s.insight.product.unit
                : context.t('insights.reorder.buy'),
          ),
      ]),
      const SizedBox(height: 12),
      PButton(
        kind: BtnKind.plain,
        icon: Icons.ios_share,
        label: context.t('insights.reorder.share'),
        onPressed: () => _share(reorderText(context.l10n, shop, list)),
      ),
    ];
  }

  // ------------------------------------------------------------ what is earning

  List<Widget> _earning(BuildContext context, List<ProductInsight> all) {
    final best = InsightsRepository.bestSellers(all);
    if (best.isEmpty) {
      return [
        PNotice.text(
            Tone.blue, Icons.info_outline, context.t('insights.earning.none'),
            margin: EdgeInsets.zero)
      ];
    }
    final revenue = best.fold<int>(0, (sum, i) => sum + i.revenueSantim);
    // Profit is only totalled over what has a cost. Adding revenue with no known cost as
    // though it were all profit would be the most flattering possible lie.
    final costed = best.where((i) => i.profitSantim != null).toList();
    final profit = costed.fold<int>(0, (sum, i) => sum + i.profitSantim!);
    final uncosted = best.length - costed.length;
    return [
      PTiles(tiles: [
        PTile(
            label: context.t('insights.earning.revenue'),
            value: formatBirr(revenue),
            unit: 'ETB'),
        PTile(
            label: context.t('insights.earning.profit'),
            value: costed.isEmpty ? '—' : formatBirr(profit),
            unit: costed.isEmpty ? null : 'ETB',
            valueColor: profit < 0 ? PharmaColors.red : PharmaColors.green),
      ]),
      const SizedBox(height: 14),
      PRows(children: [
        for (final i in best.take(25))
          PRow(
            avatar: i.product.name.characters.first.toUpperCase(),
            title: i.product.name,
            subtitle: i.profitSantim == null
                ? context.tf('insights.earning.noCost',
                    {'n': i.unitsSold, 'unit': i.product.unit})
                : context.tf('insights.earning.line', {
                    'n': i.unitsSold,
                    'unit': i.product.unit,
                    'profit': formatMoney(i.profitSantim!),
                  }),
            value: formatMoney(i.revenueSantim),
            valueCaption: context.t('insights.earning.sold'),
          ),
      ]),
      if (uncosted > 0)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: PNotice.text(Tone.amber, Icons.help_outline,
              context.tf('insights.earning.uncosted', {'n': uncosted}),
              margin: EdgeInsets.zero),
        ),
      const SizedBox(height: 10),
      Text(context.t('insights.earning.estimate'),
          style: const TextStyle(fontSize: 11.5, color: PharmaColors.faint)),
    ];
  }

  // ------------------------------------------------------------- what is sitting

  List<Widget> _dead(BuildContext context, List<ProductInsight> all) {
    final dead = InsightsRepository.deadStock(all);
    if (dead.isEmpty) {
      return [
        PNotice.text(Tone.green, Icons.check_circle_outline,
            context.t('insights.dead.none'),
            margin: EdgeInsets.zero)
      ];
    }
    final tied =
        dead.fold<int>(0, (sum, i) => sum + i.onHand * i.product.priceSantim);
    return [
      PTiles(tiles: [
        PTile(
            label: context.t('insights.dead.tied'),
            value: formatBirr(tied),
            unit: 'ETB',
            valueColor: PharmaColors.amber),
        PTile(label: context.t('insights.dead.count'), value: '${dead.length}'),
      ]),
      const SizedBox(height: 14),
      PRows(children: [
        for (final i in dead)
          PRow(
            avatarIcon: Icons.hourglass_bottom,
            avatarTone: Tone.grey,
            title: i.product.name,
            subtitle: i.daysSinceLastSale == null
                ? context.t('insights.dead.never')
                : context
                    .tf('insights.dead.since', {'days': i.daysSinceLastSale!}),
            value: describeQuantity(i.onHand, i.product),
            valueCaption: formatMoney(i.onHand * i.product.priceSantim),
          ),
      ]),
      const SizedBox(height: 10),
      Text(context.t('insights.dead.hint'),
          style: const TextStyle(fontSize: 11.5, color: PharmaColors.faint)),
    ];
  }

  // ------------------------------------------------------------- what to return

  List<Widget> _returnsList(BuildContext context, String shop) {
    if (_returns.isEmpty) {
      return [
        PNotice.text(Tone.green, Icons.check_circle_outline,
            context.t('insights.returns.none'),
            margin: EdgeInsets.zero)
      ];
    }
    return [
      for (final group in _returns) ...[
        PSection(group.supplier ?? context.t('insights.returns.unknown')),
        PRows(children: [
          for (final b in group.batches)
            PRow(
              avatarIcon: Icons.event_busy_outlined,
              avatarTone: b.daysLeft < 0 ? Tone.red : Tone.amber,
              title: b.productName,
              subtitle: [
                '${context.t('stock.lot')} ${b.lotNo}',
                b.daysLeft < 0
                    ? context
                        .tf('insights.returns.expired', {'days': -b.daysLeft})
                    : context.tf('insights.returns.left', {'days': b.daysLeft}),
              ].join(' · '),
              value: '${b.qty}',
              valueCaption:
                  b.valueSantim == null ? b.unit : formatMoney(b.valueSantim!),
            ),
        ]),
        if (group.supplier != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: PButton(
              kind: BtnKind.plain,
              small: true,
              icon: Icons.ios_share,
              label: context
                  .tf('insights.returns.share', {'supplier': group.supplier!}),
              onPressed: () => _share(returnText(context.l10n, shop, group)),
            ),
          ),
      ],
    ];
  }
}

/// The reorder list as a message — what gets sent to whoever does the buying.
String reorderText(Strings s, String shop, List<ReorderSuggestion> list) => [
      '$shop — ${s.get('insights.tab.reorder')}',
      for (final r in list)
        r.pack == null
            ? '• ${r.insight.product.name}: ${r.suggestedBaseQty} ${r.insight.product.unit}'
            : '• ${r.insight.product.name}: ${r.packs} ${r.pack!.name}',
    ].join('\n');

/// One supplier's return list as a message: every batch with its lot and expiry, which is
/// what a wholesaler needs to agree a credit, and the total being asked for.
String returnText(Strings s, String shop, SupplierReturns group) => [
      s.f('insights.returns.text.title',
          {'shop': shop, 'supplier': group.supplier ?? ''}),
      for (final b in group.batches)
        '• ${b.productName} — ${s.get('stock.lot')} ${b.lotNo}, '
            '${s.get('stock.exp')} ${b.expiryDate}: ${b.qty} ${b.unit}'
            '${b.valueSantim == null ? '' : ' (${formatMoney(b.valueSantim!)})'}',
      s.f('insights.returns.text.total',
          {'amount': formatMoney(group.valueSantim)}),
    ].join('\n');
