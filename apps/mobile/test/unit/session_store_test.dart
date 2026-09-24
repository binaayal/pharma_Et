import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/auth/session.dart';

/// Where this device is placed belongs to the pharmacy it was chosen in.
///
/// Found on a phone: after Abay's owner placed the device at Bole, a newly opened
/// pharmacy's owner signed in on the same phone and was put at *Abay's* Bole branch —
/// all-branch by role, so nothing objected. Every sale they rang up would have been refused
/// by the server's tenant isolation and waited in the outbox for good.
void main() {
  const abay = '01930000-0000-7000-8000-0000000000a1';
  const selam = '01930000-0000-7000-8000-0000000000a2';
  const bole = '01930000-0000-7000-8000-0000000000b1';

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('a placement is honoured for the pharmacy that made it', () async {
    final store = SessionStore();
    await store.setTerminalBranch(abay, bole, name: 'Bole');

    expect(await store.terminalBranchId(abay), bole);
    expect(await store.terminalBranchName(abay), 'Bole');
  });

  test('and ignored for any other pharmacy on the same phone', () async {
    final store = SessionStore();
    await store.setTerminalBranch(abay, bole, name: 'Bole');

    expect(await store.terminalBranchId(selam), isNull);
    expect(await store.terminalBranchName(selam), isNull);
  });

  test('a bare id from an older build is not trusted', () async {
    FlutterSecureStorage.setMockInitialValues(
        {'pharmaet.terminal_branch': bole});
    final store = SessionStore();

    // Its tenant is unknown, so the device asks again rather than guess.
    expect(await store.terminalBranchId(abay), isNull);
  });
}
