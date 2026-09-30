import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/core/api_endpoint.dart';

/// A release build never talks to its server in clear text.
void main() {
  test('a release build refuses plain HTTP', () {
    expect(
        () => resolveApiBaseUrl('http://pharmaet.example/api', release: true),
        throwsStateError);
  });

  test('a release build accepts HTTPS, without a trailing slash', () {
    expect(resolveApiBaseUrl('https://pharmaet.example/api/', release: true),
        'https://pharmaet.example/api');
  });

  test('a debug build may reach the developer\'s machine over HTTP', () {
    expect(resolveApiBaseUrl('http://10.0.2.2:3000/api', release: false),
        'http://10.0.2.2:3000/api');
  });

  test('nonsense is refused in any build', () {
    expect(
        () => resolveApiBaseUrl('not a url', release: false), throwsStateError);
  });
}
