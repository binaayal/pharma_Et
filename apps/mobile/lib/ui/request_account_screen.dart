import 'package:flutter/material.dart';

import '../api/tenant_api.dart';
import '../core/theme.dart';
import '../l10n/locale_store.dart';
import 'kit.dart';

/// Request an account (prototype screens 01 and 02; ADR-022).
///
/// Self-signup creates a **request**, not an account. Platform staff call the number, and
/// only then open the pharmacy — the anti-abuse gate.
class RequestAccountScreen extends StatefulWidget {
  const RequestAccountScreen({super.key, required this.api});
  final TenantApi api;

  @override
  State<RequestAccountScreen> createState() => _RequestAccountScreenState();
}

class _RequestAccountScreenState extends State<RequestAccountScreen> {
  final _pharmacy = TextEditingController();
  final _owner = TextEditingController();
  final _phone = TextEditingController();
  final _city = TextEditingController();
  String _band = '1';
  bool _busy = false;
  bool _sent = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_pharmacy, _owner, _phone, _city]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _valid =>
      _pharmacy.text.trim().length >= 2 &&
      _owner.text.trim().length >= 2 &&
      _phone.text.replaceAll(RegExp(r'\D'), '').length >= 9 &&
      _city.text.trim().length >= 2;

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.requestAccount(
        pharmacyName: _pharmacy.text.trim(),
        ownerName: _owner.text.trim(),
        phone: _phone.text.trim(),
        city: _city.text.trim(),
        branchBand: _band,
      );
      if (mounted) setState(() => _sent = true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = context.t('login.noConnection'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_sent) return _sentView(context);
    return Scaffold(
      body: Column(children: [
        PTopBar(
            title: context.t('request.title'),
            onBack: () => Navigator.of(context).pop()),
        Expanded(
          child: PBody(children: [
            PNotice.text(
                Tone.green, Icons.shield_outlined, context.t('request.notice')),
            PField(
                label: context.t('request.pharmacy'),
                hint: 'e.g. Ras Desta Pharmacy',
                controller: _pharmacy,
                onChanged: (_) => setState(() {})),
            PField(
                label: context.t('request.owner'),
                hint: 'e.g. Bina Ayalneh',
                controller: _owner,
                onChanged: (_) => setState(() {})),
            PField(
              label: context.t('request.phone'),
              hint: '+251 9__ __ __ __',
              helper: context.t('request.phoneHint'),
              controller: _phone,
              keyboardType: TextInputType.phone,
              onChanged: (_) => setState(() {}),
            ),
            PField(
                label: context.t('request.city'),
                hint: 'e.g. Addis Ababa',
                controller: _city,
                onChanged: (_) => setState(() {})),
            PField(
              label: context.t('request.branches'),
              child: PSegmented<String>(
                options: const [('1', '1'), ('2-3', '2–3'), ('4+', '4+')],
                value: _band,
                onChanged: (b) => setState(() => _band = b),
              ),
            ),
            if (_error != null)
              PNotice.text(Tone.red, Icons.error_outline, _error!),
          ]),
        ),
        PFooter(
          child: PButton(
            label: context.t(_busy ? 'request.sending' : 'request.send'),
            onPressed: _busy || !_valid ? null : _send,
          ),
        ),
      ]),
    );
  }

  Widget _sentView(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(34),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const PMark(icon: Icons.check_rounded, size: 74),
                const SizedBox(height: 18),
                Text(context.t('request.sentTitle'),
                    style: const TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3)),
                const SizedBox(height: 10),
                Text.rich(
                  TextSpan(children: [
                    TextSpan(text: '${context.t('request.sentBody')} '),
                    TextSpan(
                        text: _phone.text.trim(),
                        style: const TextStyle(
                            color: PharmaColors.ink,
                            fontWeight: FontWeight.w700)),
                    TextSpan(text: ' ${context.t('request.sentBody2')}'),
                  ]),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: PharmaColors.muted, fontSize: 13.5, height: 1.55),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: 260,
                  child: PButton(
                    kind: BtnKind.plain,
                    label: context.t('request.back'),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              ]),
            ),
          ),
        ),
      );
}
