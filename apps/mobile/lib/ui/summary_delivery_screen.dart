import 'dart:async';

import 'package:flutter/material.dart';

import '../api/tenant_api.dart';
import '../core/theme.dart';
import '../l10n/locale_store.dart';
import 'kit.dart';
import 'links.dart';
import 'terminal.dart';

/// For tests: stands in for opening Telegram.
Future<void> Function(Uri link)? debugOpenTelegram;

/// The daily summary on Telegram (FR-17, ADR-039).
///
/// Until this, the summary had to be opened; an owner who was not thinking about the shop
/// that evening did not see it. Here they connect their own Telegram once, and it arrives.
///
/// Connecting is two taps on purpose and no typing: the app gets a one-time link from the
/// server and opens it; pressing Start in Telegram is what proves the chat is the owner's.
/// Nobody enters a phone number or a chat id, so nobody can point a pharmacy's figures at
/// a chat by mistyping one.
class SummaryDeliveryScreen extends StatefulWidget {
  const SummaryDeliveryScreen({super.key});

  @override
  State<SummaryDeliveryScreen> createState() => _SummaryDeliveryScreenState();
}

class _SummaryDeliveryScreenState extends State<SummaryDeliveryScreen>
    with WidgetsBindingObserver {
  TelegramStatus? _status;
  bool _offline = false;
  bool _busy = false;

  /// Telegram has been opened and the owner has not come back linked yet.
  bool _waiting = false;
  String? _message;
  Tone _tone = Tone.green;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      unawaited(_load());
    }
  }

  /// Coming back from Telegram is the moment to look again — without being asked.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _waiting) unawaited(_load());
  }

  Future<void> _load() async {
    final t = TerminalScope.read(context);
    try {
      final status = await t.authed(t.api.telegramStatus);
      if (!mounted) return;
      setState(() {
        _status = status;
        _offline = false;
        if (status.linked) _waiting = false;
      });
    } catch (_) {
      if (mounted) setState(() => _offline = true);
    }
  }

  Future<void> _run(Future<void> Function() work) async {
    final offline = context.t('tg.offline');
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await work();
    } catch (_) {
      if (mounted) _say(offline, Tone.red);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _say(String message, Tone tone) => setState(() {
        _message = message;
        _tone = tone;
      });

  Future<void> _connect() => _run(() async {
        final t = TerminalScope.read(context);
        final locale = context.l10n.locale;
        final link = await t
            .authed((token) => t.api.telegramLink(token, locale: locale));
        if (!mounted) return;
        setState(() => _waiting = true);
        final open = debugOpenTelegram;
        if (open != null) {
          await open(link);
        } else {
          await openLink(context, link);
        }
      });

  Future<void> _check() => _run(() async {
        final notYet = context.t('tg.notYet');
        await _load();
        if (mounted && _status?.linked != true) _say(notYet, Tone.amber);
      });

  Future<void> _sendNow() => _run(() async {
        final t = TerminalScope.read(context);
        final sent = context.t('tg.sent');
        final notSent = context.t('tg.notSent');
        final ok = await t.authed(t.api.telegramSendNow);
        if (!mounted) return;
        _say(ok ? sent : notSent, ok ? Tone.green : Tone.amber);
        await _load();
      });

  Future<void> _disconnect() => _run(() async {
        final t = TerminalScope.read(context);
        final stopped = context.t('tg.disconnected');
        await t.authed(t.api.telegramUnlink);
        if (!mounted) return;
        setState(() => _waiting = false);
        _say(stopped, Tone.blue);
        await _load();
      });

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return Scaffold(
      body: Column(children: [
        PTopBar(
          title: context.t('tg.title'),
          onBack: () => Navigator.of(context).pop(),
        ),
        Expanded(
          child: PBody(children: [
            if (_offline && status == null)
              PNotice.text(Tone.amber, Icons.wifi_off, context.t('tg.offline'))
            else if (status == null)
              PNotice.text(Tone.blue, Icons.schedule, context.t('tg.loading'))
            else if (!status.available)
              // Said plainly rather than hidden: the owner was told this exists.
              PNotice.text(
                  Tone.amber, Icons.info_outline, context.t('tg.unavailable'))
            else ...[
              // What just happened comes first: under three paragraphs of explanation it
              // was below the fold on a small phone.
              if (_waiting && !status.linked)
                PNotice.text(
                    Tone.amber, Icons.schedule, context.t('tg.waiting')),
              if (_message != null)
                PNotice.text(
                    _tone,
                    _tone == Tone.green
                        ? Icons.check_circle_outline
                        : Icons.info_outline,
                    _message!),
              if (status.linked) ...[
                PTiles(tiles: [
                  PTile(
                    label: context.t('tg.connected'),
                    value: status.botUsername == null
                        ? '✓'
                        : '@${status.botUsername}',
                    valueColor: PharmaColors.green,
                  ),
                ]),
                const SizedBox(height: 14),
                PNotice.text(
                    Tone.green,
                    Icons.check_circle_outline,
                    [
                      if (status.linkedAt != null)
                        context.tf('tg.connectedSince',
                            {'date': context.l10n.date(status.linkedAt!)}),
                      status.lastSentFor == null
                          ? context.t('tg.neverSent')
                          : context
                              .tf('tg.lastSent', {'day': status.lastSentFor!}),
                    ].join(' · ')),
              ],
              PNotice.text(
                  Tone.blue, Icons.send_outlined, context.t('tg.about')),
              PNotice.text(
                  Tone.blue, Icons.shield_outlined, context.t('tg.privacy')),
            ],
          ]),
        ),
        if (status != null && status.available)
          PFooter(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (!status.linked) ...[
                PButton(
                  icon: Icons.send_outlined,
                  label: context.t('tg.connect'),
                  onPressed: _busy ? null : _connect,
                ),
                const SizedBox(height: 8),
                if (_waiting)
                  PButton(
                    kind: BtnKind.plain,
                    label: context.t('tg.check'),
                    onPressed: _busy ? null : _check,
                  )
                else
                  Text(context.t('tg.connectHint'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 12.5, color: PharmaColors.muted)),
              ] else ...[
                PButton(
                  icon: Icons.send_outlined,
                  label: context.t('tg.sendNow'),
                  onPressed: _busy ? null : _sendNow,
                ),
                const SizedBox(height: 10),
                PButton(
                  kind: BtnKind.plain,
                  label: context.t('tg.disconnect'),
                  onPressed: _busy ? null : _disconnect,
                ),
              ],
            ]),
          ),
      ]),
    );
  }
}
