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
];
