import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/catalog_repository.dart';
import '../data/inventory_repository.dart';
import '../l10n/locale_store.dart';
import 'kit.dart';
import 'terminal.dart';

/// Counting a batch — "Adjust stock" on the product screen (FR-3, BR-3.2).
///
/// BR-3.2 promises that an oversell is "flagged for **physical reconciliation**". This is
/// where that promise is kept: somebody looked at the shelf, and what they found wins.
///
/// **The person enters what they counted, not a correction.** Asking for "+8" requires
/// arithmetic against a number they have just decided is wrong; "how many are there?" is
/// the question they can actually answer, and the delta is derived.
Future<bool?> showCountSheet(BuildContext context,
        {required LocalBatch batch, required String productName}) =>
    showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => TerminalScope(
        terminal: TerminalScope.read(context),
        child: CountSheet(batch: batch, productName: productName),
      ),
    );

class CountSheet extends StatefulWidget {
  const CountSheet({super.key, required this.batch, required this.productName});

  final LocalBatch batch;
  final String productName;

  @override
  State<CountSheet> createState() => _CountSheetState();
}

class _CountSheetState extends State<CountSheet> {
  final _counted = TextEditingController();
  final _note = TextEditingController();
  AdjustmentReason _reason = AdjustmentReason.recount;
  bool _busy = false;

  @override
  void dispose() {
    _counted.dispose();
    _note.dispose();
    super.dispose();
  }

  int? get _countedQty {
    final n = int.tryParse(_counted.text.trim());
    return n == null || n < 0 ? null : n;
  }

  int? get _delta {
    final counted = _countedQty;
    return counted == null ? null : counted - widget.batch.qtyOnHand;
  }

  bool get _valid {
    final delta = _delta;
    if (delta == null || delta == 0) return false;
    // An unexplained write-off is indistinguishable from a covered-up one; the server
    // refuses it too.
    if (_reason.requiresNote && _note.text.trim().isEmpty) return false;
    return true;
  }

  Future<void> _submit() async {
    final t = TerminalScope.read(context);
    setState(() => _busy = true);
    try {
      await t.inventory.adjustStock(
        batch: widget.batch,
        branchId: t.branchId,
        countedQty: _countedQty!,
        reason: _reason,
        note: _note.text.trim().isEmpty ? null : _note.text.trim(),
      );
      if (mounted) Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final delta = _delta;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          18, 20, 18, MediaQuery.of(context).viewInsets.bottom + 18),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.productName,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text(
                context.tf('count.systemSays', {
                  'lot': widget.batch.lotNo,
                  'qty': widget.batch.qtyOnHand,
                }),
                style:
                    const TextStyle(color: PharmaColors.muted, fontSize: 13)),
            const SizedBox(height: 16),
            PField(
              label: context.t('count.howMany'),
              helper: context.t('count.howManyHint'),
              controller: _counted,
              autofocus: true,
              large: true,
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() {}),
            ),
            if (delta != null && delta != 0)
              PNotice.text(
                delta < 0 ? Tone.red : Tone.green,
                delta < 0 ? Icons.trending_down : Icons.trending_up,
                delta < 0
                    ? context.tf('count.fewer', {'n': delta.abs()})
                    : context.tf('count.more', {'n': delta}),
              ),
            PField(
              label: context.t('count.reason'),
              child: DropdownButtonFormField<AdjustmentReason>(
                initialValue: _reason,
                items: [
                  for (final reason in AdjustmentReason.values)
                    DropdownMenuItem(
                        value: reason,
                        child: Text(context.t('reason.${reason.name}'))),
                ],
                onChanged: (r) =>
                    setState(() => _reason = r ?? AdjustmentReason.recount),
              ),
            ),
            PField(
              label: context.t(_reason.requiresNote
                  ? 'count.noteRequired'
                  : 'count.noteOptional'),
              helper: _reason.requiresNote
                  ? context.t('count.noteNeeded')
                  : context.t('count.noteHint'),
              controller: _note,
              maxLines: 2,
              onChanged: (_) => setState(() {}),
            ),
            PButton(
              label: context.t(_busy ? 'cashup.recording' : 'count.record'),
              onPressed: !_valid || _busy ? null : _submit,
            ),
          ],
        ),
      ),
    );
  }
}
