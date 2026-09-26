import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../api/tenant_api.dart';
import '../core/theme.dart';
import '../l10n/locale_store.dart';
import 'kit.dart';
import 'terminal.dart';

/// Controlled ledger (prototype screen 17; FR-6 AC-6.2, BR-6.3).
///
/// Append-only: entries cannot be edited or deleted, and corrections are new compensating
/// events. Current stock is shown as what it is — a projection over those events. Needs a
/// network: the ledger is the server's record, not the device's.
class LedgerScreen extends StatefulWidget {
  const LedgerScreen({super.key});

  @override
  State<LedgerScreen> createState() => _LedgerScreenState();
}

class _LedgerScreenState extends State<LedgerScreen> {
  List<LedgerEntry>? _entries;
  Map<String, int> _stock = const {};
  String? _productId;
  bool _offline = false;
  bool _exporting = false;
  bool _loaded = false;

  (DateTime, DateTime) get _window {
    final now = DateTime.now();
    return (
      now.subtract(const Duration(days: 90)),
      now.add(const Duration(days: 1))
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final t = TerminalScope.read(context);
    final (from, to) = _window;
    try {
      final entries = await t.authed((token) =>
          t.api.ledger(token, from: from, to: to, productId: _productId));
      final stock = await t.authed(t.api.controlledStock);
      if (!mounted) return;
      setState(() {
        _entries = entries.reversed.toList();
        _stock = stock;
        _offline = false;
      });
    } catch (_) {
      if (mounted) setState(() => _offline = true);
    }
  }

  Future<void> _export() async {
    final t = TerminalScope.read(context);
    final subject = context.t('ledger.exportSubject');
    final (from, to) = _window;
    setState(() => _exporting = true);
    try {
      final csv =
          await t.authed((token) => t.api.ledgerCsv(token, from: from, to: to));
      final dir = await getTemporaryDirectory();
      final file = File(
          '${dir.path}/pharmaet-controlled-ledger-${DateTime.now().toIso8601String().substring(0, 10)}.csv');
      await file.writeAsString(csv);
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path, mimeType: 'text/csv')],
        subject: subject,
      ));
    } catch (e) {
      if (mounted) toast(context, '$e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = TerminalScope.of(context);
    final controlled = t.products.where((p) => p.isControlled).toList();
    final selected = controlled.where((p) => p.id == _productId).firstOrNull;
    final onHand = _productId == null
        ? _stock.values.fold<int>(0, (a, b) => a + b)
        : _stock[_productId] ?? 0;
    final entries = _entries;

    return Scaffold(
      body: Column(children: [
        PTopBar(
          title: context.t('reports.ledger'),
          subtitle:
              '${selected?.name ?? context.t('ledger.allControlled')} · ${context.t('ledger.immutable')}',
          onBack: () => Navigator.of(context).pop(),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: PBody(children: [
              PNotice.text(Tone.blue, Icons.lock_outline,
                  context.t('ledger.appendOnly')),
              if (controlled.length > 1)
                PField(
                  label: context.t('receive.product'),
                  child: DropdownButtonFormField<String?>(
                    initialValue: _productId,
                    items: [
                      DropdownMenuItem(
                          value: null,
                          child: Text(context.t('ledger.allControlled'))),
                      for (final p in controlled)
                        DropdownMenuItem(value: p.id, child: Text(p.name)),
                    ],
                    onChanged: (id) {
                      setState(() {
                        _productId = id;
                        _entries = null;
                      });
                      unawaited(_load());
                    },
                  ),
                ),
              if (_offline)
                PNotice.text(Tone.amber, Icons.cloud_off_outlined,
                    context.t('ledger.offline'))
              else ...[
                PTile(label: context.t('ledger.projected'), value: '$onHand'),
                PSection(context.t('ledger.events')),
                if (entries == null)
                  const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()))
                else if (entries.isEmpty)
                  PNotice.text(Tone.green, Icons.inventory_2_outlined,
                      context.t('ledger.none'),
                      margin: EdgeInsets.zero)
                else
                  PRows(children: [
                    for (final e in entries)
                      _row(context, e, showProduct: _productId == null),
                  ]),
              ],
            ]),
          ),
        ),
        PFooter(
          child: PButton(
            kind: BtnKind.plain,
            icon: Icons.ios_share,
            label: context.t(_exporting ? 'ledger.exporting' : 'ledger.export'),
            onPressed: _exporting || _offline ? null : _export,
          ),
        ),
      ]),
    );
  }

  Widget _row(BuildContext context, LedgerEntry e,
      {required bool showProduct}) {
    final kind = e.eventType.replaceFirst('controlled.', '');
    final (avatar, tone) = switch (kind) {
      'dispensed' => ('↓', Tone.red),
      'received' => ('↑', Tone.green),
      _ => ('⟲', Tone.blue),
    };
    final detail = switch (kind) {
      'dispensed' => '${e.payload['prescriptionNumber'] ?? ''}',
      'received' => '${e.payload['supplierName'] ?? ''}',
      _ => '${e.payload['note'] ?? ''}',
    };
    return PRow(
      avatar: avatar,
      avatarTone: tone,
      title:
          '${context.t('ledger.$kind')} ×${e.delta.abs()}${showProduct ? ' · ${e.productName}' : ''}',
      subtitle: [
        if (detail.isNotEmpty) detail,
        if (e.actorName != null) e.actorName!,
        '${context.l10n.date(e.occurredAt)} ${context.l10n.time(e.occurredAt)}',
      ].join(' · '),
      value: '${e.delta > 0 ? '+' : ''}${e.delta}',
      valueColor: e.delta > 0 ? PharmaColors.green : null,
    );
  }
}
