import 'dart:async';

import 'package:flutter/material.dart';

import '../core/money.dart';
import '../core/theme.dart';
import '../data/supplier_repository.dart';
import '../l10n/locale_store.dart';
import 'kit.dart';
import 'terminal.dart';

/// Suppliers and what is owed to them (FR-18, ADR-038).
///
/// The drawer of unpaid invoices, with the one thing the drawer cannot do: the total at the
/// top. Sorted by who is owed most, because the person opening this is deciding whom to pay.
class SuppliersScreen extends StatefulWidget {
  const SuppliersScreen({super.key});

  @override
  State<SuppliersScreen> createState() => _SuppliersScreenState();
}

class _SuppliersScreenState extends State<SuppliersScreen> {
  List<LocalSupplier>? _suppliers;
  int _revision = -1;

  Future<void> _load() async {
    final t = TerminalScope.read(context);
    final all = await t.suppliers.suppliers();
    if (mounted) setState(() => _suppliers = all);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Re-read after every sync or receipt: a pull may have brought a figure another phone
    // changed.
    final t = TerminalScope.of(context);
    if (t.revision != _revision) {
      _revision = t.revision;
      unawaited(_load());
    }
  }

  @override
  Widget build(BuildContext context) {
    final suppliers = _suppliers;
    final all = suppliers ?? const <LocalSupplier>[];
    final owed = all.fold<int>(
        0, (sum, s) => s.balanceSantim > 0 ? sum + s.balanceSantim : sum);
    final owedCount = all.where((s) => s.balanceSantim > 0).length;

    return Scaffold(
      body: Column(children: [
        PTopBar(
          title: context.t('supplier.title'),
          onBack: () => Navigator.of(context).pop(),
          trailing: [
            PIconButton(
              icon: Icons.add_business_outlined,
              tooltip: context.t('supplier.new'),
              onTap: () async {
                final created = await showSupplierForm(context);
                if (created != null) await _load();
              },
            ),
          ],
        ),
        Expanded(
          child: PBody(children: [
            PTiles(tiles: [
              PTile(
                label: context.t('supplier.totalOwed'),
                value: formatBirr(owed),
                unit: 'ETB',
                valueColor: owed > 0 ? PharmaColors.amber : null,
              ),
              PTile(
                  label: context.t('supplier.owedCount'), value: '$owedCount'),
            ]),
            const SizedBox(height: 14),
            if (suppliers != null && suppliers.isEmpty)
              PNotice.text(Tone.blue, Icons.local_shipping_outlined,
                  context.t('supplier.empty'))
            else if (suppliers != null)
              PRows(children: [
                for (final s in suppliers)
                  PRow(
                    avatar: s.name.characters.first.toUpperCase(),
                    avatarTone: s.balanceSantim > 0 ? Tone.amber : Tone.green,
                    title: s.name,
                    subtitle: [
                      if (s.phone != null) s.phone!,
                      if (s.pendingSantim != 0) context.t('credit.partQueued'),
                    ].join(' · '),
                    value: formatMoney(s.balanceSantim.abs()),
                    valueColor: s.balanceSantim > 0 ? PharmaColors.amber : null,
                    valueCaption: context.t(s.balanceSantim > 0
                        ? 'supplier.owed'
                        : s.balanceSantim < 0
                            ? 'supplier.ahead'
                            : 'credit.settled'),
                    chevron: true,
                    onTap: () async {
                      await Navigator.of(context).push(MaterialPageRoute<void>(
                          builder: (_) => SupplierScreen(supplierId: s.id)));
                      await _load();
                    },
                  ),
              ]),
          ]),
        ),
      ]),
    );
  }
}

/// One supplier: what is owed, paying them, and what this phone has recorded.
class SupplierScreen extends StatefulWidget {
  const SupplierScreen({super.key, required this.supplierId});
  final String supplierId;

  @override
  State<SupplierScreen> createState() => _SupplierScreenState();
}

class _SupplierScreenState extends State<SupplierScreen> {
  LocalSupplier? _supplier;
  List<PayableEntry> _history = const [];
  bool _loaded = false;

  Future<void> _load() async {
    final t = TerminalScope.read(context);
    final s = await t.suppliers.supplier(widget.supplierId);
    final h = await t.suppliers.history(widget.supplierId);
    if (mounted) {
      setState(() {
        _supplier = s;
        _history = h;
        _loaded = true;
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) unawaited(_load());
  }

  Future<void> _pay() async {
    final s = _supplier;
    if (s == null) return;
    final t = TerminalScope.read(context);
    final paid = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) =>
          TerminalScope(terminal: t, child: _PaymentSheet(supplier: s)),
    );
    if (paid == true) {
      await _load();
      await t.refresh();
      unawaited(t.sync());
    }
  }

  String _deliveryLine(BuildContext context, PayableEntry e) {
    final cost = e.costSantim ?? 0;
    if (e.amountSantim == 0) return context.t('supplier.deliveryPaid');
    if (e.amountSantim >= cost) return context.t('supplier.deliveryOwed');
    return context.t('supplier.deliveryPart');
  }

  @override
  Widget build(BuildContext context) {
    final t = TerminalScope.of(context);
    final s = _supplier;
    final balance = s?.balanceSantim ?? 0;
    return Scaffold(
      body: Column(children: [
        PTopBar(
            title: s?.name ?? context.t('supplier.title'),
            onBack: () => Navigator.of(context).pop()),
        Expanded(
          child: PBody(children: [
            if (s != null) ...[
              PTiles(tiles: [
                PTile(
                  label: context.t(balance < 0
                      ? 'supplier.aheadLabel'
                      : balance == 0
                          ? 'credit.settled'
                          : 'supplier.youOwe'),
                  value: formatMoney(balance.abs()),
                  unit: 'ETB',
                  valueColor: balance > 0 ? PharmaColors.amber : null,
                ),
                if (s.phone != null)
                  PTile(label: context.t('credit.phone'), value: s.phone!),
              ]),
              if (s.pendingSantim != 0)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  // Part of the figure has not reached the server, so another phone does
                  // not see it yet (ADR-012 §3).
                  child: PNotice.text(
                      Tone.amber,
                      Icons.schedule,
                      context.tf('credit.queuedNotice',
                          {'amount': formatMoney(s.pendingSantim.abs())}),
                      margin: EdgeInsets.zero),
                ),
              if (s.note != null)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: PNotice.text(
                      Tone.blue, Icons.sticky_note_2_outlined, s.note!,
                      margin: EdgeInsets.zero),
                ),
              PSection(context.t('credit.history')),
              if (_history.isEmpty)
                PNotice.text(Tone.blue, Icons.info_outline,
                    context.t('supplier.noHistory'),
                    margin: EdgeInsets.zero)
              else
                PRows(children: [
                  for (final e in _history)
                    PRow(
                      avatarIcon: e.isPayment
                          ? Icons.north_east
                          : Icons.local_shipping_outlined,
                      avatarTone: e.isPayment ? Tone.green : Tone.amber,
                      title: e.isPayment
                          ? context.t(e.fromTill
                              ? 'supplier.paidFromTill'
                              : 'supplier.paid')
                          : _deliveryLine(context, e),
                      subtitle: [
                        '${context.l10n.date(e.at)} ${context.l10n.time(e.at)}',
                        // What the delivery cost in all, beside what it left owing.
                        if (!e.isPayment && e.costSantim != null)
                          '${context.t('receive.totalCost')} ${formatMoney(e.costSantim!)}',
                        if (!e.synced) context.t('credit.notSynced'),
                      ].join(' · '),
                      value:
                          '${e.isPayment ? '−' : '+'}${formatMoney(e.amountSantim)}',
                      valueColor: e.isPayment ? PharmaColors.green : null,
                    ),
                ]),
              const SizedBox(height: 12),
              Text(context.t('credit.historyNote'),
                  style: const TextStyle(
                      fontSize: 11.5, color: PharmaColors.faint)),
            ],
          ]),
        ),
        // Offered to the owner and a branch manager only. A cashier sees what is owed —
        // they took the delivery — but paying it out is not theirs to do.
        if (t.canPaySuppliers)
          PFooter(
            child: PButton(
              icon: Icons.payments_outlined,
              label: context.t('supplier.pay'),
              onPressed: s == null ? null : _pay,
            ),
          ),
      ]),
    );
  }
}

/// Where a payment to a supplier came from. It decides whether a cash-up is told.
enum _Source { till, cash, other }

class _PaymentSheet extends StatefulWidget {
  const _PaymentSheet({required this.supplier});
  final LocalSupplier supplier;

  @override
  State<_PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends State<_PaymentSheet> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  _Source? _source;
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save(int amount, _Source source) async {
    final t = TerminalScope.read(context);
    setState(() => _busy = true);
    await t.suppliers.recordPayment(
      supplierId: widget.supplier.id,
      amountSantim: amount,
      branchId: t.branchId,
      paidBy: t.session.scope.userId,
      method: source == _Source.other ? 'other_recorded' : 'cash',
      // Only cash taken from the open till is tied to it: that cash has left the drawer,
      // and the cash-up must stop expecting it (BR-8.2).
      shiftId: source == _Source.till ? t.shift?.id : null,
      note: _note.text,
    );
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final t = TerminalScope.of(context);
    final s = widget.supplier;
    final tillOpen = t.shift != null;
    // No default that moves money out of a drawer: with a till open the choice is made on
    // purpose; with none, the till is not offered at all.
    final source = _source ?? (tillOpen ? null : _Source.cash);
    final amount = parseBirr(_amount.text);
    final valid = amount != null && amount > 0 && source != null;
    final after = s.balanceSantim - (amount ?? 0);
    return Padding(
      padding: EdgeInsets.fromLTRB(
          18, 20, 18, MediaQuery.of(context).viewInsets.bottom + 18),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(context.tf('supplier.payTo', {'name': s.name}),
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 14),
            PField(
              label: context.t('supplier.amount'),
              controller: _amount,
              hint: s.balanceSantim > 0 ? formatMoney(s.balanceSantim) : null,
              large: true,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => setState(() {}),
            ),
            Text(context.t('supplier.paidFrom'),
                style:
                    const TextStyle(fontSize: 12.5, color: PharmaColors.muted)),
            const SizedBox(height: 6),
            PRows(children: [
              if (tillOpen)
                _sourceRow(context, _Source.till, source,
                    Icons.point_of_sale_outlined, 'supplier.fromTill'),
              _sourceRow(context, _Source.cash, source, Icons.payments_outlined,
                  'supplier.fromCash'),
              _sourceRow(context, _Source.other, source,
                  Icons.account_balance_outlined, 'supplier.fromOther'),
            ]),
            if (source == _Source.till)
              PNotice.text(Tone.amber, Icons.point_of_sale_outlined,
                  context.t('supplier.tillNotice'),
                  margin: const EdgeInsets.only(top: 14)),
            const SizedBox(height: 14),
            PField(
              label: context.t('supplier.noteOptional'),
              hint: context.t('supplier.noteHint'),
              controller: _note,
            ),
            PSummary(
              margin: false,
              lines: [
                (context.t('supplier.owedNow'), formatMoney(s.balanceSantim)),
              ],
              total: (
                context.t(
                    after < 0 ? 'supplier.aheadAfter' : 'supplier.owedAfter'),
                amount != null && amount > 0 ? formatMoney(after.abs()) : '—'
              ),
            ),
            const SizedBox(height: 14),
            PButton(
              label: context.t(_busy ? 'pay.saving' : 'supplier.recordPayment'),
              onPressed: _busy || !valid ? null : () => _save(amount, source),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sourceRow(BuildContext context, _Source value, _Source? selected,
          IconData icon, String key) =>
      PRow(
        avatarIcon: icon,
        avatarTone: value == selected ? Tone.green : Tone.blue,
        title: context.t(key),
        trailing: Icon(
            value == selected
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked,
            color: value == selected ? PharmaColors.green : PharmaColors.faint),
        onTap: () => setState(() => _source = value),
      );
}

/// Opens a new supplier. Returns them, or null if cancelled.
Future<LocalSupplier?> showSupplierForm(BuildContext context) {
  final t = TerminalScope.read(context);
  return showModalBottomSheet<LocalSupplier>(
    context: context,
    isScrollControlled: true,
    builder: (_) => TerminalScope(terminal: t, child: const _SupplierForm()),
  );
}

class _SupplierForm extends StatefulWidget {
  const _SupplierForm();

  @override
  State<_SupplierForm> createState() => _SupplierFormState();
}

class _SupplierFormState extends State<_SupplierForm> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _note = TextEditingController();
  bool _busy = false;
  bool _exists = false;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final t = TerminalScope.read(context);
    setState(() {
      _busy = true;
      _exists = false;
    });
    // One supplier, one account: a second "EPSS" would be owed separately and paid
    // separately, and neither figure would be the one on the invoice.
    if (await t.suppliers.byName(_name.text) != null) {
      if (mounted) {
        setState(() {
          _busy = false;
          _exists = true;
        });
      }
      return;
    }
    final created = await t.suppliers
        .create(name: _name.text, phone: _phone.text, note: _note.text);
    unawaited(t.sync());
    if (mounted) Navigator.pop(context, created);
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
              Text(context.t('supplier.new'),
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 14),
              PField(
                label: context.t('credit.name'),
                hint: context.t('receive.supplierHint'),
                controller: _name,
                autofocus: true,
                onChanged: (_) => setState(() => _exists = false),
              ),
              PField(
                label: context.t('credit.phoneOptional'),
                controller: _phone,
                keyboardType: TextInputType.phone,
              ),
              PField(
                label: context.t('credit.noteOptional'),
                hint: context.t('supplier.termsHint'),
                controller: _note,
              ),
              if (_exists)
                PNotice.text(Tone.amber, Icons.info_outline,
                    context.t('supplier.exists')),
              PButton(
                label: context.t(_busy ? 'pay.saving' : 'supplier.save'),
                onPressed: _busy || _name.text.trim().isEmpty ? null : _save,
              ),
            ],
          ),
        ),
      );
}
