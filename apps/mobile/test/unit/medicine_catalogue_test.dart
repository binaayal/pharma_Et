import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/data/medicine_catalogue.dart';

/// FR-12 — the medicines list the app ships with.
///
/// Two things are held here. The **file**: it is generated from EFDA's list by a parser
/// reading a PDF, and a parser reading a PDF fails quietly — a column that drifts turns a
/// footnote into a product. And the **search**, which is the whole feature: an owner finds
/// a medicine in three letters or goes back to typing every name.
void main() {
  group('the bundled file', () {
    late Map<String, dynamic> data;
    late List<Map<String, dynamic>> medicines;

    setUpAll(() {
      data = jsonDecode(File(MedicineCatalogue.assetPath).readAsStringSync())
          as Map<String, dynamic>;
      medicines = (data['medicines'] as List<dynamic>).cast();
    });

    test('says which edition it came from', () {
      expect(data['source'], contains('Essential Medicines List'));
      expect(data['count'], medicines.length);
    });

    test('is a real catalogue, not a handful of rows', () {
      // The 2024 list has roughly 500 generics in several forms and strengths each. A
      // number far below this means the parser lost the table.
      expect(medicines.length, greaterThan(1000));
      expect(medicines.map((m) => m['g']).toSet().length, greaterThan(400));
    });

    test('every entry has a name and a unit, and no name is offered twice', () {
      final names = <String>{};
      for (final m in medicines) {
        final name = m['n'] as String;
        expect(name.trim(), isNotEmpty);
        expect((m['u'] as String).trim(), isNotEmpty, reason: name);
        expect(names.add(name.toLowerCase()), isTrue,
            reason: 'duplicate: $name');
      }
    });

    test('no entry is a paragraph that slipped out of a footnote', () {
      for (final m in medicines) {
        final name = m['n'] as String;
        expect(name.length, lessThanOrEqualTo(110), reason: name);
        expect(name, isNot(contains('*')), reason: name);
        expect(name, isNot(contains('NB:')), reason: name);
        expect(name, isNot(contains('should be used')), reason: name);
        // The WHO antibiotic grouping is for prescribers, not for a till.
        expect(name, isNot(matches(RegExp(r'\((Access|Watch|Reserve)\)'))),
            reason: name);
      }
    });

    test('carries no price, no pack and no controlled flag', () {
      // The list has none of these, and inventing them would be worse than leaving them
      // out: a guessed price is charged, and "controlled" is a regulatory fact (A-1).
      for (final m in medicines) {
        expect(
            m.keys.toSet().difference({'n', 'g', 'f', 's', 'u', 'c'}), isEmpty,
            reason: '${m['n']}');
      }
    });

    test('the medicines a counter sells every day are on it', () {
      final all =
          medicines.map((m) => (m['n'] as String).toLowerCase()).toList();
      for (final expected in [
        'paracetamol 500mg tablet',
        'metformin 500mg tablet',
        'amoxicillin 500mg capsule',
        'omeprazole 20 mg tablet/capsule',
        'amoxicillin 250mg capsule',
      ]) {
        expect(all, contains(expected));
      }
    });

    test('a tablet is counted in tablets, a syrup in bottles, a cream in tubes',
        () {
      String unitOf(String name) => medicines.firstWhere(
          (m) => (m['n'] as String).toLowerCase() == name)['u'] as String;
      expect(unitOf('paracetamol 500mg tablet'), 'tablet');
      expect(unitOf('amoxicillin 500mg capsule'), 'capsule');
      expect(unitOf('paracetamol (acetaminophen) 125mg/5ml syrup'), 'bottle');
      expect(unitOf('diclofenac 1%w/w gel'), 'tube');
      // "pen" must not match inside "suspension".
      expect(
          medicines.where((m) =>
              (m['f'] as String).toLowerCase().contains('suspension') &&
              m['u'] == 'pen'),
          isEmpty);
    });

    test('parses through the loader the app uses', () {
      final catalogue = MedicineCatalogue.parse(
          File(MedicineCatalogue.assetPath).readAsStringSync());
      expect(catalogue.length, medicines.length);
      expect(
          catalogue.search('amox 500').first.name, startsWith('Amoxicillin'));
    });
  });

  test('is declared in the app bundle, so a phone actually has it', () async {
    // The file existing on disk proves nothing about the APK: an asset missing from
    // pubspec.yaml is simply absent on the device, and the form would quietly suggest
    // nothing. This loads it the way the app does.
    TestWidgetsFlutterBinding.ensureInitialized();
    MedicineCatalogue.debugSet(null);
    final catalogue = await MedicineCatalogue.load(bundle: rootBundle);
    expect(catalogue.length, greaterThan(1000));
    expect(MedicineCatalogue.cached, same(catalogue));
    MedicineCatalogue.debugSet(null);
  });

  group('search', () {
    final catalogue = MedicineCatalogue('test', const [
      MedicineEntry(name: 'Amoxicillin 250mg capsule', unit: 'capsule'),
      MedicineEntry(name: 'Amoxicillin 500mg capsule', unit: 'capsule'),
      MedicineEntry(
          name: 'Amoxicillin + Clavulanic acid 500mg + 125mg tablet',
          unit: 'tablet'),
      MedicineEntry(name: 'Paracetamol 500mg tablet', unit: 'tablet'),
      MedicineEntry(name: 'Co-amoxiclav 625mg tablet', unit: 'tablet'),
      MedicineEntry(name: 'Zinc sulfate 20mg tablet', unit: 'tablet'),
    ]);

    List<String> names(String q, {Set<String> exclude = const {}}) =>
        [for (final e in catalogue.search(q, exclude: exclude)) e.name];

    test('finds a medicine from its first few letters', () {
      expect(names('amox'), contains('Amoxicillin 500mg capsule'));
      expect(names('para'), ['Paracetamol 500mg tablet']);
    });

    test('narrows by strength, in either order', () {
      expect(names('amox 500').first, 'Amoxicillin 500mg capsule');
      expect(names('500 amox').first, 'Amoxicillin 500mg capsule');
      expect(names('amox 250'), ['Amoxicillin 250mg capsule']);
    });

    test('puts the plain medicine before its combinations', () {
      final found = names('amox');
      expect(
          found.indexOf('Amoxicillin 250mg capsule'),
          lessThan(found
              .indexOf('Amoxicillin + Clavulanic acid 500mg + 125mg tablet')));
      // A name with the letters in a later word is still found — "amox" should reach
      // co-amoxiclav — but after everything that starts with them.
      expect(found.last, 'Co-amoxiclav 625mg tablet');
      // Mid-word is not a match at all: prefix matching is what keeps three letters from
      // returning half the list.
      expect(names('cillin'), isEmpty);
    });

    test('is not case sensitive', () {
      expect(names('PARA'), names('para'));
    });

    test('suggests nothing for one letter, or for nothing', () {
      expect(names(''), isEmpty);
      expect(names(' '), isEmpty);
      expect(names('a'), isEmpty);
    });

    test('suggests nothing for a medicine that is not on the list', () {
      expect(names('xyzolam'), isEmpty);
    });

    test('does not offer what the pharmacy already sells', () {
      expect(names('para', exclude: {'paracetamol 500mg tablet'}), isEmpty);
    });

    test('caps the list, so it never pushes the price field off the screen',
        () {
      expect(catalogue.search('a', limit: 2), isEmpty);
      expect(catalogue.search('amox', limit: 2).length, 2);
    });

    test('browsing with nothing typed is the whole list, in its own order', () {
      final all = catalogue.browse('');
      expect(all.length, catalogue.length);
      expect(all.first.name, catalogue.browse('  ').first.name);
    });

    test('browsing narrows by the same rule as the suggestions, without a cap',
        () {
      final amox = catalogue.browse('amox');
      expect(amox, isNotEmpty);
      expect(amox.every((m) => m.name.toLowerCase().contains('amox')), isTrue);
      // More than the six a suggestion list stops at, if the list has them.
      expect(amox.length,
          greaterThanOrEqualTo(catalogue.search('amox', limit: 6).length));
      expect(catalogue.browse('500 amox').length,
          catalogue.browse('amox 500').length);
      expect(catalogue.browse('xyzolam'), isEmpty);
    });

    test('an unreadable file degrades to no suggestions, not an error', () {
      expect(() => MedicineCatalogue.parse('not json'), throwsFormatException);
      expect(MedicineCatalogue.empty.search('amox'), isEmpty);
    });
  });
}
