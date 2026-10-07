import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/theme.dart';
import '../data/backup.dart';
import '../l10n/locale_store.dart';
import 'kit.dart';
import 'terminal.dart';

/// Where a backup file goes to and comes from. Both ends belong to the operating system —
/// its share sheet and its file picker — so tests replace them.
/// Where a new backup is put.
enum BackupDestination {
  /// The share sheet: Telegram, email, a cloud drive.
  send,

  /// The system's "save as" picker: a memory card, a USB stick, a folder on this phone.
  file,
}

abstract final class BackupFiles {
  static Future<bool> Function(Uint8List bytes, String name)? debugSave;
  static Future<Uint8List?> Function()? debugPick;

  /// For tests: answers "send it or save it?" without the sheet.
  static BackupDestination? debugDestination;

  /// For tests: stands in for the system's "save as" picker. Returns whether it saved.
  static Future<bool> Function(Uint8List bytes, String name)? debugSaveAsFile;

  /// Writes the file wherever the owner points the system's "save as" picker.
  ///
  /// Added after a real phone showed a share sheet with nothing on it but ways to send the
  /// file to somebody: no memory card, no folder. An owner without Telegram, or without a
  /// network that day, had no way to keep a backup at all. Returns false if the picker
  /// was closed without saving.
  static Future<bool> saveAsFile(Uint8List bytes, String name) async {
    final override = debugSaveAsFile;
    if (override != null) return override(bytes, name);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    try {
      final saved = await FlutterFileDialog.saveFile(
          params:
              SaveFileDialogParams(sourceFilePath: file.path, fileName: name));
      return saved != null;
    } finally {
      // The copy in temporary files has done its job either way, and a backup must not
      // be left lying in the one place nobody will look for it.
      if (file.existsSync()) file.deleteSync();
    }
  }

  /// Hands the file to the share sheet, so the owner puts it where *they* keep things:
  /// their own Telegram, their email, a memory card. Deliberately not a folder on this
  /// phone — a backup that lives only on the phone it backs up is lost with it.
  ///
  /// Returns whether the file was actually handed to something. False when the share
  /// sheet was closed without choosing: the backup then exists only in this phone's
  /// temporary files, which is the one place a backup must not be left.
  static Future<bool> save(Uint8List bytes, String name) async {
    final override = debugSave;
    if (override != null) return override(bytes, name);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    final result = await SharePlus.instance.share(ShareParams(
      files: [XFile(file.path, mimeType: 'application/octet-stream')],
      subject: name,
    ));
    return result.status != ShareResultStatus.dismissed;
  }

  static Future<Uint8List?> pick() async {
    final override = debugPick;
    if (override != null) return override();
    // No type filter: the file has passed through a chat app or an email, which may have
    // renamed it or lost its type. What it is gets decided by reading it, not by its name.
    final file = await openFile();
    return file?.readAsBytes();
  }
}

/// Backup & restore (FR-15, ADR-033).
///
/// The screen leads with the one number that says whether a backup matters right now: how
/// many sales exist only on this phone. With nothing waiting, the server already has
/// everything; with forty waiting and no network for two days, this is the screen an owner
/// should be on.
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key, this.service});

  /// For tests: a service with a cheap key derivation.
  final BackupService? service;

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  DateTime? _lastBackup;
  bool _busy = false;
  String? _message;
  Tone _tone = Tone.green;
  BackupService? _service;

  BackupService get _backup => _service!;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_service == null) {
      _service = widget.service ?? TerminalScope.read(context).backups;
      unawaited(_backup.lastBackupAt().then((at) {
        if (mounted) setState(() => _lastBackup = at);
      }));
    }
  }

  void _say(String message, {Tone tone = Tone.green}) => setState(() {
        _busy = false;
        _message = message;
        _tone = tone;
      });

  Future<void> _backUp() async {
    final t = TerminalScope.read(context);
    final passphrase = await _askPassphrase(context, confirm: true);
    if (passphrase == null || !mounted) return;
    final to = BackupFiles.debugDestination ??
        (BackupFiles.debugSave != null
            ? BackupDestination.send
            : await _askDestination(context));
    if (to == null || !mounted) return;
    final done = context
        .t(to == BackupDestination.file ? 'backup.savedFile' : 'backup.made');
    final notSent = context.t('backup.notSent');
    final failed = context.t('backup.failed');
    setState(() => _busy = true);
    try {
      final now = DateTime.now();
      final bytes = await _backup.create(
        passphrase: passphrase,
        tenantId: t.session.scope.tenantId,
        tenantCode: t.session.tenantCode,
        branchId: t.branchId,
        branchName: t.branchName ?? '',
        terminalId: t.terminalId,
        now: now,
      );
      String two(int n) => n.toString().padLeft(2, '0');
      final name = 'pharmaet-${t.session.tenantCode}'
          '-${now.year}${two(now.month)}${two(now.day)}'
          '-${two(now.hour)}${two(now.minute)}.pharmaet-backup';
      final kept = to == BackupDestination.file
          ? await BackupFiles.saveAsFile(bytes, name)
          : await BackupFiles.save(bytes, name);
      if (!mounted) return;
      if (!kept) {
        // Found on a real phone: closing the share sheet still said "Backup made". A file
        // nobody sent anywhere protects nothing, and saying otherwise is the worst thing
        // this screen could do.
        return _say(notSent, tone: Tone.amber);
      }
      setState(() => _lastBackup = now);
      _say(done);
    } catch (_) {
      if (mounted) _say(failed, tone: Tone.red);
    }
  }

  /// Send it, or save it as a file. Asked every time: where a backup goes is the whole
  /// point of making one.
  Future<BackupDestination?> _askDestination(BuildContext context) =>
      showModalBottomSheet<BackupDestination>(
        context: context,
        builder: (sheet) => Padding(
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(sheet.t('backup.where'),
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 14),
              PRows(children: [
                PRow(
                  avatarIcon: Icons.ios_share,
                  title: sheet.t('backup.send'),
                  subtitle: sheet.t('backup.sendSub'),
                  chevron: true,
                  onTap: () => Navigator.pop(sheet, BackupDestination.send),
                ),
                PRow(
                  avatarIcon: Icons.sd_card_outlined,
                  avatarTone: Tone.blue,
                  title: sheet.t('backup.saveFile'),
                  subtitle: sheet.t('backup.saveFileSub'),
                  chevron: true,
                  onTap: () => Navigator.pop(sheet, BackupDestination.file),
                ),
              ]),
            ],
          ),
        ),
      );

  Future<void> _restore() async {
    final t = TerminalScope.read(context);
    final l10n = context.l10n;
    final bytes = await BackupFiles.pick();
    if (bytes == null || !mounted) return;

    final BackupHeader header;
    try {
      header = BackupService.readHeader(bytes);
    } on BackupException catch (e) {
      return _say(l10n.get('backup.problem.${e.problem.name}'), tone: Tone.red);
    }
    // Checked before asking for a passphrase: nobody should type one in order to be
    // told the file was never theirs to restore.
    if (header.tenantId != t.session.scope.tenantId) {
      return _say(l10n.get('backup.problem.otherPharmacy'), tone: Tone.red);
    }
    if (header.branchId != t.branchId) {
      return _say(
          l10n.f(
              'backup.problem.otherBranchNamed', {'branch': header.branchName}),
          tone: Tone.red);
    }

    final passphrase = await _askPassphrase(
      context,
      confirm: false,
      about: l10n.f('backup.about', {
        'branch': header.branchName,
        'date': '${l10n.date(header.createdAt)} ${l10n.time(header.createdAt)}',
        'n': header.pending,
      }),
    );
    if (passphrase == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final result = await _backup.restore(
        bytes,
        passphrase: passphrase,
        tenantId: t.session.scope.tenantId,
        branchId: t.branchId,
      );
      await t.refresh();
      // Send them now if there is a network; if not, they wait in the queue like any
      // other sale.
      unawaited(t.sync());
      if (!mounted) return;
      _say(result.operationsRestored == 0
          ? l10n.get('backup.restoredNothing')
          : l10n.f('backup.restored', {'n': result.operationsRestored}));
    } on BackupException catch (e) {
      if (mounted) {
        _say(l10n.get('backup.problem.${e.problem.name}'), tone: Tone.red);
      }
    } catch (_) {
      if (mounted) _say(l10n.get('backup.problem.notABackup'), tone: Tone.red);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = TerminalScope.of(context);
    final pending = t.status.pending;
    final last = _lastBackup;
    return Scaffold(
      body: Column(children: [
        PTopBar(
          title: context.t('backup.title'),
          onBack: () => Navigator.of(context).pop(),
        ),
        Expanded(
          child: PBody(children: [
            PTiles(tiles: [
              PTile(
                label: context.t('backup.onlyHere'),
                value: '$pending',
                valueColor: pending > 0 ? PharmaColors.amber : null,
              ),
              PTile(
                label: context.t('backup.last'),
                value: last == null
                    ? context.t('backup.never')
                    : context.l10n.date(last),
              ),
            ]),
            const SizedBox(height: 14),
            PNotice.text(
              pending > 0 ? Tone.amber : Tone.green,
              pending > 0 ? Icons.phonelink_erase : Icons.cloud_done_outlined,
              pending > 0
                  ? context.tf('backup.whyNow', {'n': pending})
                  : context.t('backup.whyLater'),
            ),
            if (_message != null)
              PNotice.text(
                  _tone,
                  _tone == Tone.red
                      ? Icons.error_outline
                      : Icons.check_circle_outline,
                  _message!),
            PButton(
              icon: Icons.save_alt,
              label: context.t(_busy ? 'backup.working' : 'backup.now'),
              onPressed: _busy ? null : _backUp,
            ),
            const SizedBox(height: 10),
            PButton(
              kind: BtnKind.plain,
              icon: Icons.restore,
              label: context.t('backup.restore'),
              onPressed: _busy ? null : _restore,
            ),
            const SizedBox(height: 16),
            PNotice.text(
                Tone.blue, Icons.lock_outline, context.t('backup.passNotice')),
            PNotice.text(Tone.blue, Icons.info_outline,
                context.t('backup.restoreNotice')),
          ]),
        ),
      ]),
    );
  }
}

/// Asks for a backup's passphrase. With [confirm], twice — it is about to become the only
/// way into the file, and a typo made once is a backup nobody can open.
Future<String?> _askPassphrase(BuildContext context,
    {required bool confirm, String? about}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PassphraseDialog(confirm: confirm, about: about),
  );
}

class _PassphraseDialog extends StatefulWidget {
  const _PassphraseDialog({required this.confirm, this.about});
  final bool confirm;
  final String? about;

  @override
  State<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<_PassphraseDialog> {
  final _first = TextEditingController();
  final _second = TextEditingController();

  @override
  void dispose() {
    _first.dispose();
    _second.dispose();
    super.dispose();
  }

  bool get _valid => widget.confirm
      ? _first.text.length >= BackupService.minPassphrase &&
          _first.text == _second.text
      : _first.text.isNotEmpty;

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(context
            .t(widget.confirm ? 'backup.choosePass' : 'backup.enterPass')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.about != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Text(widget.about!,
                      style: const TextStyle(fontSize: 14, height: 1.4)),
                ),
              PField(
                label: context.t('backup.pass'),
                helper: widget.confirm ? context.t('backup.passRule') : null,
                controller: _first,
                obscure: true,
                autofocus: true,
                onChanged: (_) => setState(() {}),
              ),
              if (widget.confirm)
                PField(
                  label: context.t('backup.passAgain'),
                  controller: _second,
                  obscure: true,
                  onChanged: (_) => setState(() {}),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.t('common.cancel')),
          ),
          FilledButton(
            onPressed:
                _valid ? () => Navigator.of(context).pop(_first.text) : null,
            child: Text(context.t('common.continue')),
          ),
        ],
      );
}
