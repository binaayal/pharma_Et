import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../core/money.dart';
import '../core/theme.dart';
import '../l10n/locale_store.dart';
import 'kit.dart';
import 'terminal.dart';

/// Subscription ended (prototype screen 04; BR-1.3, ADR-016).
///
/// The prototype's lock screen, with one deliberate difference: it does not lock the till.
/// ADR-016 and NFR-1.2 are binding — suspension blocks management changes, never a sale,
/// never a queued record reaching the server — so "Continue to the till" is always there.
/// "Your data is safe" is only true if the pharmacy can keep recording it.
class SubscriptionEndedScreen extends StatelessWidget {
  const SubscriptionEndedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = TerminalScope.of(context);
    final reason = t.subscription?.suspendedReason;
    return Scaffold(
      body: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFFFFF3F0), Color(0xFFFDEBE8)]),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(34),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const PMark(icon: Icons.lock_outline, size: 74, warn: true),
                const SizedBox(height: 20),
                Text(context.t('sub.endedTitle'),
                    style: const TextStyle(
                        fontSize: 20,
                        color: PharmaColors.red,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3)),
                const SizedBox(height: 9),
                Text(context.t('sub.endedBody'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 13.5,
                        color: Color(0xFF7A3128),
                        height: 1.55)),
                if (reason != null) ...[
                  const SizedBox(height: 10),
                  Text('“$reason”',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 13,
                          color: Color(0xFF7A3128),
                          fontStyle: FontStyle.italic)),
                ],
                const SizedBox(height: 24),
                SizedBox(
                  width: 250,
                  child: PButton(
                    kind: BtnKind.warn,
                    label: context.t('sub.submitProof'),
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                            builder: (_) => const PaymentProofScreen())),
                  ),
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(context.t('sub.continueTill'),
                      style: const TextStyle(
                          color: Color(0xFF7A3128),
                          decoration: TextDecoration.underline)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum PayChannel { telebirr, cbe }

/// Submit payment proof (prototype screen 05) → proof submitted (06).
///
/// Pay ETB 1,000 by Telebirr or CBE Birr, attach the screenshot, and a person verifies it.
/// No self-unlock: the subscription changes only when platform staff approve it.
class PaymentProofScreen extends StatefulWidget {
  const PaymentProofScreen({super.key});

  @override
  State<PaymentProofScreen> createState() => _PaymentProofScreenState();
}

class _PaymentProofScreenState extends State<PaymentProofScreen> {
  PayChannel _channel = PayChannel.telebirr;
  final _reference = TextEditingController();
  final _amount = TextEditingController();
  XFile? _image;
  bool _busy = false;
  bool _sent = false;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_amount.text.isEmpty) {
      final price =
          TerminalScope.read(context).subscription?.priceSantim ?? 100000;
      _amount.text = formatBirr(price);
    }
  }

  @override
  void dispose() {
    _reference.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery, maxWidth: 2000, imageQuality: 85);
    if (picked != null && mounted) setState(() => _image = picked);
  }

  Future<void> _submit() async {
    final t = TerminalScope.read(context);
    final amount = parseBirr(_amount.text);
    if (_image == null || amount == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bytes = await _image!.readAsBytes();
      final channel = _channel == PayChannel.telebirr ? 'Telebirr' : 'CBE Birr';
      await t.authed((token) => t.api.submitPaymentProof(
            token,
            screenshot: bytes,
            filename: _image!.name,
            amountSantim: amount,
            note: '$channel ${_reference.text.trim()}'.trim(),
          ));
      await t.loadSubscription();
      if (mounted) setState(() => _sent = true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_sent) return _sentView(context);
    final amount = parseBirr(_amount.text);
    return Scaffold(
      body: Column(children: [
        PTopBar(
            title: context.t('sub.submitTitle'),
            onBack: () => Navigator.of(context).pop()),
        Expanded(
          child: PBody(children: [
            PNotice.text(
                Tone.blue,
                Icons.info_outline,
                context.tf('sub.howToPay',
                    {'amount': formatEtbShort(amount ?? 100000)})),
            PField(
              label: context.t('sub.method'),
              child: PSegmented<PayChannel>(
                options: const [
                  (PayChannel.telebirr, 'Telebirr'),
                  (PayChannel.cbe, 'CBE Birr'),
                ],
                value: _channel,
                onChanged: (c) => setState(() => _channel = c),
              ),
            ),
            PField(
              label: context.t('sub.reference'),
              hint: 'TB-8842190',
              controller: _reference,
              onChanged: (_) => setState(() {}),
            ),
            PField(
              label: context.t('sub.amount'),
              controller: _amount,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => setState(() {}),
            ),
            PField(
              label: context.t('sub.screenshot'),
              child: GestureDetector(
                onTap: _pick,
                child: Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(vertical: 26, horizontal: 12),
                  decoration: BoxDecoration(
                    color: _image == null
                        ? Colors.white.withValues(alpha: 0.55)
                        : PharmaColors.greenTint,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                        color: _image == null
                            ? const Color(0xFFC9D4CC)
                            : PharmaColors.green,
                        width: 1.5),
                  ),
                  child: Column(children: [
                    Icon(
                        _image == null
                            ? Icons.upload_outlined
                            : Icons.check_circle_outline,
                        color: _image == null
                            ? PharmaColors.muted
                            : PharmaColors.green),
                    const SizedBox(height: 7),
                    Text(
                      _image == null
                          ? context.t('sub.tapUpload')
                          : _image!.name,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 12.5, color: PharmaColors.muted),
                    ),
                  ]),
                ),
              ),
            ),
            if (_error != null)
              PNotice.text(Tone.red, Icons.error_outline, _error!),
          ]),
        ),
        PFooter(
          child: PButton(
            label: context.t(_busy ? 'sub.sending' : 'sub.submitForReview'),
            onPressed: _busy || _image == null || amount == null || amount <= 0
                ? null
                : _submit,
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
                const PMark(icon: Icons.schedule, size: 74),
                const SizedBox(height: 18),
                Text(context.t('sub.sentTitle'),
                    style: const TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3)),
                const SizedBox(height: 10),
                Text(
                  context.tf('sub.sentBody', {
                    'channel': _channel == PayChannel.telebirr
                        ? 'Telebirr'
                        : 'CBE Birr',
                    'amount': formatEtbShort(parseBirr(_amount.text) ?? 0),
                  }),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: PharmaColors.muted, fontSize: 13.5, height: 1.55),
                ),
                const SizedBox(height: 18),
                PBadge(context.t('sub.awaiting'), tone: Tone.amber),
                const SizedBox(height: 26),
                SizedBox(
                  width: 250,
                  child: PButton(
                    kind: BtnKind.plain,
                    label: context.t('common.done'),
                    onPressed: () => Navigator.of(context)
                        .popUntil((route) => route.isFirst),
                  ),
                ),
              ]),
            ),
          ),
        ),
      );
}
