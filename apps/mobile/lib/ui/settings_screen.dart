import 'package:flutter/material.dart';

import '../core/money.dart';
import '../core/permissions.dart';
import '../core/theme.dart';
import '../l10n/locale_store.dart';
import 'backup_screen.dart';
import 'cash_up_screen.dart';
import 'customers_screen.dart';
import 'suppliers_screen.dart';
import 'summary_delivery_screen.dart';
import 'delete_account_screen.dart';
import 'help_screen.dart';
import 'kit.dart';
import 'links.dart';
import 'staff_screen.dart';
import 'subscription_screens.dart';
import 'sync_chip.dart';
import 'terminal.dart';

/// Settings — the "More" tab (prototype screen 19; FR-10).
///
/// The language labels are always bilingual. Someone who cannot read the language the app
/// is currently in still has to be able to find the switch.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = TerminalScope.of(context);
    final l10n = L10n.of(context);
    final (syncLabel, _) = SyncChip.describe(context, t.status);
    final sub = t.subscription;

    return Column(children: [
      // Bilingual on purpose and in both languages, as the prototype titles it: whoever
      // cannot read the current language must still recognise where they are.
      const PTopBar(title: 'Settings  /  ማስተካከያ'),
      Expanded(
        child: PBody(children: [
          const PSection('Language / ቋንቋ', first: true),
          PSegmented<String>(
            options: const [('en', 'English'), ('am', 'አማርኛ')],
            value: l10n.strings.locale,
            onChanged: l10n.onChange,
          ),
          PSection(context.t('settings.sync')),
          PRows(children: [
            PRow(
              title: context.t('settings.syncNow'),
              subtitle: t.status.lastSyncedAt == null
                  ? syncLabel
                  : '${context.t('settings.lastSynced')} ${context.l10n.time(t.status.lastSyncedAt!)}',
              trailing: SyncChip(status: t.status),
              onTap: t.sync,
            ),
            PRow(
              title: context.t('settings.pending'),
              subtitle:
                  context.tf('settings.pendingSub', {'n': t.status.pending}),
              value: '${t.status.pending}',
              valueColor: t.status.pending > 0 ? PharmaColors.amber : null,
            ),
            if (t.canBackUp)
              PRow(
                title: context.t('backup.title'),
                subtitle: context.t('backup.sub'),
                avatarIcon: Icons.save_alt,
                // Amber when there is something on this phone that exists nowhere else.
                avatarTone: t.status.pending > 0 ? Tone.amber : Tone.green,
                chevron: true,
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => const BackupScreen())),
              ),
          ]),
          PSection(context.t('settings.account')),
          PRows(children: [
            if (t.canTakeCredit)
              PRow(
                title: context.t('credit.title'),
                subtitle: context.t('credit.sub'),
                avatarIcon: Icons.menu_book_outlined,
                avatarTone: Tone.amber,
                chevron: true,
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => const CustomersScreen())),
              ),
            if (t.canSeeSuppliers)
              PRow(
                title: context.t('supplier.title'),
                subtitle: context.t('supplier.sub'),
                avatarIcon: Icons.local_shipping_outlined,
                avatarTone: Tone.blue,
                chevron: true,
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => const SuppliersScreen())),
              ),
            PRow(
              title: t.session.scope.displayName,
              subtitle:
                  '${context.t('role.${t.role}')} · ${t.session.tenantCode}${t.branchName == null ? '' : ' · ${t.branchName}'}',
            ),
            if (t.shift != null && t.can(Capability.cashupPerform))
              PRow(
                title: context.t('cashup.title'),
                subtitle: context.t('home.closeWhenDone'),
                chevron: true,
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => const CashUpScreen())),
              ),
            if (t.can(Capability.staffManage) || t.can(Capability.branchManage))
              PRow(
                title: context.t('staff.title'),
                chevron: true,
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => const StaffScreen())),
              ),
            if (t.can(Capability.settingsConfigure))
              PRow(
                title: context.t('tg.title'),
                subtitle: context.t('tg.sub'),
                avatarIcon: Icons.send_outlined,
                avatarTone: Tone.blue,
                chevron: true,
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => const SummaryDeliveryScreen())),
              ),
            if (t.can(Capability.settingsConfigure))
              PRow(
                title: context.t('sub.title'),
                subtitle: sub == null
                    ? context.t('sub.unknown')
                    : '${context.t('sub.state.${sub.state}')} · ${formatEtbShort(sub.priceSantim)}/${context.t('sub.month')}',
                trailing: sub == null
                    ? null
                    : PBadge(context.t('sub.state.${sub.state}'),
                        tone: switch (sub.state) {
                          'active' => Tone.green,
                          'suspended' => Tone.red,
                          _ => Tone.amber,
                        }),
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => sub?.suspended == true
                        ? const SubscriptionEndedScreen()
                        : const PaymentProofScreen())),
              ),
            PRow(
              title: context.t('help.open'),
              subtitle: context.t('help.openSub'),
              avatarIcon: Icons.help_outline,
              chevron: true,
              onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const HelpScreen())),
            ),
            PRow(
              title: context.t('settings.privacy'),
              avatarIcon: Icons.privacy_tip_outlined,
              chevron: true,
              onTap: () =>
                  openLink(context, privacyPolicyUrl(context.l10n.locale)),
            ),
            if (t.role == 'owner')
              PRow(
                title: context.t('settings.deleteAccount'),
                avatarIcon: Icons.delete_outline,
                avatarTone: Tone.red,
                chevron: true,
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => const DeleteAccountScreen())),
              ),
            PRow(
              title: context.t('settings.signOut'),
              titleColor: PharmaColors.red,
              onTap: t.onSignOut,
            ),
          ]),
          const SizedBox(height: 18),
          Text(
            context.t('settings.footer'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: PharmaColors.faint, fontSize: 12),
          ),
        ]),
      ),
    ]);
  }
}
