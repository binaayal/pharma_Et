import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/catalog_repository.dart';
import '../data/inventory_repository.dart';
import '../l10n/locale_store.dart';

/// Stock reconciliation (FR-3, BR-3.2).
///
/// BR-3.2 promises that an oversell is "flagged for **physical reconciliation**". This is
/// where that promise is kept: somebody looked at the shelf, and what they found wins.
///
/// Two deliberate choices:
///
///  - **The cashier enters what they counted, not a correction.** Asking for "+8" requires
///    them to do arithmetic against a number they have just decided is wrong. Asking "how
///    many are there?" is the question they can actually answer, and the delta is derived.
///  - **Negative batches sort first.** A negative count means the shelf and the system
///    disagree, and until somebody counts, every expiry decision resting on that number is
///    guesswork.
class ReconcileScreen extends StatefulWidget {
  const ReconcileScreen({
    super.key,
    required this.catalog,
    required this.inventory,
    required this.branchId,
  });

  final CatalogRepository catalog;
  final InventoryRepository inventory;
  final String branchId;

  @override
  State<ReconcileScreen> createState() => _ReconcileScreenState();
}

class _ReconcileScreenState extends State<ReconcileScreen> {
  List<LocalBatch> _batches = [];
  Map<String, String> _productNames = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final batches =
        await widget.inventory.batchesNeedingAttention(widget.branchId);
    final products = await widget.catalog.products();
    if (!mounted) return;
    setState(() {
      _batches = batches;
      _productNames = {for (final p in products) p.id: p.name};
    });
  }

  Future<void> _reconcile(LocalBatch batch) async {
    final done = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CountSheet(
        batch: batch,
        productName: _productNames[batch.productId] ?? batch.productId,
        inventory: widget.inventory,
        branchId: widget.branchId,
      ),
    );
    if (done == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final oversold = _batches.where((b) => b.qtyOnHand < 0).length;

    return Scaffold(
      appBar: AppBar(title: Text(context.t('stock.count'))),
      body: Column(
        children: [
          if (oversold > 0)
            Container(
              width: double.infinity,
              color: PharmaColors.redTint,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              child: Text(
                context.tf('count.oversold', {'n': oversold}),
                style: const TextStyle(color: PharmaColors.red, fontSize: 12.5),
              ),
            ),
          Expanded(
            child: _batches.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        context.t('count.empty'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: PharmaColors.muted),
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: _batches.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final batch = _batches[index];
                      final negative = batch.qtyOnHand < 0;
                      return Card(
                        child: ListTile(
                          title: Text(_productNames[batch.productId] ??
                              batch.productId),
                          subtitle: Text(
                            context.tf('stock.lotExpires', {
                              'lot': batch.lotNo,
                              'date':
                                  context.l10n.calendarDate(batch.expiryDate),
                            }),
                            style: const TextStyle(fontSize: 12.5),
                          ),
                          trailing: Text(
                            '${batch.qtyOnHand}',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 17,
                              color: negative
                                  ? PharmaColors.red
                                  : PharmaColors.ink,
                            ),
                          ),
                          onTap: () => _reconcile(batch),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _CountSheet extends StatefulWidget {
  const _CountSheet({
    required this.batch,
    required this.productName,
    required this.inventory,
    required this.branchId,
  });

  final LocalBatch batch;
  final String productName;
  final InventoryRepository inventory;
  final String branchId;

  @override
  State<_CountSheet> createState() => _CountSheetState();
}

class _CountSheetState extends State<_CountSheet> {
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
    if (_reason.requiresNote && _note.text.trim().isEmpty) return false;
    return true;
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      await widget.inventory.adjustStock(
        batch: widget.batch,
        branchId: widget.branchId,
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
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.productName,
              style:
                  const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          Text(
              context.tf('count.systemSays', {
                'lot': widget.batch.lotNo,
                'qty': widget.batch.qtyOnHand,
              }),
              style: const TextStyle(color: PharmaColors.muted, fontSize: 13)),
          const SizedBox(height: 16),
          TextField(
            controller: _counted,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: context.t('count.howMany'),
              helperText: context.t('count.howManyHint'),
            ),
            onChanged: (_) => setState(() {}),
          ),
          if (delta != null && delta != 0) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color:
                    delta < 0 ? PharmaColors.redTint : PharmaColors.greenTint,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                delta < 0
                    ? context.tf('count.fewer', {'n': delta.abs()})
                    : context.tf('count.more', {'n': delta}),
                style: TextStyle(
                  color: delta < 0 ? PharmaColors.red : PharmaColors.greenDark,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ),
          ],
          const SizedBox(height: 14),
          DropdownButtonFormField<AdjustmentReason>(
            initialValue: _reason,
            decoration: InputDecoration(labelText: context.t('count.reason')),
            items: [
              for (final reason in AdjustmentReason.values)
                DropdownMenuItem(
                    value: reason,
                    child: Text(context.t('reason.${reason.name}'))),
            ],
            onChanged: (r) =>
                setState(() => _reason = r ?? AdjustmentReason.recount),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            maxLength: 500,
            decoration: InputDecoration(
              labelText: context.t(_reason.requiresNote
                  ? 'count.noteRequired'
                  : 'count.noteOptional'),
              // An unexplained write-off is indistinguishable from a covered-up one, which
              // is why the server refuses it too rather than trusting this field.
              helperText: _reason.requiresNote
                  ? context.t('count.noteNeeded')
                  : context.t('count.noteHint'),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: !_valid || _busy ? null : _submit,
            child: Text(context.t(_busy ? 'cashup.recording' : 'count.record')),
          ),
        ],
      ),
    );
  }
}
