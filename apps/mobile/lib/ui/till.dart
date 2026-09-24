import 'dart:async';

import 'package:flutter/material.dart';

import '../core/money.dart';
import '../l10n/locale_store.dart';
import 'kit.dart';
import 'terminal.dart';

/// Opening the till asks for the float already in the drawer.
///
/// It is part of the expected figure at close, so skipping it would report a variance equal
/// to the float on every shift — and a control that is always wrong is one that gets ignored.
Future<void> openTill(BuildContext context) async {
  final terminal = TerminalScope.read(context);
  final controller = TextEditingController(text: '0');
  final confirmed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (sheet) => Padding(
      padding: EdgeInsets.fromLTRB(
          18, 20, 18, MediaQuery.of(sheet).viewInsets.bottom + 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(sheet.t('shift.openTitle'),
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(sheet.t('shift.openingFloatHint'),
              style: const TextStyle(fontSize: 13.5, height: 1.45)),
          const SizedBox(height: 16),
          PField(
            label: sheet.t('shift.openingFloat'),
            controller: controller,
            autofocus: true,
            large: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          PButton(
              label: sheet.t('shift.open'),
              onPressed: () => Navigator.pop(sheet, true)),
        ],
      ),
    ),
  );
  if (confirmed != true) return;

  final santim = parseBirr(controller.text) ?? 0;
  await terminal.shifts.openShift(
    userId: terminal.session.scope.userId,
    branchId: terminal.branchId,
    openingFloatSantim: santim,
  );
  await terminal.refresh();
  // The shift is queued like a sale; push it now rather than on the next tick.
  unawaited(terminal.sync());
  if (context.mounted) {
    toast(context, '${context.t('shift.opened')} · ${formatEtb(santim)}');
  }
}
