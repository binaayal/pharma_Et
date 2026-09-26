import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/l10n/strings.dart';

/// FR-10 / BR-10.1 / AC-10.1 — Amharic and English, switchable per user.
void main() {
  test('every English key has an Amharic counterpart', () {
    // The failure this prevents is a string added in English and forgotten in Amharic,
    // which shows an Amharic speaker a screen that is half in a language they did not
    // choose. Keeping both maps in one file makes it likely; this makes it certain.
    final missing = <String>[];
    for (final key in _allKeys(Strings.en)) {
      if (Strings.am.get(key) == Strings.en.get(key) &&
          !_intentionallyShared.contains(key)) {
        missing.add(key);
      }
    }
    expect(missing, isEmpty,
        reason: 'untranslated keys: ${missing.join(', ')}');
  });

  test('an unknown locale falls back to English rather than throwing', () {
    // A cached locale from an older build must never stop the till from opening.
    expect(Strings.of('fr').locale, 'en');
    expect(Strings.of('').get('pos.title'), 'Sell');
  });

  test('an unknown key returns the key rather than crashing the screen', () {
    expect(Strings.en.get('nope.nothing.here'), 'nope.nothing.here');
  });

  test('Amharic strings are actually in Ethiopic script', () {
    // Catches a copy-paste that left English in the Amharic map.
    final ethiopic = RegExp(r'[ሀ-፿]');
    for (final key in [
      'pos.title',
      'cashup.title',
      'login.signIn',
      'shift.openTill'
    ]) {
      expect(Strings.am.get(key), matches(ethiopic),
          reason: '$key is not in Ethiopic');
    }
  });

  test('dates render in the Ethiopian calendar in both languages (BR-10.2)',
      () {
    final instant = DateTime.utc(2026, 9, 23, 12);
    expect(Strings.am.date(instant), 'መስከረም 13፣ 2019');
    expect(Strings.en.date(instant), 'Meskerem 13, 2019');
  });

  test('both languages carry the same placeholders', () {
    // A placeholder missing from one side renders as a literal "{n}" to that reader, and
    // only to that reader — the English screen looks perfect.
    final pattern = RegExp(r'\{(\w+)\}');
    Set<String> holes(String text) =>
        pattern.allMatches(text).map((m) => m.group(1)!).toSet();
    for (final key in _knownKeys) {
      expect(holes(Strings.am.get(key)), holes(Strings.en.get(key)),
          reason: key);
    }
    expect(Strings.en.f('count.fewer', {'n': 2}),
        '2 fewer than the system thought');
    expect(Strings.am.f('count.fewer', {'n': 2}), 'ሲስተሙ ካሰበው 2 ያንሳል');
  });

  test('an expiry date is a calendar date, whatever the time zone', () {
    // 30 Sep 2027 is Meskerem 19, 2020 (Enkutatash falls on 12 Sep before a Gregorian leap
    // year). Read as an instant it came out as Meskerem 18 on a phone in Addis Ababa —
    // local midnight there is still the 29th in UTC. Run under TZ=Africa/Addis_Ababa too.
    expect(Strings.en.calendarDate('2027-09-30'), 'Meskerem 19, 2020');
    expect(Strings.am.calendarDate('2027-09-30'), 'መስከረም 19፣ 2020');
    // The picker hands back a local DateTime; its ISO form must mean the same day.
    expect(
      Strings.en.calendarDate(DateTime(2027, 9, 30).toIso8601String()),
      'Meskerem 19, 2020',
    );
  });

  test('times use the 24-hour clock in both', () {
    // Ethiopian clock time starts the day at dawn and is how people speak — but tills and
    // receipts in Ethiopian pharmacies use the 24-hour clock, so this follows practice.
    final instant = DateTime.utc(2026, 9, 23, 13, 45).toLocal();
    expect(Strings.am.time(instant), matches(RegExp(r'^\d{2}:\d{2}$')));
    expect(Strings.en.time(instant), Strings.am.time(instant));
  });

  test('both supported locales resolve', () {
    for (final locale in Strings.supportedLocales) {
      expect(Strings.of(locale).locale, locale);
    }
  });
}

/// Keys where English and Amharic are legitimately identical — none yet, but the list keeps
/// the completeness test honest when one appears (a brand name, say) rather than tempting
/// someone to weaken the assertion.
const _intentionallyShared = <String>{};

Iterable<String> _allKeys(Strings strings) sync* {
  for (final key in _knownKeys) {
    yield key;
  }
}

/// Enumerated because the maps are private. Adding a string without adding it here means it
/// is untested, which is a smaller failure than an untranslated string reaching a user.
const _knownKeys = [
  'app.name',
  'app.tagline',
  'login.pharmacyCode',
  'login.username',
  'login.pin',
  'login.password',
  'login.usePassword',
  'login.usePin',
  'login.signIn',
  'login.signingIn',
  'login.failed',
  'pos.title',
  'pos.total',
  'pos.takeCash',
  'pos.perUnit',
  'pos.controlled',
  'pos.controlledLater',
  'pos.noCatalog',
  'pos.noCatalogHint',
  'pos.offlineBanner',
  'pos.saleCommitted',
  'pos.savedLocally',
  'shift.noTill',
  'shift.openTill',
  'shift.openTitle',
  'shift.openingFloat',
  'shift.openingFloatHint',
  'shift.cancel',
  'shift.open',
  'cashup.title',
  'cashup.thisShift',
  'cashup.opened',
  'cashup.sales',
  'cashup.float',
  'cashup.countDrawer',
  'cashup.countHint',
  'cashup.counted',
  'cashup.note',
  'cashup.noteHint',
  'cashup.record',
  'cashup.recording',
  'cashup.expected',
  'cashup.difference',
  'cashup.balanced',
  'cashup.short',
  'cashup.over',
  'cashup.closedOk',
  'cashup.closedVariance',
  'cashup.unsyncedWarning',
  'sync.synced',
  'sync.syncing',
  'sync.upToDate',
  'sync.waiting',
  'sync.queued',
  'sync.needsAttention',
  'settings.language',
  'settings.signOut',
  'branch.title',
  'branch.hint',
  'branch.none',
  'branch.unreachable',
  'branch.retry',
  'common.cancel',
  'common.continue',
  'stock.menu',
  'stock.receive',
  'stock.count',
  'stock.lotExpires',
  'receive.supplier',
  'receive.supplierHint',
  'receive.lines',
  'receive.add',
  'receive.noProducts',
  'receive.lineCost',
  'receive.totalCost',
  'receive.saving',
  'receive.record',
  'receive.savedHint',
  'receive.done',
  'receive.addLineTitle',
  'receive.product',
  'receive.lotNo',
  'receive.expiry',
  'receive.qty',
  'receive.unitCost',
  'receive.addLine',
  'count.oversold',
  'count.empty',
  'count.systemSays',
  'count.howMany',
  'count.howManyHint',
  'count.fewer',
  'count.more',
  'count.reason',
  'count.noteRequired',
  'count.noteOptional',
  'count.noteNeeded',
  'count.noteHint',
  'count.record',
  'reason.recount',
  'reason.damage',
  'reason.expiryWriteoff',
  'reason.theftOrLoss',
  'reason.receiptCorrection',
  'reason.other',
  'expired.title',
  'expired.body',
  'expired.mayOverride',
  'expired.cannotOverride',
  'expired.doNot',
  'expired.authorise',
  'sync.signInAgain',
  'sync.status',
  'recovery.title',
  'recovery.body',
  'recovery.lost',
  'recovery.kept',
  'recovery.ack',
  'common.done',
  'tab.home',
  'tab.sell',
  'tab.stock',
  'tab.reports',
  'tab.more',
  'role.owner',
  'role.branch_manager',
  'role.cashier',
  'sync.offline',
  'login.welcomeBack',
  'login.noConnection',
  'login.notYou',
  'login.newPharmacy',
  'login.requestAccount',
  'request.title',
  'request.notice',
  'request.pharmacy',
  'request.owner',
  'request.phone',
  'request.phoneHint',
  'request.city',
  'request.branches',
  'request.send',
  'request.sending',
  'request.sentTitle',
  'request.sentBody',
  'request.sentBody2',
  'request.back',
  'home.todayAll',
  'home.today',
  'home.thisDevice',
  'home.onThisDevice',
  'home.sales',
  'home.asOf',
  'home.shift',
  'home.closed',
  'home.opened',
  'home.toSync',
  'home.attention',
  'home.quickActions',
  'home.expiring',
  'home.expiringSub',
  'home.negative',
  'home.negativeSub',
  'home.awaitingCashup',
  'home.tillOpen',
  'home.since',
  'home.closeWhenDone',
  'home.syncAttention',
  'home.syncAttentionSub',
  'home.allClear',
  'home.receive',
  'shift.noTillTitle',
  'shift.tapToOpen',
  'shift.opened',
  'pos.offlineTooLong',
  'sell.title',
  'sell.search',
  'sell.noBatch',
  'sell.expiredAuthorised',
  'sell.oversell',
  'sell.subtotal',
  'sell.items',
  'sell.totalEtb',
  'sell.charge',
  'sell.addToStart',
  'sell.less',
  'sell.more',
  'pay.title',
  'pay.due',
  'pay.method',
  'pay.cash',
  'pay.other',
  'pay.manualNotice',
  'pay.received',
  'pay.receivedShort',
  'pay.dueShort',
  'pay.change',
  'pay.notEnough',
  'pay.complete',
  'pay.saving',
  'receipt.title',
  'receipt.paid',
  'receipt.sale',
  'receipt.change',
  'receipt.paidBy',
  'receipt.queued',
  'receipt.synced',
  'receipt.print',
  'receipt.noPrinter',
  'receipt.newSale',
  'stock.title',
  'stock.search',
  'stock.searchHint',
  'stock.all',
  'stock.low',
  'stock.expiring',
  'stock.controlled',
  'stock.ledgerTracked',
  'stock.batches',
  'stock.noBatches',
  'stock.nearest',
  'stock.exp',
  'stock.lot',
  'stock.inStock',
  'stock.negative',
  'stock.oversold',
  'stock.reconcile',
  'stock.nothingHere',
  'product.price',
  'product.batchesFefo',
  'product.nextOut',
  'product.expired',
  'product.adjust',
  'receive.title',
  'receive.items',
  'receive.addItem',
  'receive.each',
  'receive.remove',
  'receive.expiryHint',
  'receive.batchNotice',
  'receive.confirm',
  'cashup.shiftClose',
  'cashup.noShift',
  'cashup.cashSales',
  'cashup.expectedInDrawer',
  'cashup.attributed',
  'reports.title',
  'reports.today',
  'reports.week',
  'reports.month',
  'reports.salesAll',
  'reports.sales',
  'reports.avg',
  'reports.variance',
  'reports.itemsSold',
  'reports.reports',
  'reports.salesSummary',
  'reports.salesSummarySub',
  'reports.stockExpiry',
  'reports.stockExpirySub',
  'reports.ledger',
  'reports.ledgerSub',
  'reports.ledgerGate',
  'reports.cashup',
  'reports.cashupSub',
  'reports.currency',
  'reports.currencyNone',
  'reports.offline',
  'reports.total',
  'reports.items',
  'reports.otherTender',
  'reports.byBranch',
  'reports.noSales',
  'reports.shiftsShort',
  'reports.notCounted',
  'reports.shifts',
  'reports.noShifts',
  'reports.open',
  'reports.notCountedShort',
  'reports.of',
  'staff.title',
  'staff.branches',
  'staff.staff',
  'staff.count',
  'staff.allBranches',
  'staff.addBranch',
  'staff.invite',
  'staff.offline',
  'staff.branchName',
  'staff.branchAddress',
  'staff.createBranch',
  'staff.fullName',
  'staff.usernameHint',
  'staff.role',
  'staff.branch',
  'staff.startPin',
  'staff.startPinHint',
  'staff.add',
  'staff.adding',
  'branch.firstTitle',
  'branch.firstHint',
  'settings.title',
  'settings.sync',
  'settings.syncNow',
  'settings.lastSynced',
  'settings.pending',
  'settings.pendingSub',
  'settings.account',
  'settings.footer',
  'sub.title',
  'sub.unknown',
  'sub.month',
  'sub.state.active',
  'sub.state.pending',
  'sub.state.suspended',
  'sub.endedTitle',
  'sub.endedBody',
  'sub.tapToPay',
  'sub.submitProof',
  'sub.continueTill',
  'sub.submitTitle',
  'sub.howToPay',
  'sub.method',
  'sub.reference',
  'sub.amount',
  'sub.screenshot',
  'sub.tapUpload',
  'sub.submitForReview',
  'sub.sending',
  'sub.sentTitle',
  'sub.sentBody',
  'sub.awaiting',
  'shift.noTillSub',
  'product.inStock',
  'product.movement',
  'move.sale',
  'move.receipt',
  'move.count',
  'dispense.title',
  'dispense.subtitle',
  'dispense.isPsychotropic',
  'dispense.rxNumber',
  'dispense.prescriber',
  'dispense.issued',
  'dispense.issuedHint',
  'dispense.validOk',
  'dispense.daysUsed',
  'dispense.limit',
  'dispense.blocked',
  'dispense.expired',
  'dispense.future',
  'dispense.onePerRx',
  'dispense.needNumber',
  'dispense.provisional',
  'dispense.record',
  'dispense.recorded',
  'ledger.allControlled',
  'ledger.immutable',
  'ledger.appendOnly',
  'ledger.projected',
  'ledger.events',
  'ledger.none',
  'ledger.offline',
  'ledger.dispensed',
  'ledger.received',
  'ledger.adjusted',
  'ledger.export',
  'ledger.exporting',
  'ledger.exportSubject',
];
