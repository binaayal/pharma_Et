import 'dart:async';

import 'package:flutter/material.dart';

import '../core/money.dart';
import '../core/theme.dart';
import '../data/customer_repository.dart';
import '../l10n/locale_store.dart';
import 'kit.dart';
import 'terminal.dart';

/// Customers and what they owe — ዕዳ (FR-16, ADR-034).
///
/// The paper credit book, with the one thing the paper cannot do: the total at the top.
/// Sorted by who owes most, because the person opening this screen is deciding whom to ask.
class CustomersScreen extends StatefulWidget {
  const CustomersScreen({super.key});

  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  List<LocalCustomer>? _customers;
  int _revision = -1;

  Future<void> _load() async {
    final t = TerminalScope.read(context);
    final all = await t.customers.customers();
    if (mounted) setState(() => _customers = all);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Re-read after every sync or sale: a pull may have brought a balance another phone
    // changed.
    final t = TerminalScope.of(context);
    if (t.revision != _revision) {
      _revision = t.revision;
      unawaited(_load());
    }
  }

  @override
  Widget build(BuildContext context) {
    final customers = _customers;
    final owed = (customers ?? const <LocalCustomer>[]).fold<int>(
        0, (sum, c) => c.balanceSantim > 0 ? sum + c.balanceSantim : sum);
    final owing = (customers ?? const <LocalCustomer>[])
        .where((c) => c.balanceSantim > 0)
        .length;

    return Scaffold(
      body: Column(children: [
        PTopBar(
          title: context.t('credit.title'),
          onBack: () => Navigator.of(context).pop(),
          trailing: [
            PIconButton(
              icon: Icons.person_add_alt,
              tooltip: context.t('credit.newCustomer'),
              onTap: () async {
                final created = await showCustomerForm(context);
                if (created != null) await _load();
              },
            ),
          ],
        ),
        Expanded(
          child: PBody(children: [
            PTiles(tiles: [
              PTile(
                label: context.t('credit.totalOwed'),
                value: formatBirr(owed),
                unit: 'ETB',
                valueColor: owed > 0 ? PharmaColors.amber : null,
              ),
              PTile(label: context.t('credit.owing'), value: '$owing'),
            ]),
            const SizedBox(height: 14),
            if (customers != null && customers.isEmpty)
              PNotice.text(Tone.blue, Icons.menu_book_outlined,
                  context.t('credit.empty'))
            else if (customers != null)
              PRows(children: [
                for (final c in customers)
                  PRow(
                    avatar: c.name.characters.first.toUpperCase(),
                    avatarTone: c.balanceSantim > 0 ? Tone.amber : Tone.green,
                    title: c.name,
                    subtitle: [
                      if (c.phone != null) c.phone!,
                      if (c.pendingSantim != 0) context.t('credit.partQueued'),
                    ].join(' · '),
                    value: formatMoney(c.balanceSantim.abs()),
                    valueColor: c.balanceSantim > 0 ? PharmaColors.amber : null,
                    valueCaption: context.t(c.balanceSantim > 0
                        ? 'credit.owes'
                        : c.balanceSantim < 0
                            ? 'credit.ahead'
                            : 'credit.settled'),
                    chevron: true,
                    onTap: () async {
                      await Navigator.of(context).push(MaterialPageRoute<void>(
                          builder: (_) => CustomerScreen(customerId: c.id)));
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

/// One customer: what they owe, taking a payment, and what this phone has recorded.
class CustomerScreen extends StatefulWidget {
  const CustomerScreen({super.key, required this.customerId});
  final String customerId;

  @override
  State<CustomerScreen> createState() => _CustomerScreenState();
}

class _CustomerScreenState extends State<CustomerScreen> {
  LocalCustomer? _customer;
  List<CreditEntry> _history = const [];
  bool _loaded = false;

  Future<void> _load() async {
    final t = TerminalScope.read(context);
    final c = await t.customers.customer(widget.customerId);
    final h = await t.customers.history(widget.customerId);
    if (mounted) {
      setState(() {
        _customer = c;
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

  Future<void> _takePayment() async {
    final c = _customer;
    if (c == null) return;
    final t = TerminalScope.read(context);
    final taken = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) =>
          TerminalScope(terminal: t, child: _PaymentSheet(customer: c)),
    );
    if (taken == true) {
      await _load();
      await t.refresh();
      unawaited(t.sync());
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = TerminalScope.of(context);
    final c = _customer;
    final balance = c?.balanceSantim ?? 0;
    return Scaffold(
      body: Column(children: [
        PTopBar(
            title: c?.name ?? context.t('credit.title'),
            onBack: () => Navigator.of(context).pop()),
        Expanded(
          child: PBody(children: [
            if (c != null) ...[
              PTiles(tiles: [
                PTile(
                  label: context.t(balance < 0
                      ? 'credit.ahead'
                      : balance == 0
                          ? 'credit.settled'
                          : 'credit.owes'),
                  value: formatMoney(balance.abs()),
                  unit: 'ETB',
                  valueColor: balance > 0 ? PharmaColors.amber : null,
                ),
                if (c.phone != null)
                  PTile(label: context.t('credit.phone'), value: c.phone!),
              ]),
              if (c.pendingSantim != 0)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  // The honest caveat on the number: part of it has not reached the
                  // server, so another phone does not see it yet (ADR-012 §3).
                  child: PNotice.text(
                      Tone.amber,
                      Icons.schedule,
                      context.tf('credit.queuedNotice',
                          {'amount': formatMoney(c.pendingSantim.abs())}),
                      margin: EdgeInsets.zero),
                ),
              if (c.note != null)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: PNotice.text(
                      Tone.blue, Icons.sticky_note_2_outlined, c.note!,
                      margin: EdgeInsets.zero),
                ),
              PSection(context.t('credit.history')),
              if (_history.isEmpty)
                PNotice.text(Tone.blue, Icons.info_outline,
                    context.t('credit.noHistory'),
                    margin: EdgeInsets.zero)
              else
                PRows(children: [
                  for (final e in _history)
                    PRow(
                      avatarIcon: e.isPayment
                          ? Icons.south_west
                          : Icons.shopping_bag_outlined,
                      avatarTone: e.isPayment ? Tone.green : Tone.amber,
                      title: context.t(e.isPayment
                          ? 'credit.paid'
                          : 'credit.boughtOnCredit'),
                      subtitle: [
                        '${context.l10n.date(e.at)} ${context.l10n.time(e.at)}',
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
        PFooter(
          child: PButton(
            icon: Icons.payments_outlined,
            label: context.t('credit.takePayment'),
            onPressed: c == null || !t.canTakeCredit ? null : _takePayment,
          ),
        ),
      ]),
    );
  }
}

class _PaymentSheet extends StatefulWidget {
  const _PaymentSheet({required this.customer});
  final LocalCustomer customer;

  @override
  State<_PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends State<_PaymentSheet> {
  final _amount = TextEditingController();
  String _method = 'cash';
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save(int amount) async {
    final t = TerminalScope.read(context);
    setState(() => _busy = true);
    await t.customers.recordPayment(
      customerId: widget.customer.id,
      amountSantim: amount,
      branchId: t.branchId,
      receivedBy: t.session.scope.userId,
      method: _method,
      // Cash goes into the open till, so its cash-up expects it (BR-8.2). No till open:
      // still recorded — a repayment is never turned away for want of a shift.
      shiftId: t.shift?.id,
    );
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final t = TerminalScope.of(context);
    final c = widget.customer;
    final amount = parseBirr(_amount.text);
    final valid = amount != null && amount > 0;
    final after = c.balanceSantim - (amount ?? 0);
    return Padding(
      padding: EdgeInsets.fromLTRB(
          18, 20, 18, MediaQuery.of(context).viewInsets.bottom + 18),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(context.tf('credit.payFrom', {'name': c.name}),
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 14),
            PField(
              label: context.t('credit.amount'),
              controller: _amount,
              hint: c.balanceSantim > 0 ? formatMoney(c.balanceSantim) : null,
              large: true,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => setState(() {}),
            ),
            PSegmented<String>(
              options: [
                ('cash', context.t('pay.cash')),
                ('other_recorded', context.t('pay.other')),
              ],
              value: _method,
              onChanged: (v) => setState(() => _method = v),
            ),
            PSummary(
              margin: false,
              lines: [
                (context.t('credit.owesNow'), formatMoney(c.balanceSantim)),
              ],
              total: (
                context.t(after < 0 ? 'credit.aheadAfter' : 'credit.owesAfter'),
                valid ? formatMoney(after.abs()) : '—'
              ),
            ),
            if (_method == 'cash' && t.shift == null)
              PNotice.text(Tone.amber, Icons.point_of_sale_outlined,
                  context.t('credit.noTill'),
                  margin: const EdgeInsets.only(top: 14)),
            const SizedBox(height: 14),
            PButton(
              label: context.t(_busy ? 'pay.saving' : 'credit.recordPayment'),
              onPressed: _busy || !valid ? null : () => _save(amount),
            ),
          ],
        ),
      ),
    );
  }
}

/// Opens an account for a new customer. Returns them, or null if cancelled.
Future<LocalCustomer?> showCustomerForm(BuildContext context) {
  final t = TerminalScope.read(context);
  return showModalBottomSheet<LocalCustomer>(
    context: context,
    isScrollControlled: true,
    builder: (_) => TerminalScope(terminal: t, child: const _CustomerForm()),
  );
}

class _CustomerForm extends StatefulWidget {
  const _CustomerForm();

  @override
  State<_CustomerForm> createState() => _CustomerFormState();
}

class _CustomerFormState extends State<_CustomerForm> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _note = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final t = TerminalScope.read(context);
    setState(() => _busy = true);
    final created = await t.customers
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
              Text(context.t('credit.newCustomer'),
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 14),
              PField(
                label: context.t('credit.name'),
                hint: context.t('credit.nameHint'),
                controller: _name,
                autofocus: true,
                onChanged: (_) => setState(() {}),
              ),
              PField(
                label: context.t('credit.phoneOptional'),
                controller: _phone,
                keyboardType: TextInputType.phone,
              ),
              PField(
                label: context.t('credit.noteOptional'),
                hint: context.t('credit.noteHint'),
                controller: _note,
              ),
              PNotice.text(Tone.blue, Icons.shield_outlined,
                  context.t('credit.privacy')),
              PButton(
                label: context.t(_busy ? 'pay.saving' : 'credit.saveCustomer'),
                onPressed: _busy || _name.text.trim().isEmpty ? null : _save,
              ),
            ],
          ),
        ),
      );
}

/// Picks who a credit sale is for: search the customers this phone knows, or open a new
/// account without leaving the sale. Returns null if dismissed.
Future<LocalCustomer?> pickCustomer(BuildContext context) {
  final t = TerminalScope.read(context);
  return showModalBottomSheet<LocalCustomer>(
    context: context,
    isScrollControlled: true,
    builder: (_) => TerminalScope(terminal: t, child: const _CustomerPicker()),
  );
}

class _CustomerPicker extends StatefulWidget {
  const _CustomerPicker();

  @override
  State<_CustomerPicker> createState() => _CustomerPickerState();
}

class _CustomerPickerState extends State<_CustomerPicker> {
  final _search = TextEditingController();
  List<LocalCustomer>? _all;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_all == null) {
      unawaited(TerminalScope.read(context).customers.customers().then((all) {
        if (mounted) setState(() => _all = all);
      }));
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _search.text.trim().toLowerCase();
    final matches = (_all ?? const <LocalCustomer>[])
        .where((c) =>
            q.isEmpty ||
            c.name.toLowerCase().contains(q) ||
            (c.phone ?? '').contains(q))
        .take(8)
        .toList();
    return Padding(
      padding: EdgeInsets.fromLTRB(
          18, 20, 18, MediaQuery.of(context).viewInsets.bottom + 18),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(context.t('credit.whoOwes'),
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 14),
            PField(
              label: context.t('credit.search'),
              controller: _search,
              onChanged: (_) => setState(() {}),
            ),
            if (matches.isNotEmpty)
              PRows(children: [
                for (final c in matches)
                  PRow(
                    avatar: c.name.characters.first.toUpperCase(),
                    avatarTone: c.balanceSantim > 0 ? Tone.amber : Tone.green,
                    title: c.name,
                    subtitle: c.phone,
                    value: c.balanceSantim == 0
                        ? null
                        : formatMoney(c.balanceSantim.abs()),
                    valueCaption: c.balanceSantim > 0
                        ? context.t('credit.owes')
                        : c.balanceSantim < 0
                            ? context.t('credit.ahead')
                            : null,
                    onTap: () => Navigator.pop(context, c),
                  ),
              ]),
            const SizedBox(height: 12),
            PButton(
              kind: BtnKind.plain,
              small: true,
              icon: Icons.person_add_alt,
              label: context.t('credit.newCustomer'),
              onPressed: () async {
                final created = await showCustomerForm(context);
                if (created != null && context.mounted) {
                  Navigator.pop(context, created);
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}
