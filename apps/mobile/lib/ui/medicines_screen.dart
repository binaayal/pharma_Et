import 'dart:async';

import 'package:flutter/material.dart';

import '../core/money.dart';
import '../core/theme.dart';
import '../data/medicine_catalogue.dart';
import '../l10n/locale_store.dart';
import 'kit.dart';
import 'terminal.dart';

/// The ready-made medicines list (FR-12): tick what the shop sells, price them, add them.
///
/// The list was already in the app, but only as suggestions under a name being typed — so
/// an owner who did not start typing never saw it, and one who did still added medicines
/// one sheet at a time. This is the list itself: all of it, searchable, with a tick beside
/// each line. Setting up a shop becomes "go down the list", which is how a pharmacist
/// already thinks about what they stock.
///
/// Two steps, because the list has no prices and must not invent any: choose, then price.
/// Nothing is a product until the second step is confirmed.
class MedicinesScreen extends StatefulWidget {
  const MedicinesScreen({super.key});

  @override
  State<MedicinesScreen> createState() => _MedicinesScreenState();
}

class _MedicinesScreenState extends State<MedicinesScreen> {
  final _search = TextEditingController();
  MedicineCatalogue? _list;

  /// What has been ticked, in the order it was ticked — the order the price step shows.
  final Map<String, MedicineEntry> _chosen = {};

  @override
  void initState() {
    super.initState();
    final cached = MedicineCatalogue.cached;
    if (cached != null) {
      _list = cached;
    } else {
      unawaited(MedicineCatalogue.load().then((m) {
        if (mounted) setState(() => _list = m);
      }));
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _next() async {
    final added = await Navigator.of(context).push(MaterialPageRoute<int>(
        builder: (_) => MedicinePricesScreen(chosen: _chosen.values.toList())));
    if (!mounted || added == null) return;
    // Everything was added: back to the stock list, which reloads.
    Navigator.of(context).pop(true);
    toast(context, context.tf('medicines.added', {'n': added}));
  }

  @override
  Widget build(BuildContext context) {
    final t = TerminalScope.of(context);
    final list = _list;
    // What this pharmacy already sells is shown, ticked and greyed, not offered again.
    final stocked = {for (final p in t.products) p.name.toLowerCase()};
    final shown = list?.browse(_search.text) ?? const <MedicineEntry>[];

    return Scaffold(
      body: Column(children: [
        PTopBar(
          title: context.t('medicines.title'),
          onBack: () => Navigator.of(context).pop(),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
          child: PField(
            label: context.t('medicines.search'),
            hint: context.t('medicines.searchHint'),
            controller: _search,
            onChanged: (_) => setState(() {}),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              list == null
                  ? context.t('medicines.loading')
                  : context.tf('medicines.count', {'n': shown.length}),
              style: const TextStyle(fontSize: 12.5, color: PharmaColors.muted),
            ),
          ),
        ),
        Expanded(
          child: list != null && list.length == 0
              ? Padding(
                  padding: const EdgeInsets.all(18),
                  child: PNotice.text(Tone.amber, Icons.info_outline,
                      context.t('medicines.unavailable')),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                  itemCount: shown.length,
                  itemBuilder: (context, i) {
                    final m = shown[i];
                    final have = stocked.contains(m.name.toLowerCase());
                    final ticked = _chosen.containsKey(m.name);
                    return _MedicineLine(
                      entry: m,
                      ticked: ticked || have,
                      have: have,
                      onTap: have
                          ? null
                          : () => setState(() {
                                if (ticked) {
                                  _chosen.remove(m.name);
                                } else {
                                  _chosen[m.name] = m;
                                }
                              }),
                    );
                  },
                ),
        ),
        PFooter(
          child: PButton(
            label: _chosen.isEmpty
                ? context.t('medicines.tickSome')
                : context.tf('medicines.next', {'n': _chosen.length}),
            onPressed: _chosen.isEmpty ? null : _next,
          ),
        ),
      ]),
    );
  }
}

class _MedicineLine extends StatelessWidget {
  const _MedicineLine({
    required this.entry,
    required this.ticked,
    required this.have,
    required this.onTap,
  });

  final MedicineEntry entry;
  final bool ticked;

  /// Already one of this pharmacy's products.
  final bool have;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
          child: Row(children: [
            Icon(
              ticked ? Icons.check_box : Icons.check_box_outline_blank,
              color: have
                  ? PharmaColors.faint
                  : ticked
                      ? PharmaColors.green
                      : PharmaColors.muted,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.name,
                      style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                          color: have ? PharmaColors.muted : null)),
                  const SizedBox(height: 2),
                  Text(
                      have
                          ? context.t('medicines.have')
                          : '${context.t('pos.perUnit')} ${entry.unit}',
                      style: const TextStyle(
                          fontSize: 12.5, color: PharmaColors.muted)),
                ],
              ),
            ),
          ]),
        ),
      );
}

/// Step two: a price for each medicine ticked, then add them all.
///
/// The price is the owner's. The list has none, and a medicine cannot be sold without one,
/// so every line needs a figure before anything is added — or is taken off the batch.
class MedicinePricesScreen extends StatefulWidget {
  const MedicinePricesScreen({super.key, required this.chosen});
  final List<MedicineEntry> chosen;

  @override
  State<MedicinePricesScreen> createState() => _MedicinePricesScreenState();
}

class _MedicinePricesScreenState extends State<MedicinePricesScreen> {
  late final List<MedicineEntry> _left = [...widget.chosen];
  late final Map<String, TextEditingController> _prices = {
    for (final m in widget.chosen) m.name: TextEditingController(),
  };

  /// How many have been added so far, across attempts.
  int _added = 0;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in _prices.values) {
      c.dispose();
    }
    super.dispose();
  }

  int? _priceOf(MedicineEntry m) {
    final p = parseBirr(_prices[m.name]!.text);
    return p != null && p > 0 ? p : null;
  }

  int get _unpriced => _left.where((m) => _priceOf(m) == null).length;

  /// Adds them one at a time, and takes each off the list as the server accepts it. If the
  /// network drops halfway, what is left on the screen is exactly what was not added —
  /// pressing the button again cannot add anything twice.
  Future<void> _addAll() async {
    final t = TerminalScope.read(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      while (_left.isNotEmpty) {
        final m = _left.first;
        await t.authed((token) => t.api.createProduct(token,
            name: m.name, unit: m.unit, priceSantim: _priceOf(m)!));
        if (!mounted) return;
        setState(() {
          _left.removeAt(0);
          _added++;
        });
      }
      // Pull them down now, so the counter can sell them before the next tick.
      unawaited(t.sync());
      if (mounted) Navigator.of(context).pop(_added);
    } catch (e) {
      // Some were added before it failed: bring those down too.
      if (_added > 0) unawaited(t.sync());
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final unpriced = _unpriced;
    return PopScope(
      // Leaving after some were added still tells the list behind to finish up.
      canPop: _added == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_added);
      },
      child: Scaffold(
        body: Column(children: [
          PTopBar(
            title: context.t('medicines.pricesTitle'),
            onBack: () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
              children: [
                PNotice.text(Tone.blue, Icons.sell_outlined,
                    context.t('medicines.pricesHint'),
                    margin: const EdgeInsets.only(bottom: 14)),
                if (_added > 0)
                  PNotice.text(Tone.green, Icons.check_circle_outline,
                      context.tf('medicines.addedSoFar', {'n': _added}),
                      margin: const EdgeInsets.only(bottom: 14)),
                if (_error != null)
                  PNotice.text(Tone.red, Icons.error_outline,
                      '${context.t('medicines.failed')} $_error',
                      margin: const EdgeInsets.only(bottom: 14)),
                for (final m in _left)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 6,
                            child: Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(m.name,
                                      style: const TextStyle(
                                          fontSize: 14.5,
                                          fontWeight: FontWeight.w600)),
                                  const SizedBox(height: 2),
                                  Text('${context.t('pos.perUnit')} ${m.unit}',
                                      style: const TextStyle(
                                          fontSize: 12.5,
                                          color: PharmaColors.muted)),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 4,
                            child: PField(
                              label: context.t('catalog.price'),
                              controller: _prices[m.name],
                              enabled: !_busy,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              textInputAction: TextInputAction.next,
                              onChanged: (_) => setState(() {}),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(top: 22),
                            child: IconButton(
                              tooltip: context.t('receive.remove'),
                              icon: const Icon(Icons.close,
                                  size: 18, color: PharmaColors.faint),
                              onPressed: _busy
                                  ? null
                                  : () => setState(() => _left.remove(m)),
                            ),
                          ),
                        ]),
                  ),
              ],
            ),
          ),
          PFooter(
            child: PButton(
              label: _busy
                  ? context.tf('medicines.adding',
                      {'n': _added + 1, 'of': _added + _left.length})
                  : _left.isEmpty
                      ? context.t('medicines.tickSome')
                      : unpriced > 0
                          ? context.tf('medicines.needPrice', {'n': unpriced})
                          : context.tf('medicines.addAll', {'n': _left.length}),
              onPressed:
                  _busy || _left.isEmpty || unpriced > 0 ? null : _addAll,
            ),
          ),
        ]),
      ),
    );
  }
}

/// How a product gets added: from the ready-made list, or typed.
///
/// The list is offered first. Before this, the only way in was a blank form, and the list
/// showed itself only to someone who had already started typing a name.
Future<bool> showAddProductChooser(
  BuildContext context, {
  required Future<bool> Function(BuildContext context) typeOne,
}) async {
  final t = TerminalScope.read(context);
  final choice = await showModalBottomSheet<String>(
    context: context,
    builder: (sheet) => TerminalScope(
      terminal: t,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(sheet.t('catalog.addTitle'),
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 14),
            PRows(children: [
              PRow(
                avatarIcon: Icons.playlist_add_check,
                title: sheet.t('medicines.pick'),
                subtitle: sheet.t('medicines.pickSub'),
                chevron: true,
                onTap: () => Navigator.pop(sheet, 'list'),
              ),
              PRow(
                avatarIcon: Icons.edit_outlined,
                avatarTone: Tone.blue,
                title: sheet.t('medicines.typeOne'),
                subtitle: sheet.t('medicines.typeOneSub'),
                chevron: true,
                onTap: () => Navigator.pop(sheet, 'type'),
              ),
            ]),
          ],
        ),
      ),
    ),
  );
  if (!context.mounted) return false;
  switch (choice) {
    case 'list':
      return await Navigator.of(context).push(MaterialPageRoute<bool>(
              builder: (_) => const MedicinesScreen())) ??
          false;
    case 'type':
      return typeOne(context);
    default:
      return false;
  }
}
