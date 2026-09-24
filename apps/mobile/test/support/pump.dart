import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/auth/session.dart';
import 'package:pharmaet_mobile/contracts/contracts.dart';
import 'package:pharmaet_mobile/core/theme.dart';
import 'package:pharmaet_mobile/l10n/locale_store.dart';
import 'package:pharmaet_mobile/l10n/strings.dart';

/// Scaffolding for the T3 widget suites (docs/05-qa §3).
///
/// Every screen reads `context.t(...)` through the `L10n` inherited widget and is styled by
/// `buildTheme()`, so pumping one bare throws before it renders a pixel. Putting that in one
/// place keeps each test about the screen rather than about the wrapper.
Future<void> pumpScreen(
  WidgetTester tester,
  Widget screen, {
  String locale = 'en',
}) async {
  await tester.pumpWidget(
    L10n(
      strings: Strings.of(locale),
      onChange: (_) {},
      child: MaterialApp(theme: buildTheme(), home: screen),
    ),
  );
  // `pump` twice rather than `pumpAndSettle`: a screen that is still loading shows a
  // CircularProgressIndicator, which animates forever, so settling never happens. Two frames
  // is enough for a stubbed repository's future to resolve and the rebuild to land.
  await tester.pump();
  await tester.pump();
}

/// A cached session for a given role, with a window that has not closed.
CachedSession sessionFor(
  String role, {
  DateTime? offlineValidUntil,
  List<String> branchIds = const ['01930000-0000-7000-8000-000000000002'],
}) =>
    CachedSession(
      accessToken: 'token',
      refreshToken: 'refresh',
      tenantCode: 'test',
      offlineValidUntil:
          offlineValidUntil ?? DateTime.now().add(const Duration(days: 3)),
      scope: AuthScope(
        userId: '01930000-0000-7000-8000-000000000003',
        tenantId: '01930000-0000-7000-8000-000000000001',
        role: role,
        displayName: 'Test $role',
        branchIds: branchIds,
      ),
    );
