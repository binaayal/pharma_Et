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
  LocalDb._(this.db);

  final Database db;

  static const _version = 2;

  static Future<LocalDb> open({
    DatabaseFactory? factory,
    String? directory,
    String fileName = 'pharmaet.db',
  }) async {
    final dbFactory = factory ?? databaseFactory;
    final base = directory ?? await dbFactory.getDatabasesPath();
    final database = await dbFactory.openDatabase(
      p.join(base, fileName),
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
    return LocalDb._(database);
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
