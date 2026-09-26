import 'dart:async';

import 'package:flutter/material.dart';

import '../api/tenant_api.dart';
import '../core/money.dart';
import '../core/permissions.dart';
import '../core/theme.dart';
import '../l10n/locale_store.dart';
import 'cash_up_screen.dart';
import 'kit.dart';
import 'receive_screen.dart';
import 'subscription_screens.dart';
import 'sync_chip.dart';
import 'terminal.dart';
import 'till.dart';

/// Home (prototype screen 07) — "role-aware: owners see all branches consolidated; a
/// cashier sees only their branch and shift".
///
/// The owner's figures come from the server and say how current they are (BR-8.1). A
/// cashier's come from this device, so they are right with no network at all.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.onSell,
    required this.onStock,
    required this.onReports,
  });

  final VoidCallback onSell;
  final VoidCallback onStock;
  final VoidCallback onReports;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  SalesSummary? _summary;
  List<ShiftReport> _openShifts = const [];
  ({int count, int totalSantim})? _local;
  ({int expiring, int negative})? _attention;
  bool _loading = false;

  int _seen = -1;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Re-read whenever the terminal's data moved: a sale, a count, a pull.
    final revision = TerminalScope.of(context).revision;
    if (revision != _seen && !_loading) {
      _seen = revision;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    _loading = true;
    final t = TerminalScope.read(context);
    final local = await t.sales.todayOnDevice(t.branchId);
    final attention = await t.catalog.attention(t.branchId);
    if (mounted) {
      setState(() {
        _local = local;
        _attention = attention;
      });
    }
    if (t.canReadReports) {
      final now = DateTime.now();
      final midnight = DateTime(now.year, now.month, now.day);
      try {
        final summary = await t.authed((token) => t.api.salesSummary(token,
            from: midnight, to: midnight.add(const Duration(days: 1))));
        final shifts = await t.authed(t.api.cashUps);
        if (mounted) {
          setState(() {
            _summary = summary;
            _openShifts = shifts.where((s) => s.countedSantim == null).toList();
          });
        }
      } catch (_) {
        // Offline: the device's own figures stand, and the tile says whose they are.
      }
    }
    _loading = false;
  }

  Future<void> _refresh() async {
    final t = TerminalScope.read(context);
    await t.sync();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = TerminalScope.of(context);
    final roleLabel = context.t('role.${t.role}');
    final where = t.branchName ?? t.session.tenantCode;

    return Column(
      children: [
        PTopBar(
          title: t.session.scope.displayName,
          subtitle: '$roleLabel · $where',
          trailing: [SyncChip(status: t.status, onTap: _refresh)],
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refresh,
            child: PBody(children: [
              if (t.subscription?.suspended == true && t.isOwner)
                _suspendedNotice(context),
              if (t.session.offlineWindowExpired)
                PNotice.text(Tone.amber, Icons.cloud_off_outlined,
                    context.t('pos.offlineTooLong')),
              _tiles(context, t),
              PSection(context.t('home.attention')),
              _attentionRows(context, t),
              PSection(context.t('home.quickActions')),
              _quickActions(context, t),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _suspendedNotice(BuildContext context) => GestureDetector(
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => const SubscriptionEndedScreen())),
        child: PNotice(
          tone: Tone.red,
          icon: Icons.lock_outline,
          child: Text.rich(TextSpan(children: [
            TextSpan(
                text: '${context.t('sub.endedTitle')}. ',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            TextSpan(text: context.t('sub.tapToPay')),
          ])),
        ),
      );

  Widget _tiles(BuildContext context, Terminal t) {
    final summary = _summary;
    if (summary != null &&
        t.role.reach(Capability.reportTenant) != Grant.denied) {
      return PTiles(
        hero: PTile(
          hero: true,
          label: context.t('home.todayAll'),
          value: formatEtbShort(summary.total.grossSantim),
          delta:
              '${summary.total.saleCount} ${context.t('home.sales')}${summary.lastSyncedAt == null ? '' : ' · ${context.t('home.asOf')} ${context.l10n.time(summary.lastSyncedAt!)}'}',
        ),
        tiles: [
          for (final b in summary.branches)
            PTile(
                label: b.branchName,
                value: formatBirr(b.grossSantim),
                unit: 'ETB'),
        ],
      );
    }
    final local = _local;
    return PTiles(
      hero: PTile(
        hero: true,
        label:
            '${context.t('home.today')} · ${t.branchName ?? context.t('home.thisDevice')}',
        value: local == null ? '—' : formatEtbShort(local.totalSantim),
        delta: local == null
            ? null
            : '${local.count} ${context.t('home.sales')} · ${context.t('home.onThisDevice')}',
      ),
      tiles: [
        PTile(
          label: context.t('home.shift'),
          value: t.shift == null
              ? context.t('home.closed')
              : context.l10n.time(t.shift!.openedAt),
          unit: t.shift == null ? null : context.t('home.opened'),
          onTap: t.shift == null ? () => openTill(context) : null,
        ),
        PTile(
          label: context.t('home.toSync'),
          value: '${t.status.pending}',
          valueColor: t.status.pending > 0 ? PharmaColors.amber : null,
        ),
      ],
    );
  }

  Widget _attentionRows(BuildContext context, Terminal t) {
    final a = _attention;
    final rows = <Widget>[
      if (a != null && a.expiring > 0)
        PRow(
          avatar: '${a.expiring}',
          avatarTone: Tone.amber,
          title: context.t('home.expiring'),
          subtitle: context.tf('home.expiringSub', {'n': a.expiring}),
          chevron: true,
          onTap: widget.onStock,
        ),
      if (a != null && a.negative > 0)
        PRow(
          avatar: '${a.negative}',
          avatarTone: Tone.red,
          title: context.t('home.negative'),
          subtitle: context.t('home.negativeSub'),
          chevron: true,
          onTap: widget.onStock,
        ),
      if (_openShifts.isNotEmpty)
        PRow(
          avatar: '${_openShifts.length}',
          avatarTone: Tone.blue,
          title: context.t('home.awaitingCashup'),
          subtitle: _openShifts
              .map((s) => '${s.branchName} (${s.userName.split(' ').first})')
              .join(', '),
          chevron: true,
          onTap: widget.onReports,
        ),
      if (t.can(Capability.saleCreate) && t.shift == null)
        PRow(
          avatarIcon: Icons.point_of_sale_outlined,
          avatarTone: Tone.amber,
          title: context.t('shift.noTillTitle'),
          subtitle: context.t('shift.noTillSub'),
          chevron: true,
          onTap: () => openTill(context),
        ),
      if (t.shift != null && t.can(Capability.cashupPerform))
        PRow(
          avatarIcon: Icons.schedule,
          avatarTone: Tone.blue,
          title: context.t('home.tillOpen'),
          subtitle:
              '${context.t('home.since')} ${context.l10n.time(t.shift!.openedAt)} · ${context.t('home.closeWhenDone')}',
          chevron: true,
          onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const CashUpScreen())),
        ),
      if (t.status.needsAttention > 0)
        PRow(
          avatarIcon: Icons.priority_high,
          avatarTone: Tone.red,
          title:
              context.tf('home.syncAttention', {'n': t.status.needsAttention}),
          subtitle: context.t('home.syncAttentionSub'),
        ),
    ];
    if (rows.isEmpty) {
      return PNotice.text(
          Tone.green, Icons.check_circle_outline, context.t('home.allClear'),
          margin: EdgeInsets.zero);
    }
    return PRows(children: rows);
  }

  Widget _quickActions(BuildContext context, Terminal t) {
    final actions = <(IconData, String, VoidCallback)>[
      if (t.can(Capability.saleCreate))
        (Icons.add, context.t('tab.sell'), widget.onSell),
      if (t.can(Capability.goodsReceive))
        (
          Icons.south,
          context.t('home.receive'),
          () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ReceiveScreen()))
        ),
      (Icons.grid_view_rounded, context.t('tab.stock'), widget.onStock),
      if (t.canReadReports)
        (Icons.bar_chart_rounded, context.t('tab.reports'), widget.onReports),
    ];
    return Row(
      children: [
        for (var i = 0; i < 4; i++) ...[
          if (i > 0) const SizedBox(width: 10),
          Expanded(
            child: i < actions.length
                ? _QuickAction(
                    icon: actions[i].$1,
                    label: actions[i].$2,
                    onTap: actions[i].$3)
                : const SizedBox(),
          ),
        ],
      ],
    );
  }
}

/// `.qa a` — a quick-action card.
class _QuickAction extends StatelessWidget {
  const _QuickAction(
      {required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 6),
            decoration: BoxDecoration(
              color: PharmaColors.card,
              borderRadius: BorderRadius.circular(15),
              boxShadow: cardShadow,
            ),
            child: Column(children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: PharmaColors.greenTint,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(icon, color: PharmaColors.greenDark, size: 20),
              ),
              const SizedBox(height: 7),
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 11.5, fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      );
}
