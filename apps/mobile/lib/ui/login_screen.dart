import 'package:flutter/material.dart';

import '../contracts/contracts.dart';
import '../core/theme.dart';
import '../l10n/locale_store.dart';
import '../sync/sync_client.dart';

/// Online sign-in.
///
/// A terminal must log in online at least once; after that it works through the offline
/// window against its cached scope (BR-2.3). The pharmacy code is asked for because
/// usernames are unique per tenant, not globally — authentication happens before any tenant
/// scope exists.
class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.client,
    required this.terminalId,
    required this.onSignedIn,
  });

  final SyncClient client;
  final String terminalId;
  final void Function(LoginResponse response, String tenantCode) onSignedIn;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _tenantCode = TextEditingController(text: 'abay');
  final _username = TextEditingController(text: 'cashier');
  final _secret = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _tenantCode.dispose();
    _username.dispose();
    _secret.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final response = await widget.client.login(LoginRequest(
        tenantCode: _tenantCode.text.trim(),
        username: _username.text.trim(),
        secret: _secret.text,
        terminalId: widget.terminalId,
      ));
      if (!mounted) return;
      widget.onSignedIn(response, _tenantCode.text.trim());
    } catch (error) {
      // One message for every failure. Telling the difference between "no such pharmacy"
      // and "wrong PIN" tells an attacker which codes and usernames are real.
      //
      // The exception is a throttle (ADR-017). "Check the details and try again" is actively
      // harmful advice to someone who has been rate-limited: they will try again, extend the
      // window, and never learn that waiting is what works. The server's message says how
      // long and says the shop keeps selling, which is what the person at the counter needs.
      final throttled =
          error is SyncTransportException && error.statusCode == 429;
      if (mounted) {
        setState(
          () => _error = throttled
              ? error.message
              : 'Could not sign in. Check the details and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFFF1B64E), Color(0xFFD89124)],
                      ),
                      borderRadius: BorderRadius.circular(15),
                    ),
                    alignment: Alignment.center,
                    child: const Text(
                      'P',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: PharmaColors.greenDark,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    context.t('app.name'),
                    style: const TextStyle(
                        fontSize: 24, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    context.t('app.tagline'),
                    style: const TextStyle(
                        color: PharmaColors.muted, fontSize: 13.5),
                  ),
                  const SizedBox(height: 26),
                  if (_error != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: PharmaColors.redTint,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        _error!,
                        style: const TextStyle(
                            color: PharmaColors.red, fontSize: 13),
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],
                  TextField(
                    controller: _tenantCode,
                    decoration:
                        const InputDecoration(labelText: 'Pharmacy code'),
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _username,
                    decoration:
                        InputDecoration(labelText: context.t('login.username')),
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _secret,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    decoration:
                        InputDecoration(labelText: context.t('login.pin')),
                    onSubmitted: (_) => _submit(),
                  ),
                  const SizedBox(height: 22),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: Text(_busy
                        ? context.t('login.signingIn')
                        : context.t('login.signIn')),
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'Development seed: abay / cashier / 1234',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: PharmaColors.faint, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
