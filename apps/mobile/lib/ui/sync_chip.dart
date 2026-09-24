import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../l10n/locale_store.dart';
import '../sync/sync_service.dart';

/// The sync-state chip — the prototype calls it the app's signature, and it is always
/// visible on purpose (`.sync.on` / `.sync.off`).
///
/// A cashier working through a power cut needs to know, at a glance and without asking
/// anyone, that the sales they are ringing up are safe. The chip never says "error" for
/// being offline: offline is the expected, supported state of this app, not a fault.
///
/// Three tones, not two. Green and amber are the prototype's; red is ADR-019's, for the one
/// state the terminal cannot resolve by itself. Showing an expired session in the same amber
/// as "waiting" is what let it read as a network outage for fifteen minutes at a time.
class SyncChip extends StatelessWidget {
  const SyncChip({super.key, required this.status, this.onTap});

  final SyncStatus status;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final (label, tone) = describe(context, status);
    final (bg, fg, dot) = switch (tone) {
      ChipTone.on => (
          PharmaColors.greenTint,
          PharmaColors.greenDark,
          PharmaColors.green
        ),
      ChipTone.off => (
          PharmaColors.amberTint,
          PharmaColors.amber,
          PharmaColors.amber
        ),
      ChipTone.alert => (
          PharmaColors.redTint,
          PharmaColors.red,
          PharmaColors.red
        ),
    };

    return Semantics(
      label: '${context.t('sync.status')}: $label',
      button: onTap != null,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          key: const ValueKey('sync-chip'),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                key: const ValueKey('sync-dot'),
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: dot,
                  shape: BoxShape.circle,
                  boxShadow: tone == ChipTone.on
                      ? null
                      : [
                          BoxShadow(
                              color: dot.withValues(alpha: 0.15),
                              spreadRadius: 3)
                        ],
                ),
              ),
              const SizedBox(width: 7),
              Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The chip's words and tone for a status — shared with Settings' "Sync now" row.
  static (String, ChipTone) describe(BuildContext context, SyncStatus status) =>
      switch (status.state) {
        SyncState.synced => (
            status.lastSyncedAt == null
                ? context.t('sync.synced')
                : '${context.t('sync.synced')} ${_age(status.lastSyncedAt!)}'
                    .trim(),
            ChipTone.on
          ),
        SyncState.syncing => (context.t('sync.syncing'), ChipTone.on),
        SyncState.offline => (
            status.pending == 0
                ? context.t('sync.offline')
                : '${context.t('sync.offline')} · ${status.pending} ${context.t('sync.waiting')}',
            ChipTone.off
          ),
        SyncState.sessionExpired => (
            context.t('sync.signInAgain'),
            ChipTone.alert
          ),
        SyncState.needsAttention => (
            '${status.needsAttention} ${context.t('sync.needsAttention')}',
            ChipTone.alert
          ),
        SyncState.idle => status.pending == 0
            ? (context.t('sync.upToDate'), ChipTone.on)
            : ('${status.pending} ${context.t('sync.queued')}', ChipTone.off),
      };

  static String _age(DateTime at) {
    final minutes = DateTime.now().difference(at).inMinutes;
    if (minutes < 1) return '';
    if (minutes < 60) return '${minutes}m';
    return '${minutes ~/ 60}h';
  }
}

enum ChipTone { on, off, alert }
