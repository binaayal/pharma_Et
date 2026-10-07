import 'dart:convert';

import 'package:flutter/services.dart';

/// One medicine from the list the app ships with: a generic name at one strength in one
/// dosage form — "Amoxicillin 500mg capsule" — which is the thing a pharmacy stocks.
class MedicineEntry {
  const MedicineEntry({
    required this.name,
    required this.unit,
    this.generic = '',
    this.form = '',
    this.strength = '',
    this.category = '',
  });

  factory MedicineEntry.fromJson(Map<String, dynamic> json) => MedicineEntry(
        name: json['n'] as String,
        unit: (json['u'] as String?) ?? 'piece',
        generic: (json['g'] as String?) ?? '',
        form: (json['f'] as String?) ?? '',
        strength: (json['s'] as String?) ?? '',
        category: (json['c'] as String?) ?? '',
      );

  /// What goes in the product's name field.
  final String name;

  /// What one of them is counted in — the suggested base unit (FR-11).
  final String unit;
  final String generic;
  final String form;
  final String strength;

  /// The list's own therapeutic heading, shown under the name to tell near-twins apart.
  final String category;
}

/// The medicines list bundled with the app (FR-12).
///
/// EFDA publishes the Ethiopian Essential Medicines List; `scripts/build-medicines-catalogue.py`
/// turns it into `assets/catalogue/medicines.json`. It is here so that an owner setting up a
/// shop picks "Amoxicillin 500mg capsule" after three letters instead of typing a thousand
/// product names — and it is **only a suggestion list**:
///
///   - it is not the pharmacy's catalogue. Nothing is a product until the owner adds it
///     with a price; the list has no prices and no pack sizes.
///   - it never marks anything controlled. That is a regulatory fact (A-1), not a name.
///   - a medicine that is not on it is typed in exactly as before.
///
/// Bundled, not downloaded: setting up a shop must not need a network that is not there.
class MedicineCatalogue {
  MedicineCatalogue(this.source, List<MedicineEntry> entries)
      : _entries = entries,
        _words = [
          for (final e in entries) _wordsOf(e.name),
        ];

  /// An empty list. What a failed load degrades to: the form still works, it just has
  /// nothing to suggest.
  static final MedicineCatalogue empty = MedicineCatalogue('', const []);

  static const assetPath = 'assets/catalogue/medicines.json';

  /// Which edition this is, for the line under the suggestions.
  final String source;
  final List<MedicineEntry> _entries;
  final List<List<String>> _words;

  int get length => _entries.length;

  static Future<MedicineCatalogue>? _loading;

  /// The list, once it has been read — so a form opened a second time has its suggestions
  /// on the first frame rather than a moment later.
  static MedicineCatalogue? get cached => _cached;
  static MedicineCatalogue? _cached;

  /// Loads the bundled list once and keeps it. Never throws: a list that cannot be read
  /// must not be the reason an owner cannot add a product.
  static Future<MedicineCatalogue> load({AssetBundle? bundle}) =>
      _loading ??= _read(bundle ?? rootBundle);

  /// For tests: replaces (or with null, forgets) the loaded list.
  static void debugSet(MedicineCatalogue? catalogue) {
    _cached = catalogue;
    _loading = null;
  }

  static Future<MedicineCatalogue> _read(AssetBundle bundle) async {
    try {
      return _cached = parse(await bundle.loadString(assetPath));
    } catch (_) {
      return empty;
    }
  }

  static MedicineCatalogue parse(String json) {
    final data = jsonDecode(json) as Map<String, dynamic>;
    return MedicineCatalogue(
      (data['source'] as String?) ?? '',
      (data['medicines'] as List<dynamic>)
          .map((e) => MedicineEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  static List<String> _wordsOf(String text) => text
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9.%]+'))
      .where((w) => w.isNotEmpty)
      .toList();

  /// Medicines matching what has been typed so far, best first.
  ///
  /// Every typed word must begin some word of the name, in any order — so `amox 500`
  /// finds "Amoxicillin 500mg capsule" and `500 amox` does too. Names that *start* with
  /// the query come first, then shorter names: the plain tablet before the combination.
  ///
  /// [exclude] holds names already in the pharmacy's catalogue (lower-cased), so the list
  /// does not offer to add a product twice.
  List<MedicineEntry> search(String query,
      {int limit = 6, Set<String> exclude = const {}}) {
    final typed = _wordsOf(query);
    // Two letters before suggesting anything: one letter matches half the list.
    if (typed.isEmpty || query.trim().length < 2) return const [];
    final lowered = query.trim().toLowerCase();

    final hits = <(int, MedicineEntry)>[];
    for (var i = 0; i < _entries.length; i++) {
      final entry = _entries[i];
      final words = _words[i];
      if (!typed.every((t) => words.any((w) => w.startsWith(t)))) continue;
      if (exclude.contains(entry.name.toLowerCase())) continue;
      final rank = entry.name.toLowerCase().startsWith(lowered)
          ? 0
          : words.first.startsWith(typed.first)
              ? 1
              : 2;
      hits.add((rank, entry));
    }
    hits.sort((a, b) {
      final byRank = a.$1.compareTo(b.$1);
      if (byRank != 0) return byRank;
      final byLength = a.$2.name.length.compareTo(b.$2.name.length);
      return byLength != 0 ? byLength : a.$2.name.compareTo(b.$2.name);
    });
    return [for (final hit in hits.take(limit)) hit.$2];
  }
}
