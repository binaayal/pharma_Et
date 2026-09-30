import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../l10n/locale_store.dart';
import 'kit.dart';
import 'links.dart';

/// Delete account (App Store guideline 5.1.1(v); Google Play account-deletion policy).
///
/// A pharmacy account is not deleted by a button. It holds records Ethiopian pharmacy law
/// may oblige the pharmacy to keep, and it is the one thing an unhappy ex-employee with the
/// owner's phone would most like to destroy. So the owner starts it here, and PharmaEt
/// confirms by calling the owner's registered number — the customer-service step both
/// stores allow for regulated services. The screen says exactly what is deleted and what is
/// kept, before anyone calls.
class DeleteAccountScreen extends StatelessWidget {
  const DeleteAccountScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final locale = context.l10n.locale;
    return Scaffold(
      body: Column(children: [
        PTopBar(
            title: context.t('delete.title'),
            onBack: () => Navigator.of(context).pop()),
        Expanded(
          child: PBody(children: [
            PNotice.text(
                Tone.amber, Icons.info_outline, context.t('delete.intro')),
            PSection(context.t('delete.deletedTitle'), first: true),
            Text(context.t('delete.deleted'),
                style: const TextStyle(fontSize: 13.5, height: 1.55)),
            PSection(context.t('delete.keptTitle')),
            Text(context.t('delete.kept'),
                style: const TextStyle(fontSize: 13.5, height: 1.55)),
            PSection(context.t('delete.staffTitle')),
            Text(context.t('delete.staff'),
                style: const TextStyle(
                    fontSize: 13.5, height: 1.55, color: PharmaColors.muted)),
            const SizedBox(height: 14),
            TextButton.icon(
              onPressed: () => openLink(context, deleteAccountUrl(locale)),
              icon: const Icon(Icons.open_in_new, size: 18),
              label: Text(context.t('delete.readMore')),
            ),
          ]),
        ),
        PFooter(
          child: PButton(
            kind: BtnKind.warn,
            icon: Icons.call,
            label: context.t('delete.call'),
            onPressed: () => openLink(context, supportTel),
          ),
        ),
      ]),
    );
  }
}
