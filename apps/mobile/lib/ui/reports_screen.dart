import 'dart:async';

import 'package:flutter/material.dart';

import '../api/tenant_api.dart';
import '../core/money.dart';
import '../core/theme.dart';
import '../l10n/locale_store.dart';
import 'kit.dart';
import 'stock_screen.dart';
import 'sync_chip.dart';
import 'terminal.dart';

enum Period { today, week, month }

/// Reports (prototype screen 16; FR-8, BR-8.1).
///
/// Reads synced data and always states its currency, so an owner is never misled by stale
/// figures. Needs a network; without one it says so rather than showing zeros.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  Period _period = Period.today;
  SalesSummary? _summary;
  List<ShiftReport> _shifts = const [];
  bool _offline = false;
  bool _loaded = false;

  (DateTime, DateTime) _window() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final end = today.add(const Duration(days: 1));
    return switch (_period) {
      Period.today => (today, end),
      Period.week => (today.subtract(const Duration(days: 6)), end),
      Period.month => (today.subtract(const Duration(days: 29)), end),
    };
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
    final (from, to) = _window();
    try {
      final summary = await t
          .authed((token) => t.api.salesSummary(token, from: from, to: to));
      final shifts = await t.authed(t.api.cashUps);
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _shifts = shifts
            .where((s) => !s.openedAt.isBefore(from) && s.openedAt.isBefore(to))
            .toList();
        _offline = false;
      });
    } catch (_) {
      if (mounted) setState(() => _offline = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = TerminalScope.of(context);
    final s = _summary;
    final variance = _shifts
        .where((x) => x.varianceSantim != null)
        .fold<int>(0, (sum, x) => sum + x.varianceSantim!);
    final avg = s == null || s.total.saleCount == 0
        ? 0
        : s.total.grossSantim ~/ s.total.saleCount;

    return Column(children: [
      PTopBar(
        title: context.t('reports.title'),
        trailing: [SyncChip(status: t.status, onTap: t.sync)],
      ),
      Expanded(
        child: RefreshIndicator(
          onRefresh: _load,
          child: PBody(children: [
            PSegmented<Period>(
              options: [
                (Period.today, context.t('reports.today')),
                (Period.week, context.t('reports.week')),
                (Period.month, context.t('reports.month')),
              ],
              value: _period,
              onChanged: (p) {
                setState(() => _period = p);
                unawaited(_load());
              },
            ),
            if (_offline && s == null)
              PNotice.text(Tone.amber, Icons.cloud_off_outlined,
                  context.t('reports.offline'))
            else
              PTiles(
                hero: PTile(
                  hero: true,
                  label: t.isOwner
                      ? context.t('reports.salesAll')
                      : '${context.t('reports.sales')} · ${t.branchName ?? ''}',
                  value: s == null ? '—' : formatEtbShort(s.total.grossSantim),
                  delta: s == null
                      ? null
                      : '${s.total.saleCount} ${context.t('home.sales')} · ${context.t('reports.avg')} ${formatBirr(avg)}',
                ),
                tiles: [
                  PTile(
                    label: context.t('reports.variance'),
                    value: s == null ? '—' : formatBirr(variance),
                    valueColor: variance < 0 ? PharmaColors.red : null,
                  ),
                  PTile(
                    label: context.t('reports.itemsSold'),
                    value: s == null ? '—' : '${s.total.itemsSold}',
                  ),
                ],
              ),
            PSection(context.t('reports.reports')),
            PRows(children: [
              PRow(
                avatar: '▤',
                title: context.t('reports.salesSummary'),
                subtitle: context.t('reports.salesSummarySub'),
                chevron: true,
                onTap: s == null
                    ? null
                    : () => _push(context, _SalesSummaryScreen(summary: s)),
              ),
              PRow(
                avatar: '◔',
                avatarTone: Tone.amber,
                title: context.t('reports.stockExpiry'),
                subtitle: context.t('reports.stockExpirySub'),
                chevron: true,
                onTap: () => _push(
                    context,
                    Scaffold(
                        body: StockScreen(
                            onBack: () => Navigator.of(context).pop()))),
              ),
              PRow(
                avatar: '℞',
                avatarTone: Tone.blue,
                title: context.t('reports.ledger'),
                subtitle: context.t('reports.ledgerSub'),
                trailing:
                    PBadge(context.t('reports.ledgerGate'), tone: Tone.grey),
              ),
              PRow(
                avatar: '△',
                avatarTone: Tone.red,
                title: context.t('reports.cashup'),
                subtitle: context.t('reports.cashupSub'),
                chevron: true,
                onTap: () => _push(context, _CashUpsScreen(shifts: _shifts)),
              ),
            ]),
            const SizedBox(height: 14),
            PNotice.text(
              Tone.amber,
              Icons.schedule,
              s?.lastSyncedAt == null
                  ? context.t('reports.currencyNone')
                  : context.tf('reports.currency', {
                      'when':
                          '${context.l10n.date(s!.lastSyncedAt!)} ${context.l10n.time(s.lastSyncedAt!)}'
                    }),
            ),
          ]),
        ),
      ),
    ]);
  }

  void _push(BuildContext context, Widget screen) {
    final t = TerminalScope.read(context);
    Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => TerminalScope(terminal: t, child: screen)));
  }
}

/// Sales by branch for the chosen period (AC-8.2).
class _SalesSummaryScreen extends StatelessWidget {
  const _SalesSummaryScreen({required this.summary});
  final SalesSummary summary;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Column(children: [
          PTopBar(
              title: context.t('reports.salesSummary'),
              onBack: () => Navigator.of(context).pop()),
          Expanded(
            child: PBody(children: [
              PTiles(
                hero: PTile(
                  hero: true,
                  label: context.t('reports.total'),
                  value: formatEtbShort(summary.total.grossSantim),
                  delta:
                      '${summary.total.saleCount} ${context.t('home.sales')} · ${summary.total.itemsSold} ${context.t('reports.items')}',
                ),
                tiles: [
                  PTile(
                      label: context.t('pay.cash'),
                      value: formatBirr(summary.total.cashSantim),
                      unit: 'ETB'),
                  PTile(
                      label: context.t('reports.otherTender'),
                      value: formatBirr(
                          summary.total.grossSantim - summary.total.cashSantim),
                      unit: 'ETB'),
                ],
              ),
              PSection(context.t('reports.byBranch')),
              if (summary.branches.isEmpty)
                PNotice.text(
                    Tone.blue, Icons.info_outline, context.t('reports.noSales'),
                    margin: EdgeInsets.zero)
              else
                PRows(children: [
                  for (final b in summary.branches)
                    PRow(
                      avatar: b.branchName.characters.first,
                      title: b.branchName,
                      subtitle:
                          '${b.saleCount} ${context.t('home.sales')} · ${b.itemsSold} ${context.t('reports.items')}',
                      value: formatBirr(b.grossSantim),
                      valueCaption: 'ETB',
                    ),
                ]),
            ]),
          ),
        ]),
      );
}

/// Cash-up & variance, per shift and per staff member (FR-8, BR-8.2).
class _CashUpsScreen extends StatelessWidget {
  const _CashUpsScreen({required this.shifts});
  final List<ShiftReport> shifts;

  @override
  Widget build(BuildContext context) {
    final short = shifts.where((s) => (s.varianceSantim ?? 0) < 0).toList();
    final uncounted = shifts.where((s) => s.countedSantim == null).length;
    return Scaffold(
      body: Column(children: [
        PTopBar(
            title: context.t('reports.cashup'),
            onBack: () => Navigator.of(context).pop()),
        Expanded(
          child: PBody(children: [
            PTiles(tiles: [
              PTile(
                  label: context.t('reports.shiftsShort'),
                  value: '${short.length}',
                  valueColor: short.isEmpty ? null : PharmaColors.amber),
              PTile(
                  label: context.t('reports.notCounted'),
                  value: '$uncounted',
                  valueColor: uncounted == 0 ? null : PharmaColors.red),
            ]),
            PSection(context.t('reports.shifts')),
            if (shifts.isEmpty)
              PNotice.text(
                  Tone.blue, Icons.info_outline, context.t('reports.noShifts'),
                  margin: EdgeInsets.zero)
            else
              PRows(children: [
                for (final s in shifts)
                  PRow(
                    avatar:
                        s.userName.isEmpty ? '?' : s.userName.characters.first,
                    avatarTone: s.varianceSantim == null
                        ? Tone.blue
                        : s.varianceSantim! < 0
                            ? Tone.red
                            : Tone.green,
                    title: '${s.userName} · ${s.branchName}',
                    subtitle:
                        '${context.l10n.date(s.openedAt)} ${context.l10n.time(s.openedAt)} · ${s.saleCount} ${context.t('home.sales')}'
                        '${s.note == null ? '' : '\n“${s.note}”'}',
                    value: s.varianceSantim == null
                        ? context.t('reports.open')
                        : formatMoney(s.varianceSantim!),
                    valueColor:
                        (s.varianceSantim ?? 0) < 0 ? PharmaColors.red : null,
                    valueCaption: s.countedSantim == null
                        ? context.t('reports.notCountedShort')
                        : '${context.t('reports.of')} ${formatMoney(s.expectedSantim)}',
                  ),
              ]),
          ]),
        ),
      ]),
    );
  }
}
