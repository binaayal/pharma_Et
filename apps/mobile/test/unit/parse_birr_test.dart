import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/core/money.dart';

/// Typed amounts become santim without ever being a double (guardian G4).
void main() {
  test('reads what a cashier types', () {
    expect(parseBirr('500'), 50000);
    expect(parseBirr('18,600.00'), 1860000);
    expect(parseBirr('1250.5'), 125050);
    expect(parseBirr('0.07'), 7);
    expect(parseBirr('400.'), 40000);
  });

  test('refuses what is not money rather than guessing', () {
    for (final bad in ['', 'abc', '1.2.3', '-5', '1.234', '12.x']) {
      expect(parseBirr(bad), isNull, reason: bad);
    }
  });

  test('the classic float trap stays exact', () {
    // 0.1 + 0.2 in binary floating point is 0.30000000000000004.
    expect(parseBirr('0.10')! + parseBirr('0.20')!, parseBirr('0.30'));
  });
}
