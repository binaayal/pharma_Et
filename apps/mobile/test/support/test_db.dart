import 'dart:io';

import 'package:pharmaet_mobile/data/local_db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Opens a LocalDb backed by a REAL file on disk, in a temporary directory.
///
/// Not an in-memory database, deliberately. The offline guarantee is about surviving the
/// process going away, and an in-memory database dies with the process — it would make the
/// G7 suite assert nothing at all while looking like it passed.
Future<({LocalDb db, Directory dir})> openTestDb({Directory? reuse}) async {
  sqfliteFfiInit();
  final dir = reuse ?? await Directory.systemTemp.createTemp('pharmaet_test_');
  final db = await LocalDb.open(
    factory: databaseFactoryFfi,
    directory: dir.path,
  );
  return (db: db, dir: dir);
}
