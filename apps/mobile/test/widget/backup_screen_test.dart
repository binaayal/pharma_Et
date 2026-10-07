import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmaet_mobile/data/backup.dart';
import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:pharmaet_mobile/ui/backup_screen.dart';
import 'package:pharmaet_mobile/ui/kit.dart';
import 'package:pharmaet_mobile/ui/settings_screen.dart';

import '../support/terminal.dart';
import '../support/test_db.dart';

/// FR-15 — the screen an owner uses to keep a copy of what is only on the phone.
///
/// The backup engine is held by `g7_backup_restore_test.dart`. This is about what a person
/// is asked and told: that a passphrase cannot be mistyped into a file nobody can open,
/// that the wrong file is refused before they are asked to type anything, and that every
/// failure says which failure it was.
void main() {
  late LocalDb db;
  late Directory dir;

  // What the stub terminal is signed in as (test/support/pump.dart).
  const tenantId = '01930000-0000-7000-8000-000000000001';
  const branchId = '01930000-0000-7000-8000-000000000002';

  setUp(() async {
    final opened = await openTestDb();
    db = opened.db;
    dir = opened.dir;
  });

  tearDown(() async {
    BackupFiles.debugSave = null;
    BackupFiles.debugSaveAsFile = null;
    BackupFiles.debugDestination = null;
    BackupFiles.debugPick = null;
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// A file with a real, readable header and nothing decryptable behind it — enough for
  /// everything the screen does before the engine is called.
  Uint8List fileFor({
    String tenant = tenantId,
    String branch = branchId,
    String branchName = 'Bole',
    int pending = 3,
  }) {
    final header = utf8.encode(jsonEncode({
      'format': 1,
      'tenantId': tenant,
      'tenantCode': 'abay',
      'branchId': branch,
      'branchName': branchName,
      'terminalId': 'lost-phone',
      'createdAt': '2026-10-05T08:00:00.000Z',
      'pending': pending,
      'sales': pending,
    }));
    return Uint8List.fromList([
      ...ascii.encode('PHARMAET-BACKUP\n'),
      0, 0, (header.length >> 8) & 0xff, header.length & 0xff, //
      ...header,
      ...List.filled(16, 1), 0, 0, 3, 232, ...List.filled(12 + 16 + 8, 2),
    ]);
  }

  Future<_FakeBackups> open(WidgetTester tester,
      {String role = 'owner'}) async {
    final t = TestTerminal.build(db, role: role);
    final fake = _FakeBackups(db);
    await pumpTerminalScreen(tester, t.terminal, BackupScreen(service: fake));
    return fake;
  }

  PButton button(WidgetTester tester, String label) =>
      tester.widget<PButton>(find.widgetWithText(PButton, label));

  FilledButton proceed(WidgetTester tester) =>
      tester.widget<FilledButton>(find.byType(FilledButton));

  group('who is offered it', () {
    Future<void> settings(WidgetTester tester, String role) async {
      tester.view.physicalSize = const Size(1080, 3600);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final t = TestTerminal.build(db, role: role);
      await pumpTerminalScreen(
          tester, t.terminal, const Scaffold(body: SettingsScreen()));
    }

    testWidgets('the owner and a branch manager', (tester) async {
      await settings(tester, 'owner');
      expect(find.text('Backup & restore'), findsOneWidget);
      await settings(tester, 'branch_manager');
      expect(find.text('Backup & restore'), findsOneWidget);
    });

    testWidgets('not a cashier — a backup is the branch\'s whole sales',
        (tester) async {
      await settings(tester, 'cashier');
      expect(find.text('Backup & restore'), findsNothing);
    });

    testWidgets('still the owner after a week offline, when it matters most',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 3600);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      // Past the offline ceiling (BR-2.3): management actions are withdrawn. This is not
      // one of them — it is how the queue that built up gets somewhere safe.
      final t = TestTerminal.build(db,
          role: 'owner',
          offlineValidUntil: DateTime.now().subtract(const Duration(days: 1)));
      await pumpTerminalScreen(
          tester, t.terminal, const Scaffold(body: SettingsScreen()));
      expect(find.text('Backup & restore'), findsOneWidget);
    });
  });

  group('making a backup', () {
    testWidgets('a passphrase must be long enough and typed the same twice',
        (tester) async {
      await open(tester);
      await tester.tap(find.text('Back up now'));
      await tester.pumpAndSettle();

      expect(proceed(tester).onPressed, isNull);
      await tester.enterText(find.byType(TextField).at(0), 'short');
      await tester.enterText(find.byType(TextField).at(1), 'short');
      await tester.pump();
      expect(proceed(tester).onPressed, isNull, reason: 'too short');

      await tester.enterText(find.byType(TextField).at(0), 'long enough one');
      await tester.enterText(find.byType(TextField).at(1), 'long enough onf');
      await tester.pump();
      expect(proceed(tester).onPressed, isNull, reason: 'a typo in the second');

      await tester.enterText(find.byType(TextField).at(1), 'long enough one');
      await tester.pump();
      expect(proceed(tester).onPressed, isNotNull);
    });

    testWidgets('hands the file to the owner to keep somewhere else',
        (tester) async {
      String? savedAs;
      Uint8List? saved;
      BackupFiles.debugSave = (bytes, name) async {
        saved = bytes;
        savedAs = name;
        return true;
      };
      final fake = await open(tester);

      await tester.tap(find.text('Back up now'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), 'long enough one');
      await tester.enterText(find.byType(TextField).at(1), 'long enough one');
      await tester.pump();
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();

      expect(fake.createdWith, 'long enough one');
      expect(saved, isNotNull);
      expect(savedAs, startsWith('pharmaet-'));
      expect(savedAs, endsWith('.pharmaet-backup'));
      expect(find.textContaining('somewhere that is not this phone'),
          findsOneWidget);
    });

    testWidgets(
        'closing the share sheet without choosing does not count as a backup',
        (tester) async {
      // Found on a real phone: dismissing the share sheet still said "Backup made". The
      // file had gone nowhere.
      BackupFiles.debugSave = (_, __) async => false;
      await open(tester);

      await tester.tap(find.text('Back up now'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), 'long enough one');
      await tester.enterText(find.byType(TextField).at(1), 'long enough one');
      await tester.pump();
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();

      expect(find.textContaining('was not sent anywhere'), findsOneWidget);
      expect(find.textContaining('somewhere that is not this phone'),
          findsNothing);
      // And "last backup" does not move: nothing was kept.
      expect(find.text('Never'), findsOneWidget);
    });

    Future<void> throughPassphrase(WidgetTester tester) async {
      await tester.tap(find.text('Back up now'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), 'long enough one');
      await tester.enterText(find.byType(TextField).at(1), 'long enough one');
      await tester.pump();
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
    }

    testWidgets('asks where the backup should go: sent, or saved as a file',
        (tester) async {
      // Found on a real phone: the share sheet offered only ways to send the file to
      // somebody. No memory card, no folder — so no backup without a chat app.
      final fake = await open(tester);
      await throughPassphrase(tester);

      expect(find.text('Send it to yourself'), findsOneWidget);
      expect(find.text('Save it as a file'), findsOneWidget);
      // Nothing is made until the owner has said where it goes.
      expect(fake.createdWith, isNull);
    });

    testWidgets('saved as a file: kept, and told it must not stay only here',
        (tester) async {
      String? savedAs;
      BackupFiles.debugSaveAsFile = (bytes, name) async {
        savedAs = name;
        return true;
      };
      final fake = await open(tester);
      await throughPassphrase(tester);
      await tester.tap(find.text('Save it as a file'));
      await tester.pumpAndSettle();

      expect(fake.createdWith, 'long enough one');
      expect(savedAs, endsWith('.pharmaet-backup'));
      expect(find.textContaining('lost with the phone'), findsOneWidget);
      expect(find.text('Never'), findsNothing);
    });

    testWidgets('closing the save picker without saving is not a backup',
        (tester) async {
      BackupFiles.debugSaveAsFile = (_, __) async => false;
      await open(tester);
      await throughPassphrase(tester);
      await tester.tap(find.text('Save it as a file'));
      await tester.pumpAndSettle();

      expect(find.textContaining('lost with the phone'), findsNothing);
      expect(find.text('Never'), findsOneWidget);
    });

    testWidgets('cancelling the passphrase makes no file', (tester) async {
      var saves = 0;
      BackupFiles.debugSave = (_, __) async {
        saves++;
        return true;
      };
      final fake = await open(tester);

      await tester.tap(find.text('Back up now'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(fake.createdWith, isNull);
      expect(saves, 0);
    });

    testWidgets('says what a restore will and will not do, before it is asked',
        (tester) async {
      await open(tester);
      expect(find.textContaining('never removes or replaces'), findsOneWidget);
      expect(find.textContaining('not by you, and not by us'), findsOneWidget);
    });
  });

  group('restoring', () {
    Future<void> pick(WidgetTester tester, Uint8List file) async {
      BackupFiles.debugPick = () async => file;
      await tester.tap(find.text('Restore from a backup file'));
      await tester.pumpAndSettle();
    }

    testWidgets('says whose backup it is before asking for the passphrase',
        (tester) async {
      await open(tester);
      await pick(tester, fileFor(pending: 12));

      expect(find.textContaining('Backup of Bole'), findsOneWidget);
      expect(find.textContaining('12 sales or receipts'), findsOneWidget);
    });

    testWidgets('restores, and says how many came back', (tester) async {
      final fake = await open(tester);
      fake.result = const RestoreResult(
          operationsRestored: 12,
          operationsAlreadyHere: 0,
          recordsRestored: 30);
      await pick(tester, fileFor(pending: 12));
      await tester.enterText(find.byType(TextField).first, 'long enough one');
      await tester.pump();
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();

      expect(fake.restoredWith, 'long enough one');
      expect(
          find.textContaining('Restored 12 sales or receipts'), findsOneWidget);
    });

    testWidgets('a file already restored is said to be, not counted again',
        (tester) async {
      final fake = await open(tester);
      fake.result = const RestoreResult(
          operationsRestored: 0, operationsAlreadyHere: 12, recordsRestored: 0);
      await pick(tester, fileFor());
      await tester.enterText(find.byType(TextField).first, 'long enough one');
      await tester.pump();
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();

      expect(find.textContaining('already on this phone'), findsOneWidget);
    });

    testWidgets('a wrong passphrase is said to be wrong', (tester) async {
      final fake = await open(tester);
      fake.problem = BackupProblem.wrongPassphrase;
      await pick(tester, fileFor());
      await tester.enterText(find.byType(TextField).first, 'not the right one');
      await tester.pump();
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();

      expect(find.text('That passphrase does not open this backup.'),
          findsOneWidget);
      // And they can try again.
      expect(button(tester, 'Restore from a backup file').onPressed, isNotNull);
    });

    testWidgets('another branch\'s backup is refused by name, with no prompt',
        (tester) async {
      final fake = await open(tester);
      await pick(
          tester,
          fileFor(
              branch: '01930000-0000-7000-8000-0000000000b2',
              branchName: 'Piassa'));

      expect(find.textContaining('belongs to Piassa'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(fake.restoredWith, isNull);
    });

    testWidgets('another pharmacy\'s backup is refused, with no prompt',
        (tester) async {
      final fake = await open(tester);
      await pick(
          tester, fileFor(tenant: '01930000-0000-7000-8000-0000000000a1'));

      expect(find.text('That backup belongs to a different pharmacy.'),
          findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(fake.restoredWith, isNull);
    });

    testWidgets('a file that is not a backup is said not to be one',
        (tester) async {
      await open(tester);
      await pick(tester, Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]));

      expect(find.textContaining('not a PharmaEt backup'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('picking nothing does nothing', (tester) async {
      await open(tester);
      BackupFiles.debugPick = () async => null;
      await tester.tap(find.text('Restore from a backup file'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });
  });

  testWidgets('in Amharic (AC-10.1)', (tester) async {
    final t = TestTerminal.build(db, role: 'owner');
    await pumpTerminalScreen(
        tester, t.terminal, BackupScreen(service: _FakeBackups(db)),
        locale: 'am');
    expect(find.text('አሁን ቅጂ ያዝ'), findsOneWidget);
    expect(find.text('Back up now'), findsNothing);
  });
}

/// The engine, replaced: a widget test runs where real file I/O never completes, and the
/// real one is tested against a real database elsewhere.
class _FakeBackups extends BackupService {
  _FakeBackups(super.db);

  String? createdWith;
  String? restoredWith;
  BackupProblem? problem;
  RestoreResult result = const RestoreResult(
      operationsRestored: 1, operationsAlreadyHere: 0, recordsRestored: 1);

  @override
  Future<DateTime?> lastBackupAt() async => null;

  @override
  Future<Uint8List> create({
    required String passphrase,
    required String tenantId,
    required String tenantCode,
    required String branchId,
    required String branchName,
    required String terminalId,
    DateTime? now,
  }) async {
    createdWith = passphrase;
    return Uint8List.fromList([1, 2, 3]);
  }

  @override
  Future<RestoreResult> restore(
    Uint8List file, {
    required String passphrase,
    required String tenantId,
    required String branchId,
  }) async {
    restoredWith = passphrase;
    final p = problem;
    if (p != null) throw BackupException(p);
    return result;
  }
}
