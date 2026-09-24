import 'dart:async';

import 'package:flutter/material.dart';

import '../core/money.dart';
import '../core/permissions.dart';
import '../core/theme.dart';
import '../data/catalog_repository.dart';
import '../data/inventory_repository.dart';
import '../l10n/locale_store.dart';
import 'kit.dart';
import 'receive_screen.dart';
import 'reconcile_screen.dart';
import 'sell_screen.dart';
import 'terminal.dart';

enum StockFilter { all, low, expiring, controlled }

/// Inventory (prototype screen 12; FR-3).
///
/// Amber is near-expiry, red is oversold, blue is controlled and ledger-tracked. Reads the
/// device's own copy, so it works with no network.
class StockScreen extends StatefulWidget {
  const StockScreen({super.key, this.onBack});

  /// Set when opened from Reports rather than as the Stock tab.
  final VoidCallback? onBack;

  /// Below this, a line counts as "low".
  static const lowAt = 20;

  /// Within this many days, a batch counts as "expiring" (Home says the same).
  static const expiringDays = 60;

  @override
  State<StockScreen> createState() => _StockScreenState();
}

class _StockScreenState extends State<StockScreen> {
  StockFilter _filter = StockFilter.all;
  List<ProductStock>? _rows;
  String _query = '';
  bool _searching = false;
  int _seen = -1;

  Future<void> _load() async {
    final t = TerminalScope.read(context);
    final rows = await t.catalog.stockByProduct(t.branchId);
    if (mounted) setState(() => _rows = rows);
  }

  bool _expiring(ProductStock s) {
    if (s.nearestExpiry == null) return false;
    final limit =
        DateTime.now().add(const Duration(days: StockScreen.expiringDays));
    return DateTime.parse(s.nearestExpiry!).isBefore(limit);
  }

  @override
  Widget build(BuildContext context) {
    final t = TerminalScope.of(context);
    // Reload when the catalog changes underneath (a pull, a sale, a receipt).
    if (_seen != t.revision) {
      _seen = t.revision;
      unawaited(_load());
    }
    final all = _rows ?? const <ProductStock>[];
    final q = _query.toLowerCase();
    final rows = all.where((s) {
      if (q.isNotEmpty && !s.product.name.toLowerCase().contains(q)) {
        return false;
      }
      return switch (_filter) {
        StockFilter.all => true,
        StockFilter.low => s.onHand < StockScreen.lowAt,
        StockFilter.expiring => _expiring(s),
        StockFilter.controlled => s.product.isControlled,
      };
    }).toList();

    return Column(children: [
      PTopBar(
        title: context.t('stock.title'),
        onBack: widget.onBack,
        trailing: [
          if (t.can(Capability.goodsReceive))
            PIconButton(
              icon: Icons.south,
              tooltip: context.t('stock.receive'),
              onTap: () async {
                await Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => const ReceiveScreen()));
                await _load();
              },
            ),
          PIconButton(
            icon: _searching ? Icons.close : Icons.search,
            tooltip: context.t('stock.search'),
            onTap: () => setState(() {
              _searching = !_searching;
              _query = '';
            }),
          ),
        ],
      ),
      Expanded(
        child: RefreshIndicator(
          onRefresh: () async {
            await t.sync();
            await _load();
          },
          child: PBody(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 20),
              children: [
                if (_searching)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextField(
                      autofocus: true,
                      onChanged: (v) => setState(() => _query = v),
                      decoration: InputDecoration(
                          hintText: context.t('stock.searchHint'),
                          prefixIcon: const Icon(Icons.search)),
                    ),
                  ),
                PSegmented<StockFilter>(
                  options: [
                    (StockFilter.all, context.t('stock.all')),
                    (StockFilter.low, context.t('stock.low')),
                    (StockFilter.expiring, context.t('stock.expiring')),
                    (StockFilter.controlled, context.t('stock.controlled')),
                  ],
                  value: _filter,
                  onChanged: (f) => setState(() => _filter = f),
                ),
                if (_rows == null)
                  const Padding(
                      padding: EdgeInsets.all(30),
                      child: Center(child: CircularProgressIndicator()))
                else if (rows.isEmpty)
                  PNotice.text(
                      Tone.green,
                      Icons.inventory_2_outlined,
                      context
                          .t(all.isEmpty ? 'count.empty' : 'stock.nothingHere'))
                else
                  PRows(children: [
                    for (final s in rows) _row(context, s),
                  ]),
              ]),
        ),
      ),
    ]);
  }

  Widget _row(BuildContext context, ProductStock s) {
    final tone = s.oversold
        ? Tone.red
        : s.product.isControlled
            ? Tone.blue
            : _expiring(s)
                ? Tone.amber
                : Tone.green;
    const muted = TextStyle(fontSize: 12.5, color: PharmaColors.muted);
    final Widget sub;
    if (s.oversold) {
      sub = Row(children: [
        PBadge('${s.onHand} ${context.t('stock.oversold')}', tone: Tone.red),
        const SizedBox(width: 6),
        Text(context.t('stock.reconcile'), style: muted),
      ]);
    } else if (s.product.isControlled) {
      sub = Row(children: [
        PBadge(context.t('stock.controlled'), tone: Tone.blue),
        const SizedBox(width: 6),
        Text(context.t('stock.ledgerTracked'), style: muted),
      ]);
    } else if (s.nearestExpiry != null && _expiring(s)) {
      sub = Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text('${context.tf('stock.batches', {'n': s.batchCount})} · ',
            style: muted),
        PBadge(
            '${context.t('stock.exp')} ${context.l10n.calendarDate(s.nearestExpiry!)}',
            tone: Tone.amber),
      ]);
    } else {
      sub = Text(
          s.batchCount == 0
              ? context.t('stock.noBatches')
              : '${context.tf('stock.batches', {'n': s.batchCount})}'
                  '${s.nearestExpiry == null ? '' : ' · ${context.t('stock.nearest')} ${context.l10n.calendarDate(s.nearestExpiry!)}'}',
          style: muted);
    }
    return PRow(
      avatar: s.product.name.characters.first.toUpperCase(),
      avatarTone: tone,
      title: s.product.name,
      subtitleWidget: sub,
      value: '${s.onHand}',
      valueColor: s.onHand < 0 ? PharmaColors.red : null,
      valueCaption: s.onHand < 0
          ? context.t('stock.negative')
          : context.t('stock.inStock'),
      onTap: () async {
        await Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => ProductScreen(stock: s)));
        await _load();
      },
    );
  }
}

/// Product / batch detail (prototype screen 13): FEFO made legible to staff.
class ProductScreen extends StatefulWidget {
  const ProductScreen({super.key, required this.stock});
  final ProductStock stock;

  @override
  State<ProductScreen> createState() => _ProductScreenState();
}

class _ProductScreenState extends State<ProductScreen> {
  List<LocalBatch>? _batches;
  List<StockMovement> _moves = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_batches == null) unawaited(_load());
  }

  Future<void> _load() async {
    final t = TerminalScope.read(context);
    final b = await t.catalog.batchesFor(widget.stock.product.id, t.branchId);
    final m = await t.catalog.movements(widget.stock.product.id, t.branchId);
    if (mounted) {
      setState(() {
        _batches = b;
        _moves = m;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = TerminalScope.of(context);
    final p = widget.stock.product;
    final batches = _batches ?? const <LocalBatch>[];
    final today = DateTime.now();
    final nextOut = batches.indexWhere((b) =>
        b.qtyOnHand > 0 &&
        !DateTime.parse(b.expiryDate)
            .isBefore(DateTime(today.year, today.month, today.day)));
    final onHand = batches.fold<int>(0, (sum, b) => sum + b.qtyOnHand);

    return Scaffold(
      body: Column(children: [
        PTopBar(title: p.name, onBack: () => Navigator.of(context).pop()),
        Expanded(
          child: PBody(children: [
            PTiles(tiles: [
              PTile(
                  label: context.t('product.inStock'),
                  value: '$onHand',
                  valueColor: onHand < 0 ? PharmaColors.red : null),
              PTile(
                  label: context.t('product.price'),
                  value: formatBirr(p.priceSantim),
                  unit: 'ETB'),
            ]),
            if (p.isControlled)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: PNotice.text(Tone.blue, Icons.lock_outline,
                    context.t('pos.controlledLater'),
                    margin: EdgeInsets.zero),
              ),
            PSection(context.t('product.batchesFefo')),
            if (batches.isEmpty)
              PNotice.text(
                  Tone.amber, Icons.info_outline, context.t('stock.noBatches'),
                  margin: EdgeInsets.zero)
            else
              PRows(children: [
                for (var i = 0; i < batches.length; i++)
                  _batchRow(context, t, batches[i], i, i == nextOut),
              ]),
            if (_moves.isNotEmpty) ...[
              PSection(context.t('product.movement')),
              PRows(children: [
                for (final m in _moves)
                  PRow(
                    title: '${context.t('move.${m.kind}')} ×${m.delta.abs()}',
                    subtitle: [
                      if (m.kind == 'sale')
                        '${context.t('receipt.sale')} #${m.reference.substring(m.reference.length - 4).toUpperCase()}',
                      if (m.kind == 'receipt' && m.detail != null) m.detail!,
                      if (m.kind == 'count' && m.detail != null)
                        context.t(
                            'reason.${AdjustmentReason.values.firstWhere((r) => r.wire == m.detail, orElse: () => AdjustmentReason.other).name}'),
                      '${context.l10n.date(m.at)} ${context.l10n.time(m.at)}',
                    ].join(' · '),
                    value: '${m.delta > 0 ? '+' : ''}${m.delta}',
                    valueColor: m.delta > 0 ? PharmaColors.green : null,
                  ),
              ]),
            ],
          ]),
        ),
        PFooter(
          child: PButtonRow(
            left: PButton(
              kind: BtnKind.plain,
              label: context.t('product.adjust'),
              onPressed: batches.isEmpty || !t.can(Capability.goodsReceive)
                  ? null
                  : () =>
                      _adjust(context, t, batches[nextOut < 0 ? 0 : nextOut]),
            ),
            right: PButton(
              label: context.t('tab.sell'),
              onPressed: p.isControlled || !t.can(Capability.saleCreate)
                  ? null
                  : () => Navigator.of(context).pushReplacement(
                      MaterialPageRoute<void>(
                          builder: (_) => const SellScreen())),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _batchRow(
      BuildContext context, Terminal t, LocalBatch b, int i, bool next) {
    final expired = DateTime.parse(b.expiryDate).isBefore(DateTime.now());
    return PRow(
      avatar: '${i + 1}',
      avatarTone: b.qtyOnHand < 0
          ? Tone.red
          : expired
              ? Tone.grey
              : Tone.green,
      title: b.lotNo,
      subtitle:
          '${context.t('stock.exp')} ${context.l10n.calendarDate(b.expiryDate)}${expired ? ' · ${context.t('product.expired')}' : ''}',
      value: '${b.qtyOnHand}',
      valueColor: b.qtyOnHand < 0 ? PharmaColors.red : null,
      trailing:
          next ? PBadge(context.t('product.nextOut'), tone: Tone.green) : null,
      onTap:
          t.can(Capability.goodsReceive) ? () => _adjust(context, t, b) : null,
    );
  }

  Future<void> _adjust(
      BuildContext context, Terminal t, LocalBatch batch) async {
    final done = await showCountSheet(context,
        batch: batch, productName: widget.stock.product.name);
    if (done == true) {
      await _load();
      await t.refresh();
      unawaited(t.sync());
    }
  }
}
