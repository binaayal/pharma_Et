import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:sqflite/sqflite.dart';

import '../auth/offline_credentials.dart';
import 'local_db.dart';

/// What a backup file says about itself before it is opened.
///
/// Readable without the passphrase, so the app can say "Bole, 7 October, 12 sales not yet
/// synced" before asking for one — and bound to the encrypted part, so it cannot be edited
/// to point a backup at a different pharmacy without the passphrase failing.
class BackupHeader {
  const BackupHeader({
    required this.tenantId,
    required this.tenantCode,
    required this.branchId,
    required this.branchName,
    required this.terminalId,
    required this.createdAt,
    required this.pending,
    required this.sales,
    this.format = BackupService.format,
  });

  factory BackupHeader.fromJson(Map<String, dynamic> j) => BackupHeader(
        format: j['format'] as int,
        tenantId: j['tenantId'] as String,
        tenantCode: j['tenantCode'] as String,
        branchId: j['branchId'] as String,
        branchName: (j['branchName'] as String?) ?? '',
        terminalId: j['terminalId'] as String,
        createdAt: DateTime.parse(j['createdAt'] as String),
        pending: j['pending'] as int,
        sales: j['sales'] as int,
      );

  final int format;
  final String tenantId;
  final String tenantCode;
  final String branchId;
  final String branchName;
  final String terminalId;
  final DateTime createdAt;

  /// Operations that had not reached the server when the backup was made — the part of
  /// this file that exists nowhere else.
  final int pending;
  final int sales;

  Map<String, dynamic> toJson() => {
        'format': format,
        'app': 'pharmaet',
        'tenantId': tenantId,
        'tenantCode': tenantCode,
        'branchId': branchId,
        'branchName': branchName,
        'terminalId': terminalId,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'pending': pending,
        'sales': sales,
      };
}

/// Why a backup could not be read or restored. Each is a different thing to tell a person.
enum BackupProblem {
  /// Not a PharmaEt backup, or damaged.
  notABackup,

  /// Made by a newer version of the app than this one.
  tooNew,

  /// The passphrase is wrong — or the file was altered, which looks the same on purpose.
  wrongPassphrase,

  /// It belongs to a different pharmacy.
  otherPharmacy,

  /// It belongs to another branch of this pharmacy.
  otherBranch,
}

class BackupException implements Exception {
  const BackupException(this.problem);
  final BackupProblem problem;

  @override
  String toString() => 'BackupException(${problem.name})';
}

class RestoreResult {
  const RestoreResult({
    required this.operationsRestored,
    required this.operationsAlreadyHere,
    required this.recordsRestored,
  });

  /// Unsynced operations put back in the queue, to be pushed on the next sync.
  final int operationsRestored;

  /// Operations in the file this phone already holds — a second restore of one file.
  final int operationsAlreadyHere;

  /// Sales, receipts, shifts and counts added to this phone's own history.
  final int recordsRestored;
}

/// Backup and restore of what this phone holds (FR-15, ADR-033).
///
/// The server has everything that has synced. What exists **only on the phone** is the
/// outbox — sales, receipts and cash-ups taken while offline — and a phone that is lost,
/// stolen or dropped in that state takes them with it. A backup is a copy of that, in a
/// file the owner keeps somewhere that is not the phone.
///
/// Two decisions shape everything here:
///
/// **A backup is a document, not a database file.** It is the rows, as JSON, read in one
/// transaction. A copied SQLite file is tied to the schema version and journal state it was
/// taken in; rows restore into whatever version of the app opens them.
///
/// **A restore merges; it never replaces.** The phone doing the restoring may have traded
/// since — replacing its database would destroy the very thing a backup is for. So a
/// restore *adds* what the file holds and this phone lacks, and is safe to repeat: every
/// operation carries the id it was minted with, the queue will not take one twice, and the
/// server answers `duplicate` to any it has already applied (ADR-006).
class BackupService {
  BackupService(this._db, {this.kdfRounds = defaultKdfRounds});

  final LocalDb _db;

  /// The file format this version writes, and the newest it can read.
  static const format = 1;

  static const _magic = 'PHARMAET-BACKUP\n';

  /// PBKDF2-HMAC-SHA256 rounds for the passphrase.
  ///
  /// Far more than the offline PIN's: that guess is rate-limited by the phone, whereas a
  /// backup file is carried away and can be guessed at without limit. This is what makes
  /// each guess cost something.
  static const defaultKdfRounds = 150000;

  final int kdfRounds;

  /// Run the key derivation off the UI thread. Off in tests, which have one.
  static bool useIsolate = true;

  /// The shortest passphrase accepted. A backup holds a pharmacy's sales and its staff's
  /// names, and it is going to be sent through a chat app.
  static const minPassphrase = 8;

  /// What this phone authored. Restored row by row, in an order that satisfies the
  /// foreign keys between them.
  static const _authored = [
    'sale',
    'sale_line',
    'payment',
    'shift',
    'cash_up',
    'goods_receipt',
    'goods_receipt_line',
    'stock_adjustment',
    'controlled_dispense',
  ];

  /// Copied for the record — "what my shelves held on that day" — and never restored:
  /// reference data comes from the server, and an old copy must not overwrite a newer one.
  static const _reference = ['product', 'stock_batch'];

  static const _lastBackupKey = 'last_backup_at';

  /// When this phone last made a backup, or null if it never has.
  Future<DateTime?> lastBackupAt() async {
    final value = await _db.meta(_lastBackupKey);
    return value == null ? null : DateTime.tryParse(value);
  }

  /// Makes a backup file.
  ///
  /// Everything is read inside one transaction, so the file is the phone at one instant:
  /// never a sale without its lines, or an operation without the sale it describes.
  Future<Uint8List> create({
    required String passphrase,
    required String tenantId,
    required String tenantCode,
    required String branchId,
    required String branchName,
    required String terminalId,
    DateTime? now,
  }) async {
    if (passphrase.length < minPassphrase) {
      throw ArgumentError('the passphrase is too short');
    }
    final createdAt = (now ?? DateTime.now()).toUtc();

    final tables = <String, List<Map<String, Object?>>>{};
    await _db.db.transaction((txn) async {
      for (final table in ['outbox', ..._authored, ..._reference]) {
        tables[table] = await txn.query(table);
      }
    });

    final header = BackupHeader(
      tenantId: tenantId,
      tenantCode: tenantCode,
      branchId: branchId,
      branchName: branchName,
      terminalId: terminalId,
      createdAt: createdAt,
      pending: tables['outbox']!.length,
      sales: tables['sale']!.length,
    );

    final file = await _seal(
      header,
      gzip.encode(utf8.encode(jsonEncode({'tables': tables}))),
      passphrase,
    );
    await _db.setMeta(_lastBackupKey, createdAt.toIso8601String());
    return file;
  }

  /// Reads a file's header without its passphrase.
  static BackupHeader readHeader(Uint8List file) => _split(file).header;

  /// Restores a backup into this phone, by merging.
  ///
  /// Refuses a file from another pharmacy or another branch: queued operations are pushed
  /// under the branch this phone stands in, so restoring Bole's sales in Piassa would
  /// record them as Piassa's.
  Future<RestoreResult> restore(
    Uint8List file, {
    required String passphrase,
    required String tenantId,
    required String branchId,
  }) async {
    final parts = _split(file);
    if (parts.header.tenantId != tenantId) {
      throw const BackupException(BackupProblem.otherPharmacy);
    }
    if (parts.header.branchId != branchId) {
      throw const BackupException(BackupProblem.otherBranch);
    }

    final List<int> packed;
    try {
      packed = await _open(parts, passphrase);
    } on SecretBoxAuthenticationError {
      throw const BackupException(BackupProblem.wrongPassphrase);
    }

    final Map<String, dynamic> tables;
    try {
      tables = (jsonDecode(utf8.decode(gzip.decode(packed)))
          as Map<String, dynamic>)['tables'] as Map<String, dynamic>;
    } catch (_) {
      throw const BackupException(BackupProblem.notABackup);
    }

    var records = 0;
    var restored = 0;
    var alreadyHere = 0;

    await _db.db.transaction((txn) async {
      for (final table in _authored) {
        final rows = (tables[table] as List<dynamic>?) ?? const [];
        if (rows.isEmpty) continue;
        final columns = await _columnsOf(txn, table);
        for (final raw in rows) {
          final row = Map<String, Object?>.from(raw as Map)
            // A backup from a newer or older schema: keep the columns this one has.
            ..removeWhere((key, _) => !columns.contains(key));
          try {
            final id = await txn.insert(table, row,
                conflictAlgorithm: ConflictAlgorithm.ignore);
            if (id != 0) records++;
          } on DatabaseException {
            // A row this phone cannot hold — a cash-up whose shift lost out to one
            // already open here, say. Its *operation* is still restored below, so the
            // server gets it; only this phone's own history page lacks the line.
          }
        }
      }

      // The part that exists nowhere else. Appended after whatever this phone has queued,
      // in the order the file had them: a shift still opens before its cash-up.
      final queued = ((tables['outbox'] as List<dynamic>?) ?? const [])
          .map((r) => Map<String, Object?>.from(r as Map))
          .toList()
        ..sort((a, b) =>
            (a['terminal_seq']! as int).compareTo(b['terminal_seq']! as int));
      for (final row in queued) {
        final exists = await txn.query('outbox',
            columns: ['op_id'],
            where: 'op_id = ?',
            whereArgs: [row['op_id']],
            limit: 1);
        if (exists.isNotEmpty) {
          alreadyHere++;
          continue;
        }
        final seq = await _nextSeq(txn);
        await txn.insert('outbox', {
          'op_id': row['op_id'],
          'terminal_seq': seq,
          'entity_type': row['entity_type'],
          'entity_id': row['entity_id'],
          'payload_json': row['payload_json'],
          'created_at': row['created_at'],
          // A fresh start: whatever stopped it on the lost phone — no network, an older
          // server — is not a fact about this one (ADR-012 §2).
          'attempts': 0,
          'last_error': null,
          'needs_attention': 0,
        });
        if (row['entity_type'] == 'sale') {
          await txn.update('sale', {'synced': 0},
              where: 'id = ?', whereArgs: [row['entity_id']]);
        }
        restored++;
      }
    });

    return RestoreResult(
      operationsRestored: restored,
      operationsAlreadyHere: alreadyHere,
      recordsRestored: records,
    );
  }

  static Future<Set<String>> _columnsOf(
      DatabaseExecutor txn, String table) async {
    final rows = await txn.rawQuery('PRAGMA table_info($table)');
    return rows.map((r) => r['name']! as String).toSet();
  }

  /// The outbox's own counter (see `Outbox._nextSeq`), so restored operations are numbered
  /// from the same sequence as everything else this phone queues.
  static Future<int> _nextSeq(DatabaseExecutor txn) async {
    final rows = await txn.query('meta',
        where: 'key = ?', whereArgs: ['terminal_seq'], limit: 1);
    final next =
        (rows.isEmpty ? 0 : int.parse(rows.first['value']! as String)) + 1;
    await txn.insert('meta', {'key': 'terminal_seq', 'value': '$next'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    return next;
  }

  // ------------------------------------------------------------------ the file
  //
  //   "PHARMAET-BACKUP\n"
  //   header length  (4 bytes, big-endian)
  //   header         (UTF-8 JSON — readable without the passphrase)
  //   salt           (16 bytes)   key = PBKDF2-HMAC-SHA256(passphrase, salt, rounds)
  //   rounds         (4 bytes, big-endian)
  //   nonce          (12 bytes)
  //   ciphertext     AES-256-GCM, with the magic and the header as associated data
  //   tag            (16 bytes)

  static final _aes = AesGcm.with256bits();

  Future<Uint8List> _seal(
      BackupHeader header, List<int> packed, String passphrase) async {
    final random = Random.secure();
    final salt = List<int>.generate(16, (_) => random.nextInt(256));
    final headerBytes = utf8.encode(jsonEncode(header.toJson()));
    final prefix = [
      ...ascii.encode(_magic),
      ..._u32(headerBytes.length),
      ...headerBytes,
    ];
    final key = await _deriveKey(passphrase, salt, kdfRounds);
    final box = await _aes.encrypt(packed,
        secretKey: SecretKey(key), nonce: _aes.newNonce(), aad: prefix);
    return Uint8List.fromList([
      ...prefix,
      ...salt,
      ..._u32(kdfRounds),
      ...box.nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
  }

  static Future<List<int>> _open(_Parts parts, String passphrase) async {
    final key = await _deriveKey(passphrase, parts.salt, parts.rounds);
    return _aes.decrypt(
      SecretBox(parts.cipherText, nonce: parts.nonce, mac: Mac(parts.mac)),
      secretKey: SecretKey(key),
      aad: parts.prefix,
    );
  }

  static Future<List<int>> _deriveKey(
      String passphrase, List<int> salt, int rounds) {
    Uint8List run() => OfflineCredentials.derive(passphrase, salt, rounds);
    return useIsolate ? Isolate.run(run) : Future.value(run());
  }

  static List<int> _u32(int n) =>
      [(n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff];

  static _Parts _split(Uint8List file) {
    final magic = ascii.encode(_magic);
    try {
      for (var i = 0; i < magic.length; i++) {
        if (file[i] != magic[i]) {
          throw const BackupException(BackupProblem.notABackup);
        }
      }
      int u32(int o) =>
          (file[o] << 24) |
          (file[o + 1] << 16) |
          (file[o + 2] << 8) |
          file[o + 3];
      final headerLength = u32(magic.length);
      final headerEnd = magic.length + 4 + headerLength;
      if (headerLength <= 0 ||
          headerLength > 65536 ||
          headerEnd > file.length) {
        throw const BackupException(BackupProblem.notABackup);
      }
      final header = BackupHeader.fromJson(
          jsonDecode(utf8.decode(file.sublist(magic.length + 4, headerEnd)))
              as Map<String, dynamic>);
      if (header.format > format) {
        throw const BackupException(BackupProblem.tooNew);
      }
      final body = file.sublist(headerEnd);
      if (body.length < 16 + 4 + 12 + 16) {
        throw const BackupException(BackupProblem.notABackup);
      }
      final rounds =
          (body[16] << 24) | (body[17] << 16) | (body[18] << 8) | body[19];
      // A file claiming a billion rounds is not asking to be decrypted, it is asking the
      // phone to hang.
      if (rounds < 1000 || rounds > 5000000) {
        throw const BackupException(BackupProblem.notABackup);
      }
      return _Parts(
        header: header,
        prefix: file.sublist(0, headerEnd),
        salt: body.sublist(0, 16),
        rounds: rounds,
        nonce: body.sublist(20, 32),
        cipherText: body.sublist(32, body.length - 16),
        mac: body.sublist(body.length - 16),
      );
    } on BackupException {
      rethrow;
    } catch (_) {
      // Too short, not JSON, missing a field: all of them are "this is not a backup".
      throw const BackupException(BackupProblem.notABackup);
    }
  }
}

class _Parts {
  const _Parts({
    required this.header,
    required this.prefix,
    required this.salt,
    required this.rounds,
    required this.nonce,
    required this.cipherText,
    required this.mac,
  });
  final BackupHeader header;
  final List<int> prefix;
  final List<int> salt;
  final int rounds;
  final List<int> nonce;
  final List<int> cipherText;
  final List<int> mac;
}
