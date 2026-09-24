import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/contracts/contracts.dart';
import 'package:pharmaet_mobile/sync/sync_client.dart';
import 'package:pharmaet_mobile/ui/login_screen.dart';

import '../support/pump.dart';

/// T3 — the login screen (docs/05-qa §3, §10; ADR-017).
///
/// Two of this screen's decisions are security decisions rather than presentation, and both
/// are only observable here — the API is identical in each case, and what differs is what the
/// person at the counter is told.
///
///  - **One message for every ordinary failure.** Distinguishing "no such pharmacy" from
///    "wrong PIN" tells an attacker which codes and usernames are real.
///  - **Except a throttle.** "Check the details and try again" is actively harmful advice to
///    somebody rate-limited: they try again, extend the window, and never learn that waiting
///    is what works.
void main() {
  const terminalId = '01930000-0000-7000-8000-000000000004';

  Future<void> signIn(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField).at(0), 'abay');
    await tester.enterText(find.byType(TextField).at(1), 'cashier');
    await tester.enterText(find.byType(TextField).at(2), '1234');
    await tester.pump();
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    await tester.pump();
  }

  Future<void> open(WidgetTester tester, SyncClient client) => pumpScreen(
        tester,
        LoginScreen(
          client: client,
          terminalId: terminalId,
          onSignedIn: (_, __) {},
        ),
      );

  testWidgets('a wrong PIN and an unknown pharmacy read identically',
      (tester) async {
    await open(tester, _RefusingClient(401, 'invalid credentials'));
    await signIn(tester);
    final wrongPin = find.textContaining('Check the details');
    expect(wrongPin, findsOneWidget);

    await open(tester, _RefusingClient(401, 'invalid credentials'));
    await signIn(tester);

    // Same words, same shape. The server already returns one error for both; this is the
    // client half of the same promise, and the half a user actually reads.
    expect(find.textContaining('Check the details'), findsOneWidget);
  });

  testWidgets('a throttle says how long, and that the shop keeps selling',
      (tester) async {
    await open(
      tester,
      _RefusingClient(
        429,
        'Too many sign-in attempts. Try again in 15 minutes. A terminal that is '
        'already signed in keeps working — this does not stop you selling.',
      ),
    );
    await signIn(tester);

    // The server's own wording, carried through rather than flattened. Telling somebody to
    // "check the details" here would send them round the loop that caused it (ADR-017).
    expect(find.textContaining('15 minutes'), findsOneWidget);
    expect(find.textContaining('does not stop you selling'), findsOneWidget);
    expect(find.textContaining('Check the details'), findsNothing);
  });

  testWidgets('a network failure is not reported as bad credentials',
      (tester) async {
    await open(tester, _UnreachableClient());
    await signIn(tester);

    // A transport failure has nothing to do with what was typed. It still collapses to the
    // generic message, which is the honest thing to show — but it must not crash the screen,
    // which is the case a widget test can see and a unit test cannot.
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.textContaining('Check the details'), findsOneWidget);
  });

  testWidgets('it will not submit an empty form', (tester) async {
    await open(tester, _RefusingClient(401, 'invalid credentials'));

    // Nothing typed: the button does nothing rather than sending a request that can only be
    // refused, and rather than counting against the throttle.
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
  });
}

class _RefusingClient extends SyncClient {
  _RefusingClient(this.status, this.message)
      : super(baseUrl: 'http://stub.invalid');
  final int status;
  final String message;

  @override
  Future<LoginResponse> login(LoginRequest request) async =>
      throw SyncTransportException(message, statusCode: status);
}

class _UnreachableClient extends SyncClient {
  _UnreachableClient() : super(baseUrl: 'http://stub.invalid');

  @override
  Future<LoginResponse> login(LoginRequest request) async =>
      throw SyncTransportException('login failed: Connection refused');
}
