import 'dart:async';

import 'package:flutter/material.dart';

import '../api/tenant_api.dart';
import '../core/permissions.dart';
import '../core/theme.dart';
import '../l10n/locale_store.dart';
import 'kit.dart';
import 'terminal.dart';

/// Branches & staff (prototype screen 18; FR-1, FR-2).
///
/// Access is scoped by role and branch: a cashier's rights never extend beyond their
/// branch. Management writes need a network, and the server enforces the same matrix —
/// what is not offered here is what it would refuse.
class StaffScreen extends StatefulWidget {
  const StaffScreen({super.key});

  @override
  State<StaffScreen> createState() => _StaffScreenState();
}

class _StaffScreenState extends State<StaffScreen> {
  List<BranchInfo>? _branches;
  List<StaffMember>? _staff;
  String? _error;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final t = TerminalScope.read(context);
    try {
      final branches = await t.authed(t.api.branches);
      final staff = t.can(Capability.staffManage)
          ? await t.authed(t.api.staff)
          : const <StaffMember>[];
      if (mounted) {
        setState(() {
          _branches = branches;
          _staff = staff;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = context.t('staff.offline'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = TerminalScope.of(context);
    final branches = _branches;
    final staff = _staff;
    String branchName(String id) =>
        branches
            ?.firstWhere((b) => b.id == id,
                orElse: () => BranchInfo(id: id, name: '—'))
            .name ??
        '—';
    int staffAt(String id) =>
        staff?.where((s) => s.branchIds.contains(id)).length ?? 0;

    return Scaffold(
      body: Column(children: [
        PTopBar(
            title: context.t('staff.title'),
            onBack: () => Navigator.of(context).pop()),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: PBody(children: [
              if (_error != null)
                PNotice.text(Tone.amber, Icons.cloud_off_outlined, _error!),
              PSection(context.t('staff.branches'), first: true),
              if (branches == null && _error == null)
                const Center(child: CircularProgressIndicator())
              else if (branches != null)
                PRows(children: [
                  for (final b in branches)
                    PRow(
                      avatar: b.name.characters.first.toUpperCase(),
                      title: b.name,
                      subtitle:
                          '${b.address ?? ''}${b.address == null ? '' : ' · '}${context.tf('staff.count', {
                            'n': staffAt(b.id)
                          })}',
                    ),
                ]),
              if (t.can(Capability.branchManage)) ...[
                const SizedBox(height: 12),
                PButton(
                  kind: BtnKind.plain,
                  small: true,
                  label: '＋ ${context.t('staff.addBranch')}',
                  onPressed: () async {
                    if (await showBranchForm(context) && mounted) await _load();
                  },
                ),
              ],
              if (t.can(Capability.staffManage)) ...[
                PSection(context.t('staff.staff')),
                if (staff != null)
                  PRows(children: [
                    for (final s in staff)
                      PRow(
                        avatar: s.displayName.characters.first.toUpperCase(),
                        avatarTone: switch (s.role) {
                          'branch_manager' => Tone.blue,
                          'owner' => Tone.green,
                          _ => Tone.green,
                        },
                        title: s.displayName,
                        subtitle: s.branchIds.isEmpty
                            ? context.t('staff.allBranches')
                            : s.branchIds.map(branchName).join(', '),
                        trailing: PBadge(context.t('role.${s.role}'),
                            tone: switch (s.role) {
                              'owner' => Tone.green,
                              'branch_manager' => Tone.blue,
                              _ => Tone.grey,
                            }),
                      ),
                  ]),
                const SizedBox(height: 14),
                PButton(
                  kind: BtnKind.plain,
                  small: true,
                  label: '＋ ${context.t('staff.invite')}',
                  onPressed: branches == null || branches.isEmpty
                      ? null
                      : () async {
                          final added = await showModalBottomSheet<bool>(
                            context: context,
                            isScrollControlled: true,
                            builder: (_) => TerminalScope(
                                terminal: t,
                                child: _InviteSheet(branches: branches)),
                          );
                          if (added == true && mounted) await _load();
                        },
                ),
              ],
            ]),
          ),
        ),
      ]),
    );
  }
}

/// Adds a branch. Also the first thing a newly opened pharmacy does (AC-1.1: "required to
/// create a branch before any inventory/POS action").
Future<bool> showBranchForm(BuildContext context, {bool first = false}) async {
  final t = TerminalScope.read(context);
  final name = TextEditingController();
  final address = TextEditingController();
  final created = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (sheet) => StatefulBuilder(
      builder: (sheet, setSheet) {
        var busy = false;
        String? error;
        return StatefulBuilder(builder: (sheet, set) {
          return Padding(
            padding: EdgeInsets.fromLTRB(
                18, 20, 18, MediaQuery.of(sheet).viewInsets.bottom + 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(sheet.t(first ? 'branch.firstTitle' : 'staff.addBranch'),
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 14),
                PField(
                  label: sheet.t('staff.branchName'),
                  hint: 'e.g. Bole',
                  controller: name,
                  autofocus: true,
                  onChanged: (_) => set(() {}),
                ),
                PField(
                  label: sheet.t('staff.branchAddress'),
                  hint: 'e.g. Bole Rd, Addis Ababa',
                  controller: address,
                ),
                if (error != null)
                  PNotice.text(Tone.red, Icons.error_outline, error!),
                PButton(
                  label: sheet.t('staff.createBranch'),
                  onPressed: busy || name.text.trim().isEmpty
                      ? null
                      : () async {
                          set(() => busy = true);
                          try {
                            await t.authed((token) => t.api.createBranch(token,
                                name: name.text.trim(),
                                address: address.text.trim()));
                            if (sheet.mounted) Navigator.pop(sheet, true);
                          } catch (e) {
                            set(() {
                              busy = false;
                              error = '$e';
                            });
                          }
                        },
                ),
              ],
            ),
          );
        });
      },
    ),
  );
  return created == true;
}

class _InviteSheet extends StatefulWidget {
  const _InviteSheet({required this.branches});
  final List<BranchInfo> branches;

  @override
  State<_InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends State<_InviteSheet> {
  final _name = TextEditingController();
  final _username = TextEditingController();
  final _pin = TextEditingController();
  String _role = 'cashier';
  late String _branch = widget.branches.first.id;
  bool _busy = false;
  String? _error;

  bool get _valid =>
      _name.text.trim().isNotEmpty &&
      RegExp(r'^[a-z0-9._-]{2,}$', caseSensitive: false)
          .hasMatch(_username.text.trim()) &&
      RegExp(r'^\d{4,8}$').hasMatch(_pin.text);

  Future<void> _submit() async {
    final t = TerminalScope.read(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await t.authed((token) => t.api.inviteStaff(token,
          username: _username.text.trim().toLowerCase(),
          displayName: _name.text.trim(),
          role: _role,
          pin: _pin.text,
          branchIds: _role == 'owner' ? const [] : [_branch]));
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(
            18, 20, 18, MediaQuery.of(context).viewInsets.bottom + 18),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(context.t('staff.invite'),
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 14),
              PField(
                  label: context.t('staff.fullName'),
                  controller: _name,
                  onChanged: (_) => setState(() {})),
              PField(
                  label: context.t('login.username'),
                  controller: _username,
                  helper: context.t('staff.usernameHint'),
                  onChanged: (_) => setState(() {})),
              PField(
                label: context.t('staff.role'),
                child: PSegmented<String>(
                  options: [
                    ('cashier', context.t('role.cashier')),
                    ('branch_manager', context.t('role.branch_manager')),
                  ],
                  value: _role,
                  onChanged: (r) => setState(() => _role = r),
                ),
              ),
              PField(
                label: context.t('staff.branch'),
                child: DropdownButtonFormField<String>(
                  initialValue: _branch,
                  items: [
                    for (final b in widget.branches)
                      DropdownMenuItem(value: b.id, child: Text(b.name)),
                  ],
                  onChanged: (b) => setState(() => _branch = b ?? _branch),
                ),
              ),
              PField(
                label: context.t('staff.startPin'),
                controller: _pin,
                keyboardType: TextInputType.number,
                helper: context.t('staff.startPinHint'),
                onChanged: (_) => setState(() {}),
              ),
              if (_error != null)
                PNotice.text(Tone.red, Icons.error_outline, _error!),
              PButton(
                label: context.t(_busy ? 'staff.adding' : 'staff.add'),
                onPressed: _busy || !_valid ? null : _submit,
              ),
              const SizedBox(height: 4),
              const Text('', style: TextStyle(color: PharmaColors.faint)),
            ],
          ),
        ),
      );
}
