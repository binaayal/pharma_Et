import 'dart:async';

import 'package:flutter/material.dart';

import '../core/money.dart';
import '../core/theme.dart';
import '../data/catalog_repository.dart';
import '../l10n/locale_store.dart';
import 'kit.dart';
import 'terminal.dart';

/// Catalog management on the phone (FR-3, `catalog.manage`).
///
/// The prototype has no screen for it, but a pharmacy whose owner cannot add a product or
/// change a price cannot trade — and since the web is the platform's console, the phone is
/// the only place left to do it. Both are online writes: the server owns the catalog, and
/// every terminal picks the change up on its next pull.
Future<bool> showProductForm(BuildContext context) async {
  final t = TerminalScope.read(context);
  final done = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => TerminalScope(terminal: t, child: const _ProductForm()),
  );
  return done == true;
}

Future<bool> showPriceForm(BuildContext context, LocalProduct product) async {
  final t = TerminalScope.read(context);
  final done = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) =>
        TerminalScope(terminal: t, child: _PriceForm(product: product)),
  );
  return done == true;
}

class _ProductForm extends StatefulWidget {
  const _ProductForm();

  @override
  State<_ProductForm> createState() => _ProductFormState();
}

class _ProductFormState extends State<_ProductForm> {
  final _name = TextEditingController();
  final _unit = TextEditingController(text: 'tablet');
  final _price = TextEditingController();
  bool _controlled = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _unit.dispose();
    _price.dispose();
    super.dispose();
  }

  bool get _valid =>
      _name.text.trim().isNotEmpty &&
      _unit.text.trim().isNotEmpty &&
      (parseBirr(_price.text) ?? 0) > 0;

  Future<void> _save() async {
    final t = TerminalScope.read(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await t.authed((token) => t.api.createProduct(token,
          name: _name.text.trim(),
          unit: _unit.text.trim(),
          priceSantim: parseBirr(_price.text)!,
          isControlled: _controlled));
      // Pull it down now, so the counter can sell it before the next tick.
      unawaited(t.sync());
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(
            18, 20, 18, MediaQuery.of(context).viewInsets.bottom + 18),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(context.t('catalog.addTitle'),
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 14),
              PField(
                label: context.t('catalog.name'),
                hint: 'e.g. Amoxicillin 500mg',
                controller: _name,
                autofocus: true,
                onChanged: (_) => setState(() {}),
              ),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: PField(
                    label: context.t('catalog.unit'),
                    helper: context.t('catalog.unitHint'),
                    controller: _unit,
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: PField(
                    label: context.t('catalog.price'),
                    controller: _price,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ]),
              PField(
                label: context.t('stock.controlled'),
                child: PSegmented<bool>(
                  options: [
                    (false, context.t('catalog.standard')),
                    (true, context.t('catalog.psychotropic')),
                  ],
                  value: _controlled,
                  onChanged: (v) => setState(() => _controlled = v),
                ),
              ),
              if (_controlled)
                PNotice.text(Tone.blue, Icons.lock_outline,
                    context.t('catalog.controlledNotice')),
              if (_error != null)
                PNotice.text(Tone.red, Icons.error_outline, _error!),
              PButton(
                label: context.t(_busy ? 'staff.adding' : 'catalog.add'),
                onPressed: _busy || !_valid ? null : _save,
              ),
            ],
          ),
        ),
      );
}

class _PriceForm extends StatefulWidget {
  const _PriceForm({required this.product});
  final LocalProduct product;

  @override
  State<_PriceForm> createState() => _PriceFormState();
}

class _PriceFormState extends State<_PriceForm> {
  late final _price =
      TextEditingController(text: formatMoney(widget.product.priceSantim));
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _price.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final t = TerminalScope.read(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await t.authed((token) =>
          t.api.setPrice(token, widget.product.id, parseBirr(_price.text)!));
      unawaited(t.sync());
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final next = parseBirr(_price.text);
    final changed = next != null && next != widget.product.priceSantim;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          18, 20, 18, MediaQuery.of(context).viewInsets.bottom + 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.product.name,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(
              '${context.t('catalog.now')} ${formatEtb(widget.product.priceSantim)} ${context.t('pos.perUnit')} ${widget.product.unit}',
              style: const TextStyle(color: PharmaColors.muted, fontSize: 13)),
          const SizedBox(height: 16),
          PField(
            label: context.t('catalog.newPrice'),
            controller: _price,
            autofocus: true,
            large: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
          ),
          PNotice.text(
              Tone.blue, Icons.history, context.t('catalog.priceAudited')),
          if (_error != null)
            PNotice.text(Tone.red, Icons.error_outline, _error!),
          PButton(
            label: context.t(_busy ? 'staff.adding' : 'catalog.savePrice'),
            onPressed: _busy || !changed ? null : _save,
          ),
        ],
      ),
    );
  }
}
