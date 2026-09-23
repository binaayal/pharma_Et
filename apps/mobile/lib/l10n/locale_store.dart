import 'package:flutter/widgets.dart';

import '../data/local_db.dart';
import 'strings.dart';

/// Persists the user's language choice (BR-10.1: switchable per user).
///
/// Stored in the local database rather than in the session, so it survives sign-out and a
/// restart. A cashier who set the app to Amharic should not have to set it again every
/// morning — and definitely not on a shared counter terminal where the previous person's
/// choice would otherwise stick.
class LocaleStore {
  LocaleStore(this._db);

  final LocalDb _db;
  static const _key = 'locale';

  Future<String> load() async {
    final stored = await _db.meta(_key);
    return Strings.supportedLocales.contains(stored) ? stored! : 'en';
  }

  Future<void> save(String locale) async {
    if (!Strings.supportedLocales.contains(locale)) return;
    await _db.setMeta(_key, locale);
  }
}

/// Makes the active [Strings] available to the widget tree.
///
/// An InheritedWidget rather than a package: the app needs one value read in many places
/// and changed rarely, which is precisely what this is for.
class L10n extends InheritedWidget {
  const L10n(
      {super.key,
      required this.strings,
      required this.onChange,
      required super.child});

  final Strings strings;
  final void Function(String locale) onChange;

  static L10n of(BuildContext context) {
    final found = context.dependOnInheritedWidgetOfExactType<L10n>();
    assert(found != null, 'L10n is missing from the widget tree');
    return found!;
  }

  /// `context.t('pos.title')` at the call site.
  static String t(BuildContext context, String key) =>
      of(context).strings.get(key);

  @override
  bool updateShouldNotify(L10n oldWidget) =>
      oldWidget.strings.locale != strings.locale;
}

extension L10nContext on BuildContext {
  Strings get l10n => L10n.of(this).strings;
  String t(String key) => L10n.of(this).strings.get(key);
}
