import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../auth/offline_credentials.dart';
import '../auth/session.dart';
import '../contracts/contracts.dart';
import '../core/theme.dart';
import '../l10n/locale_store.dart';
import '../sync/sync_client.dart';
import 'kit.dart';

/// Login (prototype screen 03; FR-2, ADR-017).
///
/// The PIN keypad is the counter's fast path. The first sign-in on a device also asks for
/// the pharmacy code and username; after that the device remembers who last signed in —
/// never a credential — and greets them by name. Owners and managers have passwords
/// (FR-2: "PIN or password"), so the keypad can switch to a keyboard.
class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.client,
    required this.terminalId,
    required this.onSignedIn,
    this.remembered,
    this.offline,
    this.onForget,
    this.onRequestAccount,
  });

  final SyncClient client;
  final String terminalId;
  final void Function(LoginResponse response, String tenantCode,
      String username, bool usedPassword) onSignedIn;
  final RememberedIdentity? remembered;

  /// The cached-PIN fallback for a sign-in with no network (AC-2.2). Null in tests that
  /// only exercise the online path.
  final OfflineCredentials? offline;
  final VoidCallback? onForget;
  final VoidCallback? onRequestAccount;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  // Pre-filled with the development seed in debug builds only. A release build is what a
  // pharmacy installs, and it must not suggest a tenant — let alone a working PIN.
  late final _tenantCode = TextEditingController(
      text: widget.remembered?.tenantCode ?? (kDebugMode ? 'abay' : ''));
  late final _username = TextEditingController(
      text: widget.remembered?.username ?? (kDebugMode ? 'cashier' : ''));
  final _password = TextEditingController();
  String _pin = '';
  String? _error;
  bool _offline = false;
  bool _busy = false;
  late bool _usePassword = widget.remembered?.usesPassword ?? false;

  bool get _known => widget.remembered != null;

  @override
  void dispose() {
    _tenantCode.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  String get _secret => _usePassword ? _password.text : _pin;

  /// Every field filled in. An empty submission can only be refused, and ADR-017 counts
  /// attempts against whatever was supplied — five taps on a blank form would throttle a
  /// cashier who had not tried a credential yet.
  bool get _complete =>
      _tenantCode.text.trim().isNotEmpty &&
      _username.text.trim().isNotEmpty &&
      (_usePassword ? _password.text.isNotEmpty : _pin.length >= 4);

  void _key(String digit) {
    if (_busy || _pin.length >= 8) return;
    setState(() {
      _pin += digit;
      _error = null;
    });
  }

  void _backspace() {
    if (_pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _submit() async {
    if (!_complete || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _offline = false;
    });
    try {
      final response = await widget.client.login(LoginRequest(
        tenantCode: _tenantCode.text.trim(),
        username: _username.text.trim(),
        secret: _secret,
        terminalId: widget.terminalId,
      ));
      // Leave behind what an offline sign-in tomorrow morning will need (AC-2.2).
      await widget.offline?.remember(
        tenantCode: _tenantCode.text.trim(),
        username: _username.text.trim(),
        secret: _secret,
        response: response,
      );
      if (!mounted) return;
      widget.onSignedIn(response, _tenantCode.text.trim(),
          _username.text.trim(), _usePassword);
    } catch (error) {
      // One message for every credential failure: telling "no such pharmacy" from "wrong
      // PIN" tells an attacker which codes and usernames are real. A throttle says how long
      // and that the shop keeps selling (ADR-017). No connection is said plainly — it leaks
      // nothing about any account, and "check the details" would send someone retyping a
      // correct PIN at a dead network.
      final status = error is SyncTransportException ? error.statusCode : null;
      // No network at all: try the PIN against what this phone cached at the last online
      // sign-in (AC-2.2, ADR-023) before telling anyone the till cannot open.
      if (status == null && widget.offline != null) {
        final secret = _secret;
        try {
          final cached = await widget.offline!.signIn(
            tenantCode: _tenantCode.text.trim(),
            username: _username.text.trim(),
            secret: secret,
          );
          if (!mounted) return;
          widget.onSignedIn(cached, _tenantCode.text.trim(),
              _username.text.trim(), _usePassword);
          return;
        } on OfflineSignInRefused catch (refused) {
          if (!mounted) return;
          setState(() {
            _pin = '';
            _password.clear();
            _offline = refused.reason != OfflineRefusal.wrong;
            _error = switch (refused.reason) {
              OfflineRefusal.wrong => context.t('login.failed'),
              OfflineRefusal.unknown => context.t('login.noConnection'),
              OfflineRefusal.expired => context.t('login.offlineExpired'),
              OfflineRefusal.throttled => context.tf('login.offlineThrottled',
                  {'minutes': (refused.retryAfter?.inMinutes ?? 0) + 1}),
            };
          });
          return;
        }
      }
      if (mounted) {
        setState(() {
          _pin = '';
          _password.clear();
          if (status == 429) {
            _error = (error as SyncTransportException).message;
          } else if (status == null) {
            _offline = true;
            _error = context.t('login.noConnection');
          } else {
            _error = context.t('login.failed');
          }
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final first = widget.remembered?.displayName.split(' ').first;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 34, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                children: [
                  const PLogo(),
                  const SizedBox(height: 18),
                  Text(
                    _known
                        ? context.tf('login.welcomeBack', {'name': first!})
                        : context.t('app.name'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _known
                        ? '${widget.remembered!.tenantCode} · ${widget.remembered!.username}'
                        : context.t('app.tagline'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: PharmaColors.muted, fontSize: 13.5),
                  ),
                  const SizedBox(height: 18),
                  if (!_known) ...[
                    PField(
                      label: context.t('login.pharmacyCode'),
                      controller: _tenantCode,
                      textInputAction: TextInputAction.next,
                      onChanged: (_) => setState(() {}),
                    ),
                    PField(
                      label: context.t('login.username'),
                      controller: _username,
                      textInputAction: TextInputAction.next,
                      onChanged: (_) => setState(() {}),
                    ),
                  ],
                  if (_usePassword)
                    PField(
                      label: context.t('login.password'),
                      controller: _password,
                      obscure: true,
                      keyboardType: TextInputType.visiblePassword,
                      autofocus: _known,
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => _submit(),
                    )
                  else ...[
                    _PinDots(length: _pin.length),
                    const SizedBox(height: 4),
                  ],
                  if (_offline || _error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: _offline
                          ? Column(children: [
                              PSyncDot(
                                  label: context.t('sync.offline'), on: false),
                              const SizedBox(height: 8),
                              Text(_error!,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      color: PharmaColors.amber, fontSize: 13)),
                            ])
                          : Text(_error!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: PharmaColors.red, fontSize: 13)),
                    ),
                  if (!_usePassword)
                    _Keypad(onDigit: _key, onBackspace: _backspace),
                  const SizedBox(height: 18),
                  PButton(
                    kind: BtnKind.green,
                    label:
                        context.t(_busy ? 'login.signingIn' : 'login.signIn'),
                    onPressed: _busy || !_complete ? null : _submit,
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    alignment: WrapAlignment.center,
                    children: [
                      TextButton(
                        onPressed: () => setState(() {
                          _usePassword = !_usePassword;
                          _pin = '';
                          _password.clear();
                          _error = null;
                        }),
                        child: Text(context.t(_usePassword
                            ? 'login.usePin'
                            : 'login.usePassword')),
                      ),
                      if (_known)
                        TextButton(
                          onPressed: widget.onForget,
                          child: Text(context.t('login.notYou')),
                        ),
                    ],
                  ),
                  if (kDebugMode && !_known)
                    const Text('Development seed: abay / cashier / 1234',
                        style:
                            TextStyle(color: PharmaColors.faint, fontSize: 12)),
                  if (widget.onRequestAccount != null) ...[
                    const SizedBox(height: 14),
                    const Divider(color: PharmaColors.line),
                    const SizedBox(height: 8),
                    Wrap(
                      alignment: WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text('${context.t('login.newPharmacy')} ',
                            style: const TextStyle(
                                fontSize: 13, color: PharmaColors.muted)),
                        GestureDetector(
                          onTap: widget.onRequestAccount,
                          child: Text(context.t('login.requestAccount'),
                              style: const TextStyle(
                                  fontSize: 13.5,
                                  color: PharmaColors.green,
                                  fontWeight: FontWeight.w700)),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `.pin-dots` — one ring per digit, at least four.
class _PinDots extends StatelessWidget {
  const _PinDots({required this.length});
  final int length;

  @override
  Widget build(BuildContext context) {
    final count = length < 4 ? 4 : length;
    return Semantics(
      label: '$length digits entered',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < count; i++)
              Container(
                width: 14,
                height: 14,
                margin: const EdgeInsets.symmetric(horizontal: 7),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < length ? PharmaColors.green : Colors.transparent,
                  border: Border.all(color: PharmaColors.green, width: 2),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// `.keypad` — 1–9, a blank, 0 and backspace.
class _Keypad extends StatelessWidget {
  const _Keypad({required this.onDigit, required this.onBackspace});
  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;

  @override
  Widget build(BuildContext context) {
    Widget key(String label, VoidCallback? onTap, {String? semantics}) =>
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(7.5),
            child: onTap == null
                ? const SizedBox(height: 50)
                : Semantics(
                    button: true,
                    label: semantics ?? label,
                    excludeSemantics: true,
                    child: Material(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(15),
                      elevation: 0,
                      shadowColor: const Color(0x0F0D3B2B),
                      child: InkWell(
                        onTap: onTap,
                        borderRadius: BorderRadius.circular(15),
                        child: Container(
                          height: 50,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(15),
                            boxShadow: const [
                              BoxShadow(
                                  color: Color(0x0F0D3B2B),
                                  blurRadius: 12,
                                  offset: Offset(0, 3))
                            ],
                          ),
                          child: Text(label,
                              style: const TextStyle(
                                  fontSize: 24, fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ),
                  ),
          ),
        );
    Widget row(List<Widget> keys) => Row(children: keys);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 262),
      child: Column(children: [
        row([
          key('1', () => onDigit('1')),
          key('2', () => onDigit('2')),
          key('3', () => onDigit('3'))
        ]),
        row([
          key('4', () => onDigit('4')),
          key('5', () => onDigit('5')),
          key('6', () => onDigit('6'))
        ]),
        row([
          key('7', () => onDigit('7')),
          key('8', () => onDigit('8')),
          key('9', () => onDigit('9'))
        ]),
        row([
          key('', null),
          key('0', () => onDigit('0')),
          key('⌫', onBackspace, semantics: 'Delete')
        ]),
      ]),
    );
  }
}
