import 'dart:async';

import 'package:flutter/material.dart';

import '../core/money.dart';
import '../core/theme.dart';
import '../data/catalog_repository.dart';
import '../data/inventory_repository.dart';
import '../l10n/locale_store.dart';
import 'kit.dart';
import 'terminal.dart';

/// Goods receipt (prototype screen 14; FR-7 base).
///
/// Stock arrives when the wholesaler's van arrives — which in this market is not when the
/// network is up. Everything here commits locally and queues, exactly like a sale, and the
/// shelf count is credited immediately so the counter can sell what is physically there.
///
/// The expiry date is entered as a **Gregorian calendar date** — the box and the paperwork
/// print Gregorian — and shown in the Ethiopian calendar beside it (BR-10.2).
class ReceiveScreen extends StatefulWidget {
  const ReceiveScreen({super.key});

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> {
  final _supplier = TextEditingController();
  final List<ReceiptLine> _lines = [];
  List<LocalProduct>? _products;
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_products == null) {
      // Controlled items post a receipt *event* to the ledger instead of a mutable count
      // (ADR-004) — which arrives with the compliance phase, so they are not offered here.
      final t = TerminalScope.read(context);
      unawaited(t.catalog.products().then((p) {
        if (mounted) {
          // Controlled lines become ledger events on the server (ADR-004), so they are
          // offered only once the regulated half is live (ADR-024).
          setState(() => _products =
              p.where((x) => !x.isControlled || t.controlledEnabled).toList());
        }
      }));
    }
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
      builder: (_) => _LineSheet(products: _products ?? const []),
    );
    if (line != null && mounted) setState(() => _lines.add(line));
  }

  Future<void> _commit() async {
    final t = TerminalScope.read(context);
    setState(() => _busy = true);
    await t.inventory.commitReceipt(
      lines: List.of(_lines),
      supplierName: _supplier.text.trim(),
      branchId: t.branchId,
    );
    await t.refresh();
    unawaited(t.sync());
    if (!mounted) return;
    final done = context.tf('receive.done', {'count': _lines.length});
    Navigator.of(context).pop(true);
    toast(context, done);
  }

  int get _totalCost => _lines.fold(0, (sum, l) => sum + l.costSantim * l.qty);

  @override
  Widget build(BuildContext context) {
    final products = _products;
    return Scaffold(
      body: Column(children: [
        PTopBar(
          tone: BarTone.green,
          title: context.t('receive.title'),
          onBack: () => Navigator.of(context).pop(),
        ),
        Expanded(
          child: PBody(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
              children: [
                PField(
                  label: context.t('receive.supplier'),
                  hint: context.t('receive.supplierHint'),
                  controller: _supplier,
                  onChanged: (_) => setState(() {}),
                ),
                PSection(context.t('receive.items')),
                if (products != null && products.isEmpty)
                  PNotice.text(Tone.amber, Icons.info_outline,
                      context.t('receive.noProducts')),
                if (_lines.isNotEmpty)
                  PRows(children: [
                    for (final (i, line) in _lines.indexed)
                      PRow(
                        title: line.product.name,
                        subtitle:
                            '${context.t('stock.lot')} ${line.lotNo} · ${context.t('stock.exp')} ${context.l10n.calendarDate(line.expiryDate)}',
                        value: '×${line.qty}',
                        valueCaption:
                            '${formatMoney(line.costSantim)} ${context.t('receive.each')}',
                        trailing: IconButton(
                          tooltip: context.t('receive.remove'),
                          icon: const Icon(Icons.close,
                              size: 18, color: PharmaColors.faint),
                          onPressed: () => setState(() => _lines.removeAt(i)),
                        ),
                      ),
                  ]),
                const SizedBox(height: 12),
                PButton(
                  kind: BtnKind.plain,
                  small: true,
                  label: '＋ ${context.t('receive.addItem')}',
                  onPressed:
                      products == null || products.isEmpty ? null : _addLine,
                ),
                if (_lines.isNotEmpty)
                  PSummary(lines: const [], total: (
                    context.t('receive.totalCost'),
                    formatMoney(_totalCost)
                  )),
                const SizedBox(height: 14),
                PNotice.text(Tone.blue, Icons.info_outline,
                    context.t('receive.batchNotice')),
              ]),
        ),
        PFooter(
          child: PButton(
            label: context.t(_busy ? 'receive.saving' : 'receive.confirm'),
            onPressed: _busy || _lines.isEmpty || _supplier.text.trim().isEmpty
                ? null
                : _commit,
          ),
        ),
      ]),
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
      padding: EdgeInsets.fromLTRB(
          18, 20, 18, MediaQuery.of(context).viewInsets.bottom + 18),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(context.t('receive.addLineTitle'),
                style:
                    const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
            const SizedBox(height: 14),
            PField(
              label: context.t('receive.product'),
              child: DropdownButtonFormField<LocalProduct>(
                initialValue: _product,
                items: widget.products
                    .map((p) => DropdownMenuItem(value: p, child: Text(p.name)))
                    .toList(),
                onChanged: (p) => setState(() => _product = p),
              ),
            ),
            PField(
              label: context.t('receive.lotNo'),
              controller: _lot,
              onChanged: (_) => setState(() {}),
            ),
            PField(
              label: context.t('receive.expiry'),
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: PharmaColors.ink,
                  padding: const EdgeInsets.all(14),
                  alignment: Alignment.centerLeft,
                  side: const BorderSide(color: Color(0xFFE6ECE9)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                icon:
                    const Icon(Icons.event_outlined, color: PharmaColors.green),
                onPressed: () async {
                  // Gregorian picker on purpose: the box prints Gregorian, and a converted
                  // date invites a transcription error on the field where being wrong
                  // means selling expired medicine.
                  final picked = await showDatePicker(
                    context: context,
                    firstDate: DateTime.now(),
                    lastDate:
                        DateTime.now().add(const Duration(days: 365 * 10)),
                    initialDate: DateTime.now().add(const Duration(days: 365)),
                  );
                  if (picked != null) setState(() => _expiry = picked);
                },
                label: Text(_expiry == null
                    ? context.t('receive.expiryHint')
                    : '${_expiry!.toIso8601String().substring(0, 10)}'
                        '  ·  ${context.l10n.calendarDate(_expiry!.toIso8601String())}'),
              ),
            ),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: PField(
                  label: context.t('receive.qty'),
                  controller: _qty,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: PField(
                  label: context.t('receive.unitCost'),
                  controller: _cost,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                ),
              ),
            ]),
            PButton(
              label: context.t('receive.addLine'),
              onPressed: !_valid
                  ? null
                  : () => Navigator.pop(
                        context,
                        ReceiptLine(
                          product: _product!,
                          lotNo: _lot.text.trim(),
                          expiryDate:
                              _expiry!.toIso8601String().substring(0, 10),
                          qty: int.parse(_qty.text),
                          // Integral santim from the start (G4).
                          costSantim: parseBirr(_cost.text) ?? 0,
                        ),
                      ),
            ),
          ],
        ),
      ),
    );
  }
}
