import 'package:flutter/material.dart';

import '../core/money.dart';
import '../core/theme.dart';
import '../data/shift_repository.dart';
import '../l10n/locale_store.dart';

/// Cash-up / Z-report (FR-8, AC-8.1).
///
/// Vision §2.1.1 calls this the owner's primary anti-shrinkage control. Two decisions in
/// this screen follow from that, and both are deliberate:
///
///  - **The expected figure is hidden until the cashier has entered their count.** A
///    reconciliation that shows the target first is not a count; it is a prompt. Revealing
///    it afterwards is the difference between measuring the till and asking someone to
///    agree with a number.
///  - **A variance is reported, never blocked.** The cashier can always complete the
///    cash-up. Refusing to accept a discrepancy would simply teach people to fudge the
///    count until the screen let them through.
class CashUpScreen extends StatefulWidget {
  const CashUpScreen({
    super.key,
    required this.shift,
    required this.shifts,
    required this.onCompleted,
  });

  final ActiveShift shift;
  final ShiftRepository shifts;
  final void Function(int varianceSantim) onCompleted;

  @override
  State<CashUpScreen> createState() => _CashUpScreenState();
}

class _CashUpScreenState extends State<CashUpScreen> {
  final _counted = TextEditingController();
  final _note = TextEditingController();
  ExpectedCash? _expected;
  bool _revealed = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _counted.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final expected = await widget.shifts.expectedCash(widget.shift.id);
    if (mounted) setState(() => _expected = expected);
  }

  /// Birr as typed, converted to santim exactly. `int.parse` on the two halves rather than
  /// a double: money never becomes a float, not even for a moment (guardian G4).
  int? _countedSantim() {
    final text = _counted.text.trim();
    if (text.isEmpty) return null;
    final parts = text.split('.');
    final birr = int.tryParse(parts[0].replaceAll(',', ''));
    if (birr == null || birr < 0) return null;
    if (parts.length == 1) return birr * 100;
    if (parts.length > 2) return null;
    final cents = int.tryParse(parts[1].padRight(2, '0').substring(0, 2));
    if (cents == null) return null;
    return birr * 100 + cents;
  }

  Future<void> _submit() async {
    final counted = _countedSantim();
    if (counted == null || _expected == null) return;

    setState(() => _busy = true);
    final variance = await widget.shifts.closeShiftWithCashUp(
      shift: widget.shift,
      countedSantim: counted,
      note: _note.text.trim().isEmpty ? null : _note.text.trim(),
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _revealed = true;
    });
    widget.onCompleted(variance);
  }

  @override
  Widget build(BuildContext context) {
    final expected = _expected;
    final counted = _countedSantim();

    return Scaffold(
      appBar: AppBar(title: Text(context.t('cashup.title'))),
      body: expected == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(context.t('cashup.thisShift'),
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 10),
                        // The date renders in the Ethiopian calendar (BR-10.2); the
                        // instant itself stays UTC in storage (AC-10.2).
                        _row(
                            context.t('cashup.opened'),
                            '${context.l10n.date(widget.shift.openedAt)} '
                            '${context.l10n.time(widget.shift.openedAt)}'),
                        _row(
                            context.t('cashup.sales'), '${expected.saleCount}'),
                        _row(context.t('cashup.float'),
                            formatEtb(expected.openingFloatSantim)),
                        if (expected.unsyncedSaleCount > 0) ...[
                          const SizedBox(height: 10),
                          // The honest caveat on the number. If sales are still queued the
                          // server will compute a different expected figure, and that gap
                          // is a finding rather than a fault (ADR-012 §3).
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: PharmaColors.amberTint,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '${expected.unsyncedSaleCount} '
                              '${context.t('cashup.unsyncedWarning')}',
                              style: const TextStyle(
                                  color: PharmaColors.amber, fontSize: 12.5),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(context.t('cashup.countDrawer'),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                  context.t('cashup.countHint'),
                  style:
                      const TextStyle(color: PharmaColors.muted, fontSize: 13),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _counted,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  enabled: !_revealed,
                  decoration: InputDecoration(
                    labelText: context.t('cashup.counted'),
                    prefixIcon: const Icon(Icons.payments_outlined),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _note,
                  enabled: !_revealed,
                  maxLength: 500,
                  decoration: InputDecoration(
                    labelText: context.t('cashup.note'),
                    helperText: context.t('cashup.noteHint'),
                  ),
                ),
                const SizedBox(height: 8),
                if (_revealed)
                  _Result(
                    expected: expected,
                    countedSantim: counted ?? 0,
                    labels: (
                      expected: context.t('cashup.expected'),
                      counted: context.t('cashup.counted'),
                      difference: context.t('cashup.difference'),
                      balanced: context.t('cashup.balanced'),
                      short: context.t('cashup.short'),
                      over: context.t('cashup.over'),
                      closedOk: context.t('cashup.closedOk'),
                      closedVariance: context.t('cashup.closedVariance'),
                    ),
                  )
                else
                  FilledButton(
                    onPressed: counted == null || _busy ? null : _submit,
                    child: Text(context
                        .t(_busy ? 'cashup.recording' : 'cashup.record')),
                  ),
              ],
            ),
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(
                child: Text(label,
                    style: const TextStyle(
                        color: PharmaColors.muted, fontSize: 13.5))),
            Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      );
}

typedef _ResultLabels = ({
  String expected,
  String counted,
  String difference,
  String balanced,
  String short,
  String over,
  String closedOk,
  String closedVariance,
});

class _Result extends StatelessWidget {
  const _Result({
    required this.expected,
    required this.countedSantim,
    required this.labels,
  });

  final ExpectedCash expected;
  final int countedSantim;
  final _ResultLabels labels;

  @override
  Widget build(BuildContext context) {
    final variance = countedSantim - expected.expectedSantim;
    final (color, tint, label) = variance == 0
        ? (PharmaColors.greenDark, PharmaColors.greenTint, labels.balanced)
        : variance < 0
            ? (PharmaColors.red, PharmaColors.redTint, labels.short)
            : (PharmaColors.amber, PharmaColors.amberTint, labels.over);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration:
          BoxDecoration(color: tint, borderRadius: BorderRadius.circular(14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  color: color, fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 10),
          _line(labels.expected, formatEtb(expected.expectedSantim), color),
          _line(labels.counted, formatEtb(countedSantim), color),
          const Divider(height: 20),
          _line(labels.difference, formatEtb(variance), color, bold: true),
          const SizedBox(height: 10),
          Text(
            variance == 0 ? labels.closedOk : labels.closedVariance,
            style: TextStyle(color: color, fontSize: 12.5),
          ),
        ],
      ),
    );
  }

  Widget _line(String label, String value, Color color, {bool bold = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Expanded(
                child: Text(label,
                    style: TextStyle(color: color, fontSize: 13.5))),
            Text(
              value,
              style: TextStyle(
                color: color,
                fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
                fontSize: bold ? 16 : 14,
              ),
            ),
          ],
        ),
      );
}
