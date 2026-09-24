import 'package:flutter/material.dart';

import '../auth/branch_placement.dart';
import '../contracts/contracts.dart';
import '../l10n/locale_store.dart';
import 'kit.dart';

/// Asked once per device: which branch is this terminal in?
///
/// Every sale, receipt and count carries a branch (BR-4.3), and an all-branch user —
/// usually the owner, often the person at the counter in a one-shop pharmacy — does not
/// imply one. Guessing would put a day's takings on the wrong shop's books.
///
/// A pharmacy with no branch at all is a new one (AC-1.1): its owner creates the first
/// branch here, since the owner's whole app is this phone.
class BranchPickerScreen extends StatefulWidget {
  const BranchPickerScreen({
    super.key,
    required this.placement,
    required this.onChosen,
    required this.onRetry,
    required this.onSignOut,
    this.canCreate = false,
    this.onCreate,
  });

  final Placement placement;
  final void Function(String id, String name) onChosen;
  final VoidCallback onRetry;
  final VoidCallback onSignOut;
  final bool canCreate;
  final Future<void> Function(String name, String address)? onCreate;

  @override
  State<BranchPickerScreen> createState() => _BranchPickerScreenState();
}

class _BranchPickerScreenState extends State<BranchPickerScreen> {
  final _name = TextEditingController();
  final _address = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onCreate!(_name.text.trim(), _address.text.trim());
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final placement = widget.placement;
    final creating =
        placement is NoBranch && widget.canCreate && widget.onCreate != null;
    return Scaffold(
      body: Column(children: [
        PTopBar(
          title: context.t(creating ? 'branch.firstTitle' : 'branch.title'),
          trailing: [
            PIconButton(
              icon: Icons.logout,
              tooltip: context.t('settings.signOut'),
              onTap: widget.onSignOut,
            ),
          ],
        ),
        Expanded(
          child: PBody(
              children: switch (placement) {
            ChooseBranch(:final branches) => [
                PNotice.text(Tone.blue, Icons.storefront_outlined,
                    context.t('branch.hint')),
                PRows(children: [
                  for (final BranchRef b in branches)
                    PRow(
                      avatar: b.name.characters.first.toUpperCase(),
                      title: b.name,
                      subtitle: b.address,
                      chevron: true,
                      onTap: () => widget.onChosen(b.id, b.name),
                    ),
                ]),
              ],
            NoBranch() when creating => [
                PNotice.text(Tone.green, Icons.storefront_outlined,
                    context.t('branch.firstHint')),
                PField(
                  label: context.t('staff.branchName'),
                  hint: 'e.g. Bole',
                  controller: _name,
                  onChanged: (_) => setState(() {}),
                ),
                PField(
                  label: context.t('staff.branchAddress'),
                  hint: 'e.g. Bole Rd, Addis Ababa',
                  controller: _address,
                ),
                if (_error != null)
                  PNotice.text(Tone.red, Icons.error_outline, _error!),
              ],
            NoBranch() => [
                PNotice.text(
                    Tone.amber, Icons.info_outline, context.t('branch.none')),
              ],
            _ => [
                PNotice.text(Tone.amber, Icons.cloud_off_outlined,
                    context.t('branch.unreachable')),
                PButton(
                    label: context.t('branch.retry'),
                    onPressed: widget.onRetry),
              ],
          }),
        ),
        if (creating)
          PFooter(
            child: PButton(
              label: context.t(_busy ? 'staff.adding' : 'staff.createBranch'),
              onPressed: _busy || _name.text.trim().isEmpty ? null : _create,
            ),
          ),
      ]),
    );
  }
}
