import 'package:flutter/material.dart';

import '../core/money.dart';
import '../core/theme.dart';
import '../data/catalog_repository.dart';
import '../data/inventory_repository.dart';
import '../l10n/locale_store.dart';

/// Goods receipt (FR-7 base).
///
/// Stock arrives when the wholesaler's van arrives — which in this market is not when the
/// network is up. Everything here commits locally and queues, exactly like a sale, and the
/// shelf count is credited immediately so the counter can sell what is physically there.
///
/// The expiry date is entered as a **Gregorian calendar date** and shown in the Ethiopian
/// calendar beneath the field. Wholesaler paperwork and the box itself print Gregorian, so
/// asking for a converted date would invite transcription errors on the one field where
/// getting it wrong means selling expired medicine.
class ReceiveScreen extends StatefulWidget {
  const ReceiveScreen({
    super.key,
    required this.catalog,
    required this.inventory,
    required this.branchId,
  });

  final CatalogRepository catalog;
  final InventoryRepository inventory;
  final String branchId;

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> {
  final _supplier = TextEditingController();
  final List<ReceiptLine> _lines = [];
  List<LocalProduct> _products = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.catalog.products().then((p) {
      if (mounted) {
        setState(() => _products = p.where((x) => !x.isControlled).toList());
      }
    });
  }

  @override
  void dispose() {
    _supplier.dispose();
    super.dispose();
  }

  Future<void> _addLine() async {
    final line = await showModalBottomSheet<ReceiptLine>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _LineSheet(products: _products),
    );
    if (line != null && mounted) setState(() => _lines.add(line));
  }

  Future<void> _commit() async {
    if (_lines.isEmpty || _supplier.text.trim().isEmpty) return;
    setState(() => _busy = true);

    await widget.inventory.commitReceipt(
      lines: List.of(_lines),
      supplierName: _supplier.text.trim(),
      branchId: widget.branchId,
    );

    if (!mounted) return;
    final done = context.tf('receive.done', {'count': _lines.length});
    Navigator.of(context).pop(true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: PharmaColors.greenDark,
        content: Text(done),
      ),
    );
  }

  int get _totalCost => _lines.fold(0, (sum, l) => sum + l.costSantim * l.qty);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.t('stock.receive'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _supplier,
            decoration: InputDecoration(
              labelText: context.t('receive.supplier'),
              helperText: context.t('receive.supplierHint'),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Text(context.t('receive.lines'),
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const Spacer(),
              TextButton.icon(
                onPressed: _products.isEmpty ? null : _addLine,
                icon: const Icon(Icons.add),
                label: Text(context.t('receive.add')),
              ),
            ],
          ),
          if (_products.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                context.t('receive.noProducts'),
                style: const TextStyle(color: PharmaColors.muted, fontSize: 13),
              ),
            ),
          for (final (index, line) in _lines.indexed)
            Card(
              child: ListTile(
                title: Text(line.product.name),
                subtitle: Text(
                  '${context.tf('stock.lotExpires', {
                        'lot': line.lotNo,
                        'date': context.l10n.calendarDate(line.expiryDate),
                      })}\n${context.tf('receive.lineCost', {
                        'qty': line.qty,
                        'cost': formatEtb(line.costSantim),
                      })}',
                ),
                isThreeLine: true,
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => _lines.removeAt(index)),
                ),
              ),
            ),
          if (_lines.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Text(context.t('receive.totalCost'),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const Spacer(),
                Text(formatEtb(_totalCost),
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 16)),
              ],
            ),
          ],
          const SizedBox(height: 22),
          FilledButton(
            onPressed: _busy || _lines.isEmpty || _supplier.text.trim().isEmpty
                ? null
                : _commit,
            child: Text(context.t(_busy ? 'receive.saving' : 'receive.record')),
          ),
          const SizedBox(height: 10),
          Text(
            context.t('receive.savedHint'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: PharmaColors.faint, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _LineSheet extends StatefulWidget {
  const _LineSheet({required this.products});
  final List<LocalProduct> products;

  @override
  State<_LineSheet> createState() => _LineSheetState();
}

class _LineSheetState extends State<_LineSheet> {
  LocalProduct? _product;
  final _lot = TextEditingController();
  final _qty = TextEditingController();
  final _cost = TextEditingController();
  DateTime? _expiry;

  @override
  void dispose() {
    _lot.dispose();
    _qty.dispose();
    _cost.dispose();
    super.dispose();
  }

  bool get _valid =>
      _product != null &&
      _lot.text.trim().isNotEmpty &&
      _expiry != null &&
      (int.tryParse(_qty.text) ?? 0) > 0;

  @override
  Widget build(BuildContext context) {
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
          Text(context.t('receive.addLineTitle'),
              style:
                  const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(height: 14),
          DropdownButtonFormField<LocalProduct>(
            initialValue: _product,
            decoration:
                InputDecoration(labelText: context.t('receive.product')),
            items: widget.products
                .map((p) => DropdownMenuItem(value: p, child: Text(p.name)))
                .toList(),
            onChanged: (p) => setState(() => _product = p),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _lot,
            decoration: InputDecoration(labelText: context.t('receive.lotNo')),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.event_outlined),
            onPressed: () async {
              // Gregorian picker on purpose: the box and the wholesaler's paperwork print
              // Gregorian, and asking for a converted date invites a transcription error on
              // the one field where being wrong means selling expired medicine.
              final picked = await showDatePicker(
                context: context,
                firstDate: DateTime.now(),
                lastDate: DateTime.now().add(const Duration(days: 365 * 10)),
                initialDate: DateTime.now().add(const Duration(days: 365)),
              );
              if (picked != null) {
                setState(() => _expiry = picked);
              }
            },
            label: Text(_expiry == null
                ? context.t('receive.expiry')
                : '${_expiry!.toIso8601String().substring(0, 10)}'
                    '  ·  ${context.l10n.calendarDate(_expiry!.toIso8601String())}'),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _qty,
                  keyboardType: TextInputType.number,
                  decoration:
                      InputDecoration(labelText: context.t('receive.qty')),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _cost,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration:
                      InputDecoration(labelText: context.t('receive.unitCost')),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          FilledButton(
            onPressed: !_valid
                ? null
                : () {
                    final costBirr = double.tryParse(_cost.text.trim()) ?? 0;
                    Navigator.pop(
                      context,
                      ReceiptLine(
                        product: _product!,
                        lotNo: _lot.text.trim(),
                        expiryDate: _expiry!.toIso8601String().substring(0, 10),
                        qty: int.parse(_qty.text),
                        // Parsed once, at the edge, and immediately integral santim (G4).
                        costSantim: (costBirr * 100).round(),
                      ),
                    );
                  },
            child: Text(context.t('receive.addLine')),
          ),
        ],
      ),
    );
  }
}
