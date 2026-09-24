import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/l10n/locale_store.dart';
import 'package:pharmaet_mobile/l10n/strings.dart';

import '../support/test_db.dart';

/// The language choice (BR-10.1), and what it refuses to store.
///
/// Small, and worth pinning because both of its guards protect against the same thing from
/// opposite sides: an unsupported value reaching the widget tree. One rejects it on the way
/// in, the other on the way out — and the second is what saves a terminal whose stored value
/// was written by an older build that supported a locale this one does not.
void main() {
  late LocalDb db;
  late Directory dir;
  late LocaleStore locales;

  setUp(() async {
    final opened = await openTestDb();
    db = opened.db;
    dir = opened.dir;
    locales = LocaleStore(db);
  });

  tearDown(() async {
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('a fresh terminal is English', () async {
    expect(await locales.load(), 'en');
  });

  test('a choice survives a restart', () async {
    await locales.save('am');

    // The point of storing it in the database rather than the session: a cashier who set
    // Amharic should not set it again every morning, and on a shared counter terminal the
    // previous person's choice must not silently follow them.
    await db.close();
    final reopened = await openTestDb(reuse: dir);
    db = reopened.db;
    expect(await LocaleStore(db).load(), 'am');
  });

  test('every supported locale round-trips', () async {
    for (final locale in Strings.supportedLocales) {
      await locales.save(locale);
      expect(await locales.load(), locale);
    }
  });

  test('an unsupported locale is refused rather than stored', () async {
    await locales.save('am');
    await locales.save('fr');

    // Silently keeping the previous value beats writing one that `Strings.of` cannot resolve.
    expect(await locales.load(), 'am');
  });

  test('a stored value this build no longer supports falls back to English',
      () async {
    // The case the read-side guard exists for: a locale written by a build that supported it,
    // read by one that does not. Without the guard the app would resolve strings against a
    // language it has none of — which is a blank UI on a till, not a missing translation.
    await db.setMeta('locale', 'ti');
    expect(await locales.load(), 'en');
  });
}
