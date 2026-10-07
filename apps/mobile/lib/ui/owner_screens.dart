import 'dart:async';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../core/money.dart';
import '../core/owner_reports.dart';
import '../core/permissions.dart';
import '../core/theme.dart';
import '../l10n/locale_store.dart';
import 'kit.dart';
import 'terminal.dart';

/// For tests: replaces the platform share sheet for the day's summary.
Future<void> Function(String text)? debugShareSummary;

/// The end-of-day summary (FR-17, ADR-035).
///
/// What an owner who is not behind the counter wants every evening, in the order they
/// would ask it: how much, is the drawer right, who was on, what am I owed, what is running
/// out, and did anything happen I should know about.
///
/// It needs the server — this is every phone's sales added up, which no one phone has —
/// and it says how fresh it is, because a till offline since noon is missing from the
/// afternoon (BR-8.1).
class DailySummaryScreen extends StatefulWidget {
  const DailySummaryScreen({super.key, this.today});

  /// For tests: what "now" is.
  final DateTime? today;

  @override
  State<DailySummaryScreen> createState() => _DailySummaryScreenState();
}

class _DailySummaryScreenState extends State<DailySummaryScreen> {
  /// 0 is today, 1 yesterday.
  int _daysAgo = 0;
  DailySummary? _summary;
  String? _error;
  bool _loading = false;
  bool _started = false;

  DateTime get _day {
    final now = widget.today ?? DateTime.now();
    return DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: _daysAgo));
  }

  Future<void> _load() async {
    final t = TerminalScope.read(context);
    final offline = context.t('day.offline');
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // The shop's day: local midnight to local midnight, sent as instants.
      final from = _day;
      final summary = await t.authed((token) => t.api.dailySummary(token,
          from: from, to: from.add(const Duration(days: 1))));
      if (mounted) {
        setState(() {
          _summary = summary;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _summary = null;
          _loading = false;
          _error = offline;
        });
      }
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

  Future<void> _share(DailySummary summary) async {
    final t = TerminalScope.read(context);
    final text = summary.toText(context.l10n,
        shop: t.branchName ?? t.session.tenantCode,
        day: context.l10n.date(_day.add(const Duration(hours: 12))));
    final override = debugShareSummary;
    if (override != null) return override(text);
    await SharePlus.instance.share(ShareParams(text: text));
  }

  @override
  Widget build(BuildContext context) {
    final s = _summary;
    return Scaffold(
      body: Column(children: [
        PTopBar(
          title: context.t('day.title'),
          onBack: () => Navigator.of(context).pop(),
        ),
        Expanded(
          child: PBody(children: [
            PSegmented<int>(
              options: [
                (0, context.t('day.today')),
                (1, context.t('day.yesterday')),
              ],
              value: _daysAgo,
              onChanged: (v) {
                setState(() => _daysAgo = v);
                unawaited(_load());
              },
            ),
            if (_loading && s == null)
              const Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (_error != null)
              PNotice.text(Tone.amber, Icons.cloud_off_outlined, _error!),
            if (s != null) ..._body(context, s),
          ]),
        ),
        if (s != null)
          PFooter(
            child: PButton(
              kind: BtnKind.plain,
              icon: Icons.ios_share,
              label: context.t('day.share'),
              onPressed: () => _share(s),
            ),
          ),
      ]),
    );
  }

  List<Widget> _body(BuildContext context, DailySummary s) => [
        PTiles(
          hero: PTile(
            hero: true,
            label: context.t('day.sales'),
            value: formatEtbShort(s.grossSantim),
            delta: context.tf('day.salesCount', {'n': s.saleCount}),
          ),
          tiles: [
            PTile(
                label: context.t('pay.cash'),
                value: formatBirr(s.cashSantim),
                unit: 'ETB'),
            PTile(
                label: context.t('reports.otherTender'),
                value: formatBirr(s.otherTenderSantim),
                unit: 'ETB'),
            if (s.creditSantim > 0)
              PTile(
                  label: context.t('reports.onCredit'),
                  value: formatBirr(s.creditSantim),
                  unit: 'ETB',
                  valueColor: PharmaColors.amber),
          ],
        ),

        // ------------------------------------------------------------ the drawer
        PSection(context.t('day.drawer')),
        if (s.shifts.isEmpty)
          PNotice.text(Tone.blue, Icons.point_of_sale_outlined,
              context.t('day.text.noTill'),
              margin: EdgeInsets.zero)
        else ...[
          // The one line that decides whether the owner relaxes: red if any till is
          // short, however little; never softened by another till being over.
          PNotice.text(
            s.shortageSantim > 0
                ? Tone.red
                : s.openShifts > 0
                    ? Tone.amber
                    : Tone.green,
            s.shortageSantim > 0
                ? Icons.error_outline
                : s.openShifts > 0
                    ? Icons.schedule
                    : Icons.check_circle_outline,
            s.shortageSantim > 0
                ? context.tf(
                    'day.text.short', {'amount': formatMoney(s.shortageSantim)})
                : s.openShifts > 0
                    ? context.tf('day.text.open', {'n': s.openShifts})
                    : context.tf('day.text.balanced', {'n': s.countedShifts}),
            margin: EdgeInsets.zero,
          ),
          const SizedBox(height: 10),
          PRows(children: [
            for (final shift in s.shifts)
              PRow(
                avatar: shift.userName.isEmpty
                    ? '?'
                    : shift.userName.characters.first.toUpperCase(),
                avatarTone: (shift.varianceSantim ?? 0) < 0
                    ? Tone.red
                    : shift.closed
                        ? Tone.green
                        : Tone.amber,
                title: shift.userName,
                subtitle: shift.branchName,
                value: shift.varianceSantim == null
                    ? context.t('day.stillOpen')
                    : shift.varianceSantim == 0
                        ? context.t('day.exact')
                        : formatMoney(shift.varianceSantim!),
                valueColor:
                    (shift.varianceSantim ?? 0) < 0 ? PharmaColors.red : null,
                valueCaption: shift.varianceSantim == null
                    ? null
                    : shift.varianceSantim! < 0
                        ? context.t('day.shortCaption')
                        : shift.varianceSantim! > 0
                            ? context.t('day.overCaption')
                            : null,
              ),
          ]),
        ],

        // ------------------------------------------------------------ money owed
        PSection(context.t('day.owedTitle')),
        PRows(children: [
          PRow(
            avatarIcon: Icons.menu_book_outlined,
            avatarTone: s.owedSantim > 0 ? Tone.amber : Tone.green,
            title: context.t('credit.totalOwed'),
            subtitle: context.tf('day.customersOwing', {'n': s.customersOwing}),
            value: formatMoney(s.owedSantim),
          ),
          PRow(
            avatarIcon: Icons.south_west,
            title: context.t('day.repaid'),
            value: formatMoney(s.repaidSantim),
          ),
        ]),

        // ----------------------------------------------------------------- stock
        PSection(context.t('day.stock')),
        if (s.lowCount == 0 && s.expiringBatches == 0 && s.oversoldBatches == 0)
          PNotice.text(Tone.green, Icons.check_circle_outline,
              context.t('day.stockFine'),
              margin: EdgeInsets.zero)
        else
          PRows(children: [
            for (final item in s.low)
              PRow(
                avatarIcon: Icons.trending_down,
                avatarTone: item.onHand <= 0 ? Tone.red : Tone.amber,
                title: item.name,
                value: '${item.onHand}',
                valueCaption: item.unit,
                valueColor: item.onHand <= 0 ? PharmaColors.red : null,
              ),
            if (s.lowCount > s.low.length)
              PRow(
                title:
                    context.tf('day.moreLow', {'n': s.lowCount - s.low.length}),
              ),
            if (s.expiringBatches > 0)
              PRow(
                avatarIcon: Icons.event_busy_outlined,
                avatarTone: Tone.amber,
                title:
                    context.tf('day.text.expiring', {'n': s.expiringBatches}),
              ),
            if (s.oversoldBatches > 0)
              PRow(
                avatarIcon: Icons.error_outline,
                avatarTone: Tone.red,
                title:
                    context.tf('day.text.oversold', {'n': s.oversoldBatches}),
              ),
          ]),

        // -------------------------------------------------- should have been told
        if (s.priceChanges + s.stockWriteOffs + s.expiredDispenses > 0) ...[
          PSection(context.t('day.attention')),
          PRows(children: [
            if (s.priceChanges > 0)
              PRow(
                  avatarIcon: Icons.sell_outlined,
                  title: context.tf('day.text.prices', {'n': s.priceChanges})),
            if (s.stockWriteOffs > 0)
              PRow(
                  avatarIcon: Icons.delete_outline,
                  avatarTone: Tone.amber,
                  title: context
                      .tf('day.text.writeOffs', {'n': s.stockWriteOffs})),
            if (s.expiredDispenses > 0)
              PRow(
                  avatarIcon: Icons.warning_amber_rounded,
                  avatarTone: Tone.red,
                  title: context
                      .tf('day.text.expired', {'n': s.expiredDispenses})),
          ]),
        ],

        const SizedBox(height: 14),
        PNotice.text(
          Tone.amber,
          Icons.schedule,
          s.lastSyncedAt == null
              ? context.t('reports.currencyNone')
              : context.tf('reports.currency', {
                  'when':
                      '${context.l10n.date(s.lastSyncedAt!)} ${context.l10n.time(s.lastSyncedAt!)}'
                }),
        ),
      ];
}

/// The audit trail (FR-17; ADR-015 built the log, this is where an owner reads it).
///
/// Who changed a price, who wrote stock off, who handed over expired medicine, who added a
/// member of staff — as sentences, newest first. Entries that are the usual shape of a
/// problem (a price made *cheaper*, a write-off, an expired dispense) are marked, and can
/// be listed alone.
///
/// Read-only, and there is nothing here to make it otherwise: the log is append-only at the
/// database, for the owner too.
class AuditScreen extends StatefulWidget {
  const AuditScreen({super.key});

  @override
  State<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends State<AuditScreen> {
  List<AuditEntry>? _entries;
  String? _error;

  /// Null shows everything.
  AuditKind? _kind;
  bool _flaggedOnly = false;
  bool _started = false;

  Future<void> _load() async {
    final t = TerminalScope.read(context);
    final offline = context.t('day.offline');
    try {
      final entries = await t.authed(t.api.auditTrail);
      if (mounted) setState(() => _entries = entries);
    } catch (_) {
      if (mounted) setState(() => _error = offline);
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

  @override
  Widget build(BuildContext context) {
    final t = TerminalScope.of(context);
    final all = _entries;
    final shown = (all ?? const <AuditEntry>[])
        .where((e) => _kind == null || e.kind == _kind)
        .where((e) => !_flaggedOnly || e.flagged)
        .toList();
    String? nameOf(String id) {
      for (final p in t.products) {
        if (p.id == id) return p.name;
      }
      return null;
    }

    return Scaffold(
      body: Column(children: [
        PTopBar(
          title: context.t('audit.title'),
          onBack: () => Navigator.of(context).pop(),
        ),
        Expanded(
          child: PBody(children: [
            PSegmented<AuditKind?>(
              options: [
                (null, context.t('audit.all')),
                (AuditKind.prices, context.t('audit.kind.prices')),
                (AuditKind.stock, context.t('audit.kind.stock')),
                (AuditKind.staff, context.t('audit.kind.staff')),
              ],
              value: _kind,
              onChanged: (v) => setState(() => _kind = v),
            ),
            GestureDetector(
              onTap: () => setState(() => _flaggedOnly = !_flaggedOnly),
              child: PNotice.text(
                _flaggedOnly ? Tone.red : Tone.blue,
                _flaggedOnly ? Icons.flag : Icons.flag_outlined,
                context
                    .t(_flaggedOnly ? 'audit.flaggedOn' : 'audit.flaggedOff'),
                margin: EdgeInsets.zero,
              ),
            ),
            const SizedBox(height: 14),
            if (all == null && _error == null)
              const Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (_error != null)
              PNotice.text(Tone.amber, Icons.cloud_off_outlined, _error!),
            if (all != null && shown.isEmpty)
              PNotice.text(Tone.green, Icons.check_circle_outline,
                  context.t('audit.none'),
                  margin: EdgeInsets.zero),
            if (shown.isNotEmpty)
              PRows(children: [
                for (final e in shown)
                  PRow(
                    avatarIcon: switch (e.kind) {
                      AuditKind.prices => Icons.sell_outlined,
                      AuditKind.stock => Icons.inventory_2_outlined,
                      AuditKind.staff => Icons.badge_outlined,
                      AuditKind.account => Icons.receipt_long_outlined,
                    },
                    avatarTone: e.flagged ? Tone.red : Tone.grey,
                    title: e.describe(context.l10n, productName: nameOf),
                    subtitle: [
                      // Who, then when. "The platform" when it was not one of theirs.
                      e.actorName ?? context.t('audit.platform'),
                      '${context.l10n.date(e.occurredAt)} ${context.l10n.time(e.occurredAt)}',
                      if (e.note != null) '“${e.note}”',
                    ].join(' · '),
                  ),
              ]),
            const SizedBox(height: 14),
            Text(context.t('audit.footer'),
                style:
                    const TextStyle(fontSize: 11.5, color: PharmaColors.faint)),
          ]),
        ),
      ]),
    );
  }
}

/// Whether the audit trail is this person's to open: the owner alone, as the server
/// enforces (`settings.configure`, ADR-015).
bool canReadAudit(Terminal t) => t.can(Capability.settingsConfigure);
