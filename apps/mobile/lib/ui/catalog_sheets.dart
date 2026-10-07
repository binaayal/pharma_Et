import 'dart:async';

import 'package:flutter/material.dart';

import '../contracts/contracts.dart';
import '../core/money.dart';
import '../core/theme.dart';
import '../data/catalog_repository.dart';
import '../data/medicine_catalogue.dart';
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

/// A product's packs — strip of 10, box of 100, each with its own price (FR-11).
///
/// An online write behind `catalog.manage`, like a price: a pack carries a price, so it is
/// audited as one, and every terminal picks the change up on its next pull.
Future<bool> showPacksForm(BuildContext context, LocalProduct product) async {
  final t = TerminalScope.read(context);
  final done = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) =>
        TerminalScope(terminal: t, child: _PacksForm(product: product)),
  );
  return done == true;
}

/// The most packs one product may define. Mirrors the contract's `MAX_PACKS_PER_PRODUCT`.
const maxPacksPerProduct = 4;

/// The most base units one pack may hold. Mirrors the contract's `MAX_PACK_SIZE`.
const maxPackSize = 100000;

/// One pack being typed: its name, how many base units it holds, and what it sells for.
class PackDraft {
  PackDraft(
      {String name = '',
      String size = '',
      String price = '',
      String wholesale = ''})
      : name = TextEditingController(text: name),
        size = TextEditingController(text: size),
        price = TextEditingController(text: price),
        wholesale = TextEditingController(text: wholesale);

  factory PackDraft.of(ProductPack pack) => PackDraft(
      name: pack.name,
      size: '${pack.size}',
      price: formatMoney(pack.priceSantim),
      wholesale: pack.wholesalePriceSantim == null
          ? ''
          : formatMoney(pack.wholesalePriceSantim!));

  final TextEditingController name;
  final TextEditingController size;
  final TextEditingController price;

  /// What one sells for to a wholesale customer (FR-19). Optional: empty means the pack
  /// has one price.
  final TextEditingController wholesale;

  /// A row nobody has typed in is not a mistake; it is ignored.
  bool get isBlank =>
      name.text.trim().isEmpty &&
      size.text.trim().isEmpty &&
      price.text.trim().isEmpty;

  void dispose() {
    name.dispose();
    size.dispose();
    price.dispose();
    wholesale.dispose();
  }
}

/// Reads the typed rows into packs, or null if any row is not a pack yet.
///
/// The same rules the server applies (`productPacks` in the contract), checked here first so
/// the owner is told beside the field instead of by a refused request: a pack holds at
/// least two, has a price, and no two share a name or a size. Money goes through
/// [parseBirr], never a double (G4).
List<ProductPack>? readPacks(List<PackDraft> drafts) {
  final packs = <ProductPack>[];
  for (final draft in drafts) {
    if (draft.isBlank) continue;
    final name = draft.name.text.trim();
    final size = int.tryParse(draft.size.text.trim());
    final price = parseBirr(draft.price.text);
    if (name.isEmpty || name.length > 40) return null;
    if (size == null || size < 2 || size > maxPackSize) return null;
    if (price == null) return null;
    // Optional — but if something is typed, it has to be money. A wholesale price that
    // was meant and mistyped must not be saved as "none".
    final wholesaleText = draft.wholesale.text.trim();
    final wholesale = wholesaleText.isEmpty ? null : parseBirr(wholesaleText);
    if (wholesaleText.isNotEmpty && wholesale == null) return null;
    packs.add(ProductPack(
        name: name,
        size: size,
        priceSantim: price,
        wholesalePriceSantim: wholesale));
  }
  if (packs.length > maxPacksPerProduct) return null;
  if (packs.map((p) => p.name.toLowerCase()).toSet().length != packs.length) {
    return null;
  }
  if (packs.map((p) => p.size).toSet().length != packs.length) return null;
  return packs..sort((a, b) => a.size.compareTo(b.size));
}

/// The rows of the pack editor, shared by "add product" and "edit packs".
class PackRows extends StatelessWidget {
  const PackRows({
    super.key,
    required this.drafts,
    required this.unit,
    required this.onChanged,
    required this.onAdd,
    required this.onRemove,
  });

  final List<PackDraft> drafts;

  /// The product's base unit, so the size field can say "tablets in one".
  final String unit;
  final VoidCallback onChanged;
  final VoidCallback onAdd;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, draft) in drafts.indexed)
            // Two lines a pack. Four fields on one line fitted a 720-pixel phone only by
            // clipping the price ("900.0…"), found on a real handset — and a price is
            // the one figure here nobody should have to guess at.
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  flex: 3,
                  child: PField(
                    label: context.t('packs.name'),
                    hint: context.t('packs.nameHint'),
                    controller: draft.name,
                    onChanged: (_) => onChanged(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: PField(
                    label: context.t('packs.size'),
                    hint: '10 $unit',
                    controller: draft.size,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => onChanged(),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 22),
                  child: IconButton(
                    tooltip: context.t('packs.remove'),
                    icon: const Icon(Icons.close,
                        size: 18, color: PharmaColors.faint),
                    onPressed: () => onRemove(i),
                  ),
                ),
              ]),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: PField(
                    label: context.t('catalog.price'),
                    controller: draft.price,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => onChanged(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: PField(
                    // The price for a clinic or an organisation (FR-19). Left empty,
                    // the pack has one price for everybody.
                    label: context.t('tier.wholesaleShort'),
                    hint: '—',
                    controller: draft.wholesale,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => onChanged(),
                  ),
                ),
              ]),
              // Tells one pack from the next now that each is two lines tall.
              if (i < drafts.length - 1)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Divider(height: 1, color: PharmaColors.line),
                ),
            ]),
          if (drafts.length < maxPacksPerProduct)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: PButton(
                kind: BtnKind.plain,
                small: true,
                label: '＋ ${context.t('packs.add')}',
                onPressed: onAdd,
              ),
            ),
        ],
      );
}

class _PacksForm extends StatefulWidget {
  const _PacksForm({required this.product});
  final LocalProduct product;

  @override
  State<_PacksForm> createState() => _PacksFormState();
}

class _PacksFormState extends State<_PacksForm> {
  late final List<PackDraft> _drafts = [
    for (final pack in widget.product.packs) PackDraft.of(pack),
    if (widget.product.packs.isEmpty) PackDraft(),
  ];
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final draft in _drafts) {
      draft.dispose();
    }
    super.dispose();
  }

  bool _same(List<ProductPack> a, List<ProductPack> b) =>
      a.length == b.length &&
      [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);

  Future<void> _save(List<ProductPack> packs) async {
    final t = TerminalScope.read(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await t
          .authed((token) => t.api.setPacks(token, widget.product.id, packs));
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
    final p = widget.product;
    final packs = readPacks(_drafts);
    final changed = packs != null && !_same(packs, p.packs);
    return Padding(
      padding: EdgeInsets.fromLTRB(
          18, 20, 18, MediaQuery.of(context).viewInsets.bottom + 18),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(p.name,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text(
                '${formatEtb(p.priceSantim)} ${context.t('pos.perUnit')} ${p.unit}',
                style:
                    const TextStyle(color: PharmaColors.muted, fontSize: 13)),
            const SizedBox(height: 16),
            PackRows(
              drafts: _drafts,
              unit: p.unit,
              onChanged: () => setState(() {}),
              onAdd: () => setState(() => _drafts.add(PackDraft())),
              onRemove: (i) => setState(() => _drafts.removeAt(i).dispose()),
            ),
            PNotice.text(
                Tone.blue, Icons.inventory_2_outlined, context.t('packs.help')),
            if (packs == null)
              PNotice.text(
                  Tone.amber, Icons.info_outline, context.t('packs.invalid')),
            if (_error != null)
              PNotice.text(Tone.red, Icons.error_outline, _error!),
            PButton(
              label: context.t(_busy ? 'staff.adding' : 'packs.save'),
              onPressed: _busy || !changed ? null : () => _save(packs),
            ),
          ],
        ),
      ),
    );
  }
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
  final List<PackDraft> _packs = [];
  bool _controlled = false;
  bool _busy = false;
  String? _error;

  /// The bundled medicines list (FR-12). Empty until it loads, and empty if it cannot —
  /// in which case this is simply the form it always was.
  MedicineCatalogue _medicines = MedicineCatalogue.empty;

  /// Set when the name was filled from the list, so the suggestions step out of the way
  /// until the owner types in the name field again.
  String? _picked;

  /// How many products this sheet has added while staying open ("Add another").
  int _added = 0;

  @override
  void initState() {
    super.initState();
    final cached = MedicineCatalogue.cached;
    if (cached != null) {
      _medicines = cached;
    } else {
      unawaited(MedicineCatalogue.load().then((m) {
        if (mounted) setState(() => _medicines = m);
      }));
    }
  }

  /// Fills the form from the list: the name, and the unit one of them is counted in. The
  /// price is left for the owner — the list has none, and a guessed price is worse than
  /// an empty field.
  void _pick(MedicineEntry entry) => setState(() {
        _name.text = entry.name;
        _unit.text = entry.unit;
        _picked = entry.name;
      });

  @override
  void dispose() {
    _name.dispose();
    _unit.dispose();
    _price.dispose();
    for (final draft in _packs) {
      draft.dispose();
    }
    super.dispose();
  }

  bool get _valid =>
      _name.text.trim().isNotEmpty &&
      _unit.text.trim().isNotEmpty &&
      (parseBirr(_price.text) ?? 0) > 0 &&
      readPacks(_packs) != null;

  /// Saves the product. With [another], the sheet stays open and clears for the next one —
  /// stocking a new shop is the same four taps a few hundred times, and reopening the
  /// sheet for each would double them.
  Future<void> _save({bool another = false}) async {
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
          isControlled: _controlled,
          // A controlled substance is counted in its base unit only (ADR-030 §5).
          packs: _controlled ? const [] : readPacks(_packs)!));
      // Pull it down now, so the counter can sell it before the next tick.
      unawaited(t.sync());
      if (!mounted) return;
      if (!another) return Navigator.pop(context, true);
      setState(() {
        _added++;
        _busy = false;
        _picked = null;
        _name.clear();
        _price.clear();
        _unit.text = 'tablet';
        _controlled = false;
        for (final draft in _packs) {
          draft.dispose();
        }
        _packs.clear();
      });
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
    final t = TerminalScope.of(context);
    final suggestions = _picked != null && _picked == _name.text
        ? const <MedicineEntry>[]
        : _medicines.search(
            _name.text,
            // What this pharmacy already sells is not offered again.
            exclude: {for (final p in t.products) p.name.toLowerCase()},
          );
    return PopScope(
      canPop: _added == 0,
      // Closed by the back gesture after "Add another": still report that products were
      // added, so the stock list behind this sheet reloads.
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, true);
      },
      child: Padding(
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
              if (_added > 0)
                PNotice.text(Tone.green, Icons.check_circle_outline,
                    context.tf('catalog.addedCount', {'n': _added})),
              PField(
                label: context.t('catalog.name'),
                hint: context.t('catalog.nameHint'),
                controller: _name,
                autofocus: true,
                onChanged: (_) => setState(() => _picked = null),
              ),
              if (suggestions.isNotEmpty) ...[
                // The bundled medicines list (FR-12): three letters and a tap instead of
                // a typed name. Only a suggestion — typing on is always allowed.
                PRows(children: [
                  for (final entry in suggestions)
                    PRow(
                      title: entry.name,
                      // No heading underneath. The list files a medicine under the use
                      // it happened to be listed for — on a real phone that read
                      // "Paracetamol 500mg tablet · For Treatment of Acute Attack",
                      // which is true of migraine and misleading at a counter. The name
                      // already carries strength and form.
                      value: entry.unit,
                      onTap: () => _pick(entry),
                    ),
                ]),
                Padding(
                  padding: const EdgeInsets.only(top: 6, bottom: 14),
                  child: Text(context.t('catalog.fromList'),
                      style: const TextStyle(
                          fontSize: 11.5, color: PharmaColors.faint)),
                ),
              ],
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
                    context.t('catalog.controlledNotice'))
              else ...[
                PSection(context.t('packs.title')),
                PackRows(
                  drafts: _packs,
                  unit: _unit.text.trim().isEmpty ? '…' : _unit.text.trim(),
                  onChanged: () => setState(() {}),
                  onAdd: () => setState(() => _packs.add(PackDraft())),
                  onRemove: (i) => setState(() => _packs.removeAt(i).dispose()),
                ),
                if (readPacks(_packs) == null)
                  PNotice.text(Tone.amber, Icons.info_outline,
                      context.t('packs.invalid')),
              ],
              if (_error != null)
                PNotice.text(Tone.red, Icons.error_outline, _error!),
              PButton(
                label: context.t(_busy ? 'staff.adding' : 'catalog.add'),
                onPressed: _busy || !_valid ? null : _save,
              ),
              const SizedBox(height: 8),
              PButton(
                kind: BtnKind.plain,
                small: true,
                label: context.t('catalog.addAnother'),
                onPressed: _busy || !_valid ? null : () => _save(another: true),
              ),
            ],
          ),
        ),
      ),
    );
  }
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

  /// The price for a wholesale customer (FR-19). Empty means the product has one price.
  late final _wholesale = TextEditingController(
      text: widget.product.wholesalePriceSantim == null
          ? ''
          : formatMoney(widget.product.wholesalePriceSantim!));
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _price.dispose();
    _wholesale.dispose();
    super.dispose();
  }

  /// What the wholesale field says: (valid, price-or-null). Empty is valid and means none.
  (bool, int?) get _wholesaleTyped {
    final text = _wholesale.text.trim();
    if (text.isEmpty) return (true, null);
    final parsed = parseBirr(text);
    return (parsed != null, parsed);
  }

  Future<void> _save() async {
    final t = TerminalScope.read(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final retail = parseBirr(_price.text)!;
      final (_, wholesale) = _wholesaleTyped;
      // Two writes, each sent only if it changed: each is its own entry in the audit log,
      // and a price nobody touched should not appear there as changed.
      if (retail != widget.product.priceSantim) {
        await t.authed(
            (token) => t.api.setPrice(token, widget.product.id, retail));
      }
      if (wholesale != widget.product.wholesalePriceSantim) {
        await t.authed((token) =>
            t.api.setWholesalePrice(token, widget.product.id, wholesale));
      }
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
    final (wholesaleOk, wholesale) = _wholesaleTyped;
    final changed = next != null &&
        wholesaleOk &&
        (next != widget.product.priceSantim ||
            wholesale != widget.product.wholesalePriceSantim);
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
          if (!widget.product.isControlled)
            PField(
              label: context.t('tier.wholesalePrice'),
              helper: context.t('tier.wholesaleHint'),
              controller: _wholesale,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
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
