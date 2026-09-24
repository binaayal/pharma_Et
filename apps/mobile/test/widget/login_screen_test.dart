import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/auth/session.dart';
import 'package:pharmaet_mobile/contracts/contracts.dart';
import 'package:pharmaet_mobile/sync/sync_client.dart';
import 'package:pharmaet_mobile/ui/kit.dart';
import 'package:pharmaet_mobile/ui/login_screen.dart';

import '../support/pump.dart';

/// T3 — the login screen (prototype screen 03; docs/05-qa §3, §10; ADR-017).
///
/// Two of this screen's decisions are security decisions rather than presentation, and both
/// are only observable here:
///
///  - **One message for every credential failure.** Distinguishing "no such pharmacy" from
///    "wrong PIN" tells an attacker which codes and usernames are real.
///  - **Except a throttle, and a dead network.** "Check the details" is harmful advice to
///    someone rate-limited, and to someone whose PIN is right but whose phone is offline.
void main() {
  const terminalId = '01930000-0000-7000-8000-000000000004';

  Future<void> open(WidgetTester tester, SyncClient client,
      {RememberedIdentity? remembered}) async {
    // A phone-shaped surface: the keypad's bottom row sits below an 800×600 test window.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpScreen(
      tester,
      LoginScreen(
        client: client,
        terminalId: terminalId,
        remembered: remembered,
        onSignedIn: (_, __, ___, ____) {},
      ),
    );
  }

  Future<void> keyIn(WidgetTester tester, String pin) async {
    for (final digit in pin.split('')) {
      await tester.tap(find.bySemanticsLabel(digit).first);
      await tester.pump();
    }
  }

  PButton signInButton(WidgetTester tester) => tester
      .widgetList<PButton>(find.byType(PButton))
      .firstWhere((b) => b.label.startsWith('Sign'));

  Future<void> signIn(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField).at(0), 'abay');
    await tester.enterText(find.byType(TextField).at(1), 'cashier');
    await keyIn(tester, '1234');
    signInButton(tester).onPressed!();
    await tester.pump();
    await tester.pump();
  }

  testWidgets('the PIN is entered on the keypad, as the prototype draws it',
      (tester) async {
    await open(tester, _RefusingClient(401, 'invalid credentials'));
    await keyIn(tester, '12');
    expect(find.bySemanticsLabel('2 digits entered'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Delete'));
    await tester.pump();
    expect(find.bySemanticsLabel('1 digits entered'), findsOneWidget);
  });

  testWidgets('a returning user is greeted by name and only asked for a PIN',
      (tester) async {
    await open(tester, _RefusingClient(401, 'invalid credentials'),
        remembered: const RememberedIdentity(
            tenantCode: 'abay', username: 'sara', displayName: 'Sara Girma'));
    expect(find.text('Welcome back, Sara'), findsOneWidget);
    // No pharmacy code or username fields: the device remembers who, never a credential.
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('a wrong PIN and an unknown pharmacy read identically',
      (tester) async {
    await open(tester, _RefusingClient(401, 'invalid credentials'));
    await signIn(tester);
    expect(find.textContaining('Check the details'), findsOneWidget);

    await open(tester, _RefusingClient(401, 'invalid credentials'));
    await signIn(tester);
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

    expect(find.textContaining('15 minutes'), findsOneWidget);
    expect(find.textContaining('does not stop you selling'), findsOneWidget);
    expect(find.textContaining('Check the details'), findsNothing);
  });

  testWidgets('no connection is said plainly, not blamed on the credentials',
      (tester) async {
    await open(tester, _UnreachableClient());
    await signIn(tester);

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.textContaining('No connection'), findsOneWidget);
    expect(find.textContaining('Check the details'), findsNothing);
  });

  testWidgets('it will not submit an incomplete form', (tester) async {
    await open(tester, _RefusingClient(401, 'invalid credentials'));
    await keyIn(tester, '12');
    // Fewer than four digits can only be refused, and would count against the throttle.
    expect(signInButton(tester).onPressed, isNull);
  });

  testWidgets('a manager can type a password, not only a PIN', (tester) async {
    await open(tester, _RefusingClient(401, 'invalid credentials'));
    await tester.tap(find.text('Use a password'));
    await tester.pump();

    // Owners and managers have passwords (FR-2), which a keypad cannot type.
    final password = tester
        .widgetList<TextField>(find.byType(TextField))
        .firstWhere((f) => f.obscureText);
    expect(password.keyboardType, TextInputType.visiblePassword);
    expect(find.text('PASSWORD'), findsOneWidget);
    expect(find.bySemanticsLabel('Delete'), findsNothing);
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
