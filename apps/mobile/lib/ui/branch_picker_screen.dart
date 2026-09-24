import 'package:flutter/material.dart';

import '../auth/branch_placement.dart';
import '../contracts/contracts.dart';
import '../core/theme.dart';
import '../l10n/locale_store.dart';

/// Asked once per device: which branch is this terminal in?
///
/// Every sale, receipt and count carries a branch (BR-4.3), and an all-branch user —
/// usually the owner, often the person at the counter in a one-shop pharmacy — does not
/// imply one. Guessing would put a day's takings on the wrong shop's books.
class BranchPickerScreen extends StatelessWidget {
  const BranchPickerScreen({
    super.key,
    required this.placement,
    required this.onChosen,
    required this.onRetry,
    required this.onSignOut,
  });

  final Placement placement;
  final ValueChanged<String> onChosen;
  final VoidCallback onRetry;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final placement = this.placement;
    return Scaffold(
      appBar: AppBar(
        title: Text(context.t('branch.title')),
        actions: [
          IconButton(
            tooltip: context.t('settings.signOut'),
            icon: const Icon(Icons.logout),
            onPressed: onSignOut,
          ),
        ],
      ),
      body: switch (placement) {
        ChooseBranch(:final branches) => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(context.t('branch.hint'),
                  style: const TextStyle(color: PharmaColors.muted)),
              const SizedBox(height: 12),
              for (final BranchRef branch in branches)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.storefront_outlined),
                    title: Text(branch.name),
                    subtitle:
                        branch.address == null ? null : Text(branch.address!),
                    onTap: () => onChosen(branch.id),
                  ),
                ),
            ],
          ),
        NoBranch() => _Message(text: context.t('branch.none')),
        _ => _Message(
            text: context.t('branch.unreachable'),
            action: FilledButton(
                onPressed: onRetry, child: Text(context.t('branch.retry'))),
          ),
      },
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, this.action});
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(text, textAlign: TextAlign.center),
              if (action != null) ...[const SizedBox(height: 16), action!],
            ],
          ),
        ),
      );
}
