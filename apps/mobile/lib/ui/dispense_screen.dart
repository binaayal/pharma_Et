import 'dart:async';

import 'package:flutter/material.dart';

import '../core/compliance.dart';
import '../core/money.dart';
import '../core/theme.dart';
import '../data/catalog_repository.dart';
import '../data/controlled_repository.dart';
import '../l10n/locale_store.dart';
import 'kit.dart';
import 'terminal.dart';

/// Controlled dispense (prototype screen 11; FR-4 §4a–4b, FR-6; ADR-024).
///
/// The rules run here, on the device, so they hold offline; the server checks them again.
/// BR-4.2 — a violation is **blocked**, not warned: the button does not exist until every
/// rule is satisfied, and the reason is on screen in red. The dispense is a sale and a ledger
/// event in one local transaction.
class DispenseScreen extends StatefulWidget {
  const DispenseScreen({super.key, required this.product});
  final LocalProduct product;

  @override
  State<DispenseScreen> createState() => _DispenseScreenState();
}

class _DispenseScreenState extends State<DispenseScreen> {
  final _rx = TextEditingController();
  final _prescriber = TextEditingController();
  DateTime? _issued;
  int _qty = 1;
  DispenseBlocked? _block;
  int? _daysUsed;
  bool _busy = false;

  @override
  void dispose() {
    _rx.dispose();
    _prescriber.dispose();
    super.dispose();
  }

  String? get _issuedIso => _issued == null
      ? null
      : '${_issued!.year.toString().padLeft(4, '0')}-${_issued!.month.toString().padLeft(2, '0')}-${_issued!.day.toString().padLeft(2, '0')}';

  /// Re-runs the rules whenever an input changes, so the verdict is always current.
  Future<void> _check() async {
    final t = TerminalScope.read(context);
    if (_issuedIso == null || _rx.text.trim().isEmpty) {
      setState(() {
        _block = null;
        _daysUsed = null;
      });
      return;
    }
    try {
      final r = await t.controlled.check(
          product: widget.product,
          prescriptionNo: _rx.text,
          issuedOn: _issuedIso!);
      if (mounted) {
        setState(() {
          _block = null;
          _daysUsed = r.daysUsed;
        });
      }
    } on DispenseBlocked catch (b) {
      if (mounted) {
        setState(() {
          _block = b;
          _daysUsed = b.daysUsed;
        });
      }
    }
  }

  bool get _ready =>
      _block == null &&
      _daysUsed != null &&
      _prescriber.text.trim().isNotEmpty &&
      _qty > 0;

  Future<void> _dispense() async {
    final t = TerminalScope.read(context);
    setState(() => _busy = true);
    try {
      await t.controlled.dispense(
        product: widget.product,
        qty: _qty,
        prescriptionNo: _rx.text,
        prescriber: _prescriber.text,
        issuedOn: _issuedIso!,
        branchId: t.branchId,
        cashierId: t.session.scope.userId,
        shiftId: t.shift?.id,
      );
      await t.refresh();
      unawaited(t.sync());
      if (!mounted) return;
      Navigator.of(context).pop();
      toast(context,
          '${context.t('dispense.recorded')} · ${widget.product.name} ×$_qty');
    } on DispenseBlocked catch (b) {
      if (mounted) setState(() => _block = b);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    final total = lineTotalSantim(qty: _qty, unitPriceSantim: p.priceSantim);
    return Scaffold(
      body: Column(children: [
        PTopBar(
          tone: BarTone.red,
          title: context.t('dispense.title'),
          subtitle: context.t('dispense.subtitle'),
          onBack: () => Navigator.of(context).pop(),
        ),
        Expanded(
          child: PBody(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
              children: [
                PNotice(
                  tone: Tone.red,
                  icon: Icons.warning_amber_rounded,
                  child: Text.rich(TextSpan(children: [
                    TextSpan(
                        text: p.name,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    TextSpan(text: ' ${context.t('dispense.isPsychotropic')}'),
                  ])),
                ),
                PField(
                  label: context.t('dispense.rxNumber'),
                  hint: 'RX-PSY-00417',
                  controller: _rx,
                  onChanged: (_) => unawaited(_check()),
                ),
                PField(
                  label: context.t('dispense.prescriber'),
                  hint: 'Dr. Almaz Tesfaye',
                  controller: _prescriber,
                  onChanged: (_) => setState(() {}),
                ),
                PField(
                  label: context.t('dispense.issued'),
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
                    icon: const Icon(Icons.event_outlined,
                        color: PharmaColors.red),
                    onPressed: () async {
                      final now = DateTime.now();
                      final picked = await showDatePicker(
                        context: context,
                        firstDate: now.subtract(const Duration(days: 365)),
                        lastDate: now,
                        initialDate: now,
                      );
                      if (picked != null) {
                        setState(() => _issued = picked);
                        unawaited(_check());
                      }
                    },
                    label: Text(_issuedIso == null
                        ? context.t('dispense.issuedHint')
                        : '$_issuedIso  ·  ${context.l10n.calendarDate(_issuedIso!)}'),
                  ),
                ),
                PField(
                  label: context.t('receive.qty'),
                  child: Row(children: [
                    IconButton.filledTonal(
                      onPressed: _qty > 1 ? () => setState(() => _qty--) : null,
                      icon: const Icon(Icons.remove),
                    ),
                    SizedBox(
                      width: 56,
                      child: Text('$_qty',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 20, fontWeight: FontWeight.w800)),
                    ),
                    IconButton.filledTonal(
                      onPressed: () => setState(() => _qty++),
                      icon: const Icon(Icons.add),
                    ),
                    const Spacer(),
                    Text(formatEtbShort(total),
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w800)),
                  ]),
                ),
                if (_block == null && _daysUsed != null)
                  PNotice(
                    tone: Tone.green,
                    icon: Icons.check_rounded,
                    child: Text.rich(TextSpan(children: [
                      TextSpan(text: '${context.t('dispense.validOk')} — '),
                      TextSpan(
                          text: context.tf('dispense.daysUsed', {
                            'used': _daysUsed!,
                            'of': PsychotropicRules.psychotropicValidityDays,
                          }),
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      TextSpan(
                          text: ' (${context.tf('dispense.limit', {
                            'days': PsychotropicRules.psychotropicValidityDays
                          })}).'),
                    ])),
                  ),
                if (_block != null)
                  PNotice(
                    tone: Tone.red,
                    icon: Icons.block,
                    child: Text.rich(TextSpan(children: [
                      TextSpan(
                          text: '${context.t('dispense.blocked')} ',
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      TextSpan(
                        text: switch (_block!.reason) {
                          DispenseBlock.expired =>
                            context.tf('dispense.expired', {
                              'used': _block!.daysUsed ?? 0,
                              'days':
                                  PsychotropicRules.psychotropicValidityDays,
                            }),
                          DispenseBlock.notYetValid =>
                            context.t('dispense.future'),
                          DispenseBlock.anotherPsychotropic =>
                            context.t('dispense.onePerRx'),
                          DispenseBlock.noPrescriptionNumber =>
                            context.t('dispense.needNumber'),
                        },
                      ),
                    ])),
                  ),
                PNotice.text(Tone.amber, Icons.gavel_outlined,
                    context.t('dispense.provisional'),
                    margin: EdgeInsets.zero),
              ]),
        ),
        PFooter(
          child: PButton(
            kind: BtnKind.warn,
            label: context.t(_busy ? 'pay.saving' : 'dispense.record'),
            onPressed: _busy || !_ready ? null : _dispense,
          ),
        ),
      ]),
    );
  }
}
