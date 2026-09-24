import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../sync/sync_service.dart';

/// The sync-state chip — the prototype calls it the app's signature, and it is always
/// visible on purpose.
///
/// A cashier working through a power cut needs to know, at a glance and without asking
/// anyone, that the sales they are ringing up are safe. The chip never says "error" for
/// being offline: offline is the expected, supported state of this app, not a fault.
class SyncChip extends StatelessWidget {
  const SyncChip({super.key, required this.status, this.onTap});

  final SyncStatus status;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final (label, background, foreground, icon) = switch (status.state) {
      SyncState.synced => (
          'Synced',
          PharmaColors.greenTint,
          PharmaColors.greenDark,
          Icons.cloud_done_outlined
        ),
      SyncState.syncing => (
          'Syncing…',
          PharmaColors.greenTint,
          PharmaColors.greenDark,
          Icons.sync
        ),
      SyncState.offline => (
          '${status.pending} waiting',
          PharmaColors.amberTint,
          PharmaColors.amber,
          Icons.cloud_off_outlined,
        ),
      // Red, and worded as an instruction rather than a status. Every other state here is
      // something the terminal will resolve by itself; this one is the only one that needs a
      // person, and showing it in the same amber as "waiting" is what let an expired session
      // read as a network outage for fifteen minutes at a time (ADR-019).
      SyncState.sessionExpired => (
          'Sign in again',
          PharmaColors.redTint,
          PharmaColors.red,
          Icons.lock_clock_outlined,
        ),
      SyncState.needsAttention => (
          '${status.needsAttention} need attention',
          PharmaColors.redTint,
          PharmaColors.red,
          Icons.error_outline,
        ),
      SyncState.idle => (
          status.pending == 0 ? 'Up to date' : '${status.pending} queued',
          PharmaColors.greenTint,
          PharmaColors.greenDark,
          Icons.cloud_queue_outlined,
        ),
    };

    return Semantics(
      label: 'Sync status: $label',
      button: onTap != null,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: foreground),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: foreground,
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
}
