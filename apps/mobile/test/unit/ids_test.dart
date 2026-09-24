import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/core/ids.dart';

/// Client-generated identifiers (ADR-006).
///
/// `newId()` is a thin wrapper over the `uuid` package, so this does not re-test v7 — that
/// would be testing somebody else's library. What it pins is the three things **ADR-006
/// claims about our use of it**, each of which would fail somewhere far from here.
void main() {
  /// The exact pattern `packages/contracts/src/primitives.ts` enforces.
  ///
  /// Duplicated on purpose, and the duplication IS the test: the server validates every
  /// operation against this regex, so a generator that drifted from it would have every push
  /// rejected at the boundary — after a day of offline trading, from a queue that cannot
  /// drain. The one place a Dart–TypeScript divergence would be invisible until it was
  /// expensive.
  final contractPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  test('every id satisfies the contract the server validates against', () {
    for (var i = 0; i < 500; i++) {
      final id = newId();
      expect(contractPattern.hasMatch(id), isTrue,
          reason: '$id would be rejected by the contract');
    }
  });

  test('the version nibble is 7, not 4', () {
    // A one-word change to `v4()` would work perfectly, pass every other test, and silently
    // throw away the property the whole of ADR-006 rests on — ids that sort by time. The
    // damage would show up as index bloat months later, attributable to nothing.
    expect(newId()[14], '7');
  });

  test('ids minted at different times sort in that order', () async {
    // What "time-ordered" buys: a day's sales cluster in the B-tree instead of scattering,
    // and the outbox's natural order matches the order things happened.
    final first = newId();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final second = newId();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final third = newId();

    expect([first, second, third]..sort(), [first, second, third]);

    // Intra-millisecond ordering is deliberately NOT asserted: RFC 9562 permits a counter
    // but does not require one, and nothing in this system depends on it. Operation order
    // comes from `terminal_seq`, never from an id (ADR-005).
  });

  test('a cart minted in one tick has no collisions', () {
    // Every line of a sale is minted in the same instant, and a duplicate would violate a
    // primary key on a device with no server to notice.
    final ids = List.generate(10000, (_) => newId());
    expect(ids.toSet().length, ids.length);
  });
}
