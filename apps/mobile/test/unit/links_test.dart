import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/core/api_endpoint.dart';
import 'package:pharmaet_mobile/ui/links.dart';

void main() {
  test('the public site is the API\'s origin', () {
    expect(siteFromApi('https://pharmaet.example/api'),
        'https://pharmaet.example');
  });

  test('legal pages open in the reader\'s language', () {
    publicSite = 'https://pharmaet.example';
    expect('${privacyPolicyUrl('en')}', 'https://pharmaet.example/privacy');
    expect('${deleteAccountUrl('am')}',
        'https://pharmaet.example/delete-account#am');
  });

  test('support is dialled in international form', () {
    expect('$supportTel', 'tel:+251902432346');
  });
}
