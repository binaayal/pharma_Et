import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/core/payment_accounts.dart';
import 'package:pharmaet_mobile/l10n/help_content.dart';

/// FR-10 / BR-10.1 — the user guide exists, in full, in both languages.
void main() {
  final en = HelpGuide.en;
  final am = HelpGuide.am;

  test('every topic exists in both languages, in the same order', () {
    // A topic added in English and forgotten in Amharic leaves an Amharic reader without
    // the one page they opened the guide for.
    expect(am.topics.map((t) => t.id), en.topics.map((t) => t.id));
  });

  test('each topic has the same shape in both languages', () {
    for (var i = 0; i < en.topics.length; i++) {
      final e = en.topics[i];
      final a = am.topics[i];
      expect(a.icon, e.icon, reason: e.id);
      expect(a.steps.length, e.steps.length,
          reason: '${e.id}: a step exists in one language only');
      expect(a.tip == null, e.tip == null,
          reason: '${e.id}: a tip exists in one language only');
    }
  });

  test('the Amharic guide is actually in Ethiopic script', () {
    final ethiopic = RegExp(r'[ሀ-፿]');
    for (final topic in am.topics) {
      expect(topic.title, matches(ethiopic), reason: topic.id);
      for (final step in topic.steps) {
        expect(step, matches(ethiopic), reason: topic.id);
      }
    }
  });

  test('both guides tell an owner exactly where to pay', () {
    // The reason the payment topic exists: an owner with a lapsed subscription and no
    // account number cannot pay.
    for (final guide in [en, am]) {
      final payment = guide.topics.firstWhere((t) => t.id == 'payment');
      final text = payment.steps.join('\n');
      for (final account in paymentAccounts.values) {
        expect(text, contains(account.number));
      }
      expect(text, contains('Binyam Ayalneh Zerihun'));
      expect(guide.contactBody, contains(supportPhone));
    }
  });

  test('an unknown locale reads the English guide', () {
    expect(HelpGuide.of('fr'), same(en));
    expect(HelpGuide.of('am'), same(am));
  });
}
