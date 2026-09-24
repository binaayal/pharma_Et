import 'dart:async';

import 'package:flutter/material.dart';

import '../core/money.dart';
import '../data/shift_repository.dart';
import '../l10n/locale_store.dart';
import 'kit.dart';
import 'terminal.dart';

/// Shift cash-up (prototype screen 15; FR-8, BR-8.2).
///
/// The owner's anti-shrinkage control: expected against counted, the variance attributed to
/// the staff member and the shift. The count is recorded whatever it says — a difference is
/// what matters, not hiding it — and nothing here waits for a network.
class CashUpScreen extends StatefulWidget {
  const CashUpScreen({super.key});

  @override
  State<CashUpScreen> createState() => _CashUpScreenState();
}

class _CashUpScreenState extends State<CashUpScreen> {
  final _counted = TextEditingController();
  final _note = TextEditingController();
  ActiveShift? _shift;
  ExpectedCash? _expected;
  int? _recordedVariance;
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_shift == null) {
      final t = TerminalScope.read(context);
      _shift = t.shift;
      if (_shift != null) {
        unawaited(t.shifts.expectedCash(_shift!.id).then((e) {
          if (mounted) setState(() => _expected = e);
        }));
      }
    }
  }

  @override
  void dispose() {
    _counted.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final t = TerminalScope.read(context);
    final counted = parseBirr(_counted.text);
    if (counted == null || _shift == null) return;
    setState(() => _busy = true);
    final variance = await t.shifts.closeShiftWithCashUp(
      shift: _shift!,
      countedSantim: counted,
      note: _note.text.trim().isEmpty ? null : _note.text.trim(),
    );
    await t.refresh();
    // The close and the cash-up are queued; push them when there is a network.
    unawaited(t.sync());
    if (!mounted) return;
    setState(() {
      _busy = false;
      _recordedVariance = variance;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = TerminalScope.of(context);
    final shift = _shift;
    final expected = _expected;
    final counted = parseBirr(_counted.text);
    final variance = counted == null || expected == null
        ? null
        : counted - expected.expectedSantim;
    final done = _recordedVariance != null;

    return Scaffold(
      body: Column(children: [
        PTopBar(
          title: context.t('cashup.title'),
          subtitle: shift == null
              ? null
              : '${t.firstName} · ${t.branchName ?? t.session.tenantCode} · ${context.t('cashup.shiftClose')}',
          onBack: () => Navigator.of(context).pop(),
        ),
        Expanded(
          child: shift == null
              ? PBody(children: [
                  PNotice.text(Tone.blue, Icons.info_outline,
                      context.t('cashup.noShift')),
                ])
              : expected == null
                  ? const Center(child: CircularProgressIndicator())
                  : PBody(children: [
                      PSummary(
                        margin: false,
                        lines: [
                          (
                            context.t('cashup.opened'),
                            '${context.l10n.date(shift.openedAt)} ${context.l10n.time(shift.openedAt)}'
                          ),
                          (
                            context.t('cashup.float'),
                            formatMoney(expected.openingFloatSantim)
                          ),
                          (
                            '${context.t('cashup.cashSales')} (${expected.saleCount})',
                            formatMoney(expected.cashTakenSantim)
                          ),
                        ],
                        total: (
                          context.t('cashup.expectedInDrawer'),
                          formatMoney(expected.expectedSantim)
                        ),
                      ),
                      if (expected.unsyncedSaleCount > 0)
                        // The honest caveat: if sales are still queued the server will
                        // compute a different expected figure, and that gap is a finding
                        // rather than a fault (ADR-012 §3).
                        PNotice.text(Tone.amber, Icons.schedule,
                            '${expected.unsyncedSaleCount} ${context.t('cashup.unsyncedWarning')}',
                            margin: const EdgeInsets.only(top: 14)),
                      const SizedBox(height: 16),
                      PField(
                        label: context.t('cashup.counted'),
                        controller: _counted,
                        large: true,
                        hint: '0.00',
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        enabled: !done,
                        onChanged: (_) => setState(() {}),
                      ),
                      if (variance != null)
                        _varianceNotice(context, t, variance, done),
                      PField(
                        label: context.t('cashup.note'),
                        helper: context.t('cashup.noteHint'),
                        controller: _note,
                        enabled: !done,
                        maxLines: 2,
                      ),
                    ]),
        ),
        if (shift != null && expected != null)
          PFooter(
            child: done
                ? PButton(
                    kind: BtnKind.green,
                    label: context.t('common.done'),
                    onPressed: () => Navigator.of(context).pop(),
                  )
                : PButton(
                    label:
                        context.t(_busy ? 'cashup.recording' : 'cashup.record'),
                    onPressed: _busy || counted == null ? null : _submit,
                  ),
          ),
      ]),
    );
  }

  Widget _varianceNotice(
      BuildContext context, Terminal t, int variance, bool done) {
    if (variance == 0) {
      return PNotice.text(Tone.green, Icons.check_circle_outline,
          done ? context.t('cashup.closedOk') : context.t('cashup.balanced'));
    }
    final label =
        variance < 0 ? context.t('cashup.short') : context.t('cashup.over');
    return PNotice(
      tone: variance < 0 ? Tone.red : Tone.amber,
      icon: Icons.warning_amber_rounded,
      child: Text.rich(TextSpan(children: [
        TextSpan(
            text: '$label ${formatEtb(variance)}. ',
            style: const TextStyle(fontWeight: FontWeight.w700)),
        TextSpan(
            text: done
                ? context.t('cashup.closedVariance')
                : context.tf('cashup.attributed', {'name': t.firstName})),
      ])),
    );
  }
}
