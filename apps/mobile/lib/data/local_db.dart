import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// The terminal's local database — the actual source of truth for the counter.
///
/// This file carries the product's central promise. Every core-loop write lands here first
/// and is durable before any network attempt (NFR-1.3, ADR-002). The network is never on
/// the critical path of a sale; if it were, a power cut would stop the till, which is the
/// one failure this system exists to prevent.
///
/// Two shapes live here, and the difference matters:
///   - mirrored reference data (products, stock), overwritten by each pull;
///   - locally authored transactions (sales) plus the append-only `outbox`, which is the
///     only record that a sale happened until the server acknowledges it.
class LocalDb {
  LocalDb._(this.db, {this.quarantinedFile});

  final Database db;

  /// Set when the previous database could not be opened and was set aside (ADR-018).
  ///
  /// Non-null means **this terminal has lost local data**. The counter can trade, which is
  /// the point, but somebody must be told. Silence here would be the product quietly
  /// reporting that a pharmacy had no sales.
  ///
  /// This field reflects *this* launch only. The notice that must actually reach a human
  /// survives a restart — see [pendingQuarantineNotice].
  final String? quarantinedFile;

  bool get recoveredFromCorruption => quarantinedFile != null;

  static const _quarantineKey = 'pharmaet.quarantined_file';

  /// The quarantine the user has not acknowledged yet, or null.
  ///
  /// Recorded in the **new** database rather than held in memory, because otherwise the
  /// warning would be dismissible by force-closing the app — and a force-close is a
  /// completely ordinary thing to do to a till that has just behaved strangely. The one
  /// person who most needs to see this is the one most likely to restart their way past it.
  Future<String?> pendingQuarantineNotice() async {
    final rows = await db.query('meta',
        where: 'key = ?', whereArgs: [_quarantineKey], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  /// Clears the notice, once a human has actually seen it.
  Future<void> acknowledgeQuarantine() =>
      db.delete('meta', where: 'key = ?', whereArgs: [_quarantineKey]);

  static const _version = 3;

  /// Opens the terminal's database, and **always returns one** (ADR-018).
  ///
  /// A corrupt SQLite file is not hypothetical here. The target market has unreliable mains
  /// power and cheap flash storage, and a write interrupted at the wrong moment is exactly
  /// how `SQLITE_NOTADB` and `SQLITE_CORRUPT` happen. Before ADR-018 that threw out of
  /// `open`, so the app could not start — a till that will not open, which this product
  /// treats as the worst outcome it can produce.
  ///
  /// So corruption is handled rather than propagated: the unreadable file is renamed aside
  /// and a fresh database is created, so the pharmacy opens and trades. The quarantined file
  /// is **kept**, never deleted — it is the only copy of whatever had not yet synced, and a
  /// later version may be able to salvage rows from it.
  static Future<LocalDb> open({
    DatabaseFactory? factory,
    String? directory,
    String fileName = 'pharmaet.db',
  }) async {
    final dbFactory = factory ?? databaseFactory;
    final base = directory ?? await dbFactory.getDatabasesPath();
    final path = p.join(base, fileName);

    try {
      return LocalDb._(await _openAt(dbFactory, path));
    } on DatabaseException catch (error) {
      // Narrow on purpose. A disk-full or permission error must propagate: quarantining on
      // those would rename away a perfectly good database and *cause* the data loss this is
      // meant to contain.
      if (!_isCorruption(error)) rethrow;

      final quarantined = _quarantine(path);
      final fresh = await _openAt(dbFactory, path);
      if (quarantined != null) {
        // Written into the replacement database so the warning outlives a restart. If this
        // insert itself fails the terminal still opens: a notice is worth less than a till.
        try {
          await fresh.insert(
            'meta',
            {'key': _quarantineKey, 'value': quarantined},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        } catch (_) {
          // Nothing to do. The in-memory flag still shows it for this launch.
        }
      }
      return LocalDb._(fresh, quarantinedFile: quarantined);
    }
  }

  static Future<Database> _openAt(DatabaseFactory dbFactory, String path) {
    return dbFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: _version,
        onConfigure: (db) async {
          // Foreign keys are off by default in SQLite. A sale line pointing at a sale that
          // is not there is a corrupt receipt, so we ask the database to refuse it.
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: _createSchema,
        onUpgrade: _upgradeSchema,
      ),
    );
  }

  /// Whether this error means the file is unreadable as a database.
  ///
  /// Matched on SQLite's own wording rather than a numeric code: the code is not exposed
  /// uniformly across the sqflite implementations this runs on (the device plugin and the
  /// FFI factory the tests use), and a check that worked in one and not the other would make
  /// the guardian suite assert something the handset does not do.
  static bool _isCorruption(DatabaseException error) {
    final message = error.toString().toLowerCase();
    return message.contains('file is not a database') || // SQLITE_NOTADB (26)
        message.contains(
            'database disk image is malformed') || // SQLITE_CORRUPT (11)
        message.contains('file is encrypted');
  }

  /// Renames the unreadable file aside and returns where it went.
  ///
  /// Renamed, not deleted. It holds whatever this terminal had not yet synced, and deleting
  /// it would turn a recoverable incident into a certain loss. The timestamp means a second
  /// corruption cannot overwrite the evidence of the first.
  static String? _quarantine(String path) {
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    final target = '$path.corrupt-$stamp';
    var moved = false;

    for (final suffix in ['', '-journal', '-wal', '-shm']) {
      final file = File('$path$suffix');
      if (!file.existsSync()) continue;
      try {
        file.renameSync('$target$suffix');
        if (suffix.isEmpty) moved = true;
      } catch (_) {
        // If it cannot even be renamed, delete it: an unopenable file that cannot be moved
        // would block every future launch, and a till that never opens is the one outcome
        // worse than losing the unsynced rows it holds.
        try {
          file.deleteSync();
        } catch (_) {
          // Nothing further to try. The open below will fail and the caller will see it.
        }
      }
    }

    return moved ? target : null;
  }

  static Future<void> _createSchema(Database db, int version) async {
    // ---------------------------------------------------------- reference data
    // Mirrored from the server by delta pull. Safe to overwrite: the terminal never
    // authors these, so nothing is lost by replacing a row (docs/04 §7.2).
    await db.execute('''
      CREATE TABLE product (
        id                TEXT PRIMARY KEY,
        name              TEXT NOT NULL,
        unit              TEXT NOT NULL,
        is_controlled     INTEGER NOT NULL DEFAULT 0,
        price_santim      INTEGER NOT NULL,
        change_seq        INTEGER NOT NULL DEFAULT 0,
        deleted           INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE stock_batch (
        id           TEXT PRIMARY KEY,
        branch_id    TEXT NOT NULL,
        product_id   TEXT NOT NULL,
        lot_no       TEXT NOT NULL,
        expiry_date  TEXT NOT NULL,
        qty_on_hand  INTEGER NOT NULL,
        change_seq   INTEGER NOT NULL DEFAULT 0,
        deleted      INTEGER NOT NULL DEFAULT 0
      )
    ''');
    // FEFO reads this index on every line of every sale, so it exists from day one
    // (AC-3.2).
    await db.execute(
      'CREATE INDEX stock_batch_fefo ON stock_batch (product_id, branch_id, expiry_date)',
    );

    // ------------------------------------------------------- local transactions
    await db.execute('''
      CREATE TABLE sale (
        id            TEXT PRIMARY KEY,
        branch_id     TEXT NOT NULL,
        cashier_id    TEXT NOT NULL,
        shift_id      TEXT,
        total_santim  INTEGER NOT NULL,
        sold_at       TEXT NOT NULL,
        synced        INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE sale_line (
        id                 TEXT PRIMARY KEY,
        sale_id            TEXT NOT NULL REFERENCES sale(id),
        product_id         TEXT NOT NULL,
        batch_id           TEXT,
        qty                INTEGER NOT NULL,
        unit_price_santim  INTEGER NOT NULL,
        line_total_santim  INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE payment (
        id             TEXT PRIMARY KEY,
        sale_id        TEXT NOT NULL REFERENCES sale(id),
        method         TEXT NOT NULL,
        amount_santim  INTEGER NOT NULL
      )
    ''');

    // ------------------------------------------------------------------ outbox
    // Append-only queue of operations awaiting acknowledgement (ADR-002).
    //
    // A row leaves this table for exactly one reason: the server acknowledged it as applied
    // or duplicate. Not on a timeout, not on a parse failure, not on a 500. An operation we
    // cannot send yet is an operation we keep — deleting it would be losing a real sale,
    // quietly, which is the failure mode the whole design is arranged against.
    await db.execute('''
      CREATE TABLE outbox (
        op_id         TEXT PRIMARY KEY,
        terminal_seq  INTEGER NOT NULL UNIQUE,
        entity_type   TEXT NOT NULL,
        entity_id     TEXT NOT NULL,
        payload_json  TEXT NOT NULL,
        created_at    TEXT NOT NULL,
        attempts      INTEGER NOT NULL DEFAULT 0,
        last_error    TEXT,
        needs_attention INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('CREATE INDEX outbox_order ON outbox (terminal_seq)');

    await _createShiftSchema(db);
    await _createInventorySchema(db);

    // -------------------------------------------------------------------- meta
    // Terminal identity, the pull cursor, and the monotonic write counter. Kept in the
    // database rather than in preferences so that the counter and the operations it
    // numbers commit or roll back together.
    await db.execute(
        'CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
  }

  /// FR-8 — shift and cash-up (contract v1.1.0, ADR-012).
  ///
  /// Both are authored locally and queued, exactly like a sale: a pharmacy counts its till
  /// at close, which is frequently when the power is out. Neither waits on the network.
  static Future<void> _createShiftSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE shift (
        id                    TEXT PRIMARY KEY,
        branch_id             TEXT NOT NULL,
        user_id               TEXT NOT NULL,
        opened_at             TEXT NOT NULL,
        closed_at             TEXT,
        opening_float_santim  INTEGER NOT NULL DEFAULT 0,
        synced                INTEGER NOT NULL DEFAULT 0
      )
    ''');
    // One open shift per user on this terminal. Two open tills for one person means the
    // expected figure is split across them and neither reconciles.
    await db.execute(
      'CREATE UNIQUE INDEX shift_one_open_per_user ON shift (user_id) WHERE closed_at IS NULL',
    );

    await db.execute('''
      CREATE TABLE cash_up (
        id               TEXT PRIMARY KEY,
        shift_id         TEXT NOT NULL REFERENCES shift(id),
        user_id          TEXT NOT NULL,
        counted_at       TEXT NOT NULL,
        expected_santim  INTEGER NOT NULL,
        counted_santim   INTEGER NOT NULL,
        variance_santim  INTEGER NOT NULL,
        note             TEXT,
        synced           INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(
        'CREATE UNIQUE INDEX cash_up_one_per_shift ON cash_up (shift_id)');
  }

  /// Goods receipts and stock corrections, authored locally (FR-7, FR-3).
  ///
  /// Both happen at the counter and both must work with no network: stock arrives when the
  /// wholesaler's van arrives, and a shelf gets counted when somebody notices the number is
  /// wrong — neither waits for connectivity.
  static Future<void> _createInventorySchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE goods_receipt (
        id             TEXT PRIMARY KEY,
        branch_id      TEXT NOT NULL,
        supplier_name  TEXT NOT NULL,
        received_at    TEXT NOT NULL,
        synced         INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE goods_receipt_line (
        id                TEXT PRIMARY KEY,
        goods_receipt_id  TEXT NOT NULL REFERENCES goods_receipt(id),
        product_id        TEXT NOT NULL,
        lot_no            TEXT NOT NULL,
        expiry_date       TEXT NOT NULL,
        qty               INTEGER NOT NULL,
        cost_santim       INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE stock_adjustment (
        id                    TEXT PRIMARY KEY,
        branch_id             TEXT NOT NULL,
        batch_id              TEXT NOT NULL,
        product_id            TEXT NOT NULL,
        delta                 INTEGER NOT NULL,
        reason                TEXT NOT NULL,
        note                  TEXT,
        previous_qty_on_hand  INTEGER NOT NULL,
        counted_at            TEXT NOT NULL,
        synced                INTEGER NOT NULL DEFAULT 0
      )
    ''');
  }

  /// Schema upgrades run on a device holding real, unsynced sales.
  ///
  /// So they are additive only — new tables and new nullable columns. Anything that
  /// rewrites or drops existing rows risks destroying a transaction that has not reached
  /// the server yet, and that transaction is somebody's money (NFR-1.3).
  static Future<void> _upgradeSchema(Database db, int from, int to) async {
    if (from < 2) {
      await _createShiftSchema(db);
      // Sales gain their shift. Existing rows keep NULL: they were rung up before shifts
      // existed and cannot be retro-assigned to one honestly.
      await db.execute('ALTER TABLE sale ADD COLUMN shift_id TEXT');
    }
    if (from < 3) {
      await _createInventorySchema(db);
    }
  }

  Future<String?> meta(String key) async {
    final rows =
        await db.query('meta', where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> setMeta(String key, String value,
      {DatabaseExecutor? txn}) async {
    await (txn ?? db).insert(
      'meta',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> close() => db.close();
}
