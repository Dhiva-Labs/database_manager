import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../models.dart';
import 'db_driver.dart';

class SqliteDriver extends DbDriver {
  SqliteDriver(super.profile);

  Database? _db;
  Database get db => _db ?? (throw DriverException('Not connected'));

  @override
  bool get supportsSql => true;

  @override
  String get queryHint => 'SELECT * FROM my_table LIMIT 100;';

  @override
  Future<void> connect() async {
    if (!File(profile.filePath).existsSync()) {
      throw DriverException('File not found: ${profile.filePath}');
    }
    _db = sqlite3.open(profile.filePath);
    if (profile.password.isNotEmpty) {
      // The bundled library is SQLCipher (see pubspec hooks), so PRAGMA key
      // unlocks encrypted databases.
      db.execute(
          "PRAGMA key = '${profile.password.replaceAll("'", "''")}'");
    }
    // Fail fast if the file is not readable — either it's not a SQLite
    // database at all, or it's encrypted and the key is missing/wrong.
    try {
      db.select('SELECT 1 FROM sqlite_master LIMIT 1');
    } on SqliteException {
      final looksSqlite = _hasSqliteHeader(profile.filePath);
      await close();
      if (looksSqlite) rethrow; // plain header but unreadable: corrupt file
      throw PasswordRequiredException(profile.password.isEmpty
          ? 'This database is encrypted. Enter its password to open it.'
          : 'Wrong password — could not unlock the database.');
    }
  }

  /// Test hook: true when the file is a plaintext (unencrypted) SQLite file.
  static bool hasSqliteHeaderForTest(String path) => _hasSqliteHeader(path);

  /// Unencrypted SQLite files start with the magic string "SQLite format 3".
  static bool _hasSqliteHeader(String path) {
    try {
      final raf = File(path).openSync();
      final header = raf.readSync(15);
      raf.closeSync();
      return String.fromCharCodes(header) == 'SQLite format 3';
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> close() async {
    _db?.close();
    _db = null;
  }

  @override
  Future<List<String>> listTables() async {
    final rs = db.select(
        "SELECT name FROM sqlite_master WHERE type IN ('table','view') "
        "AND name NOT LIKE 'sqlite_%' ORDER BY name");
    return [for (final r in rs) r['name'] as String];
  }

  @override
  Future<List<ColumnInfo>> describe(String table) async {
    final rs = db.select('PRAGMA table_info(${_q(table)})');
    return [
      for (final r in rs)
        ColumnInfo(r['name'] as String,
            type: (r['type'] as String?) ?? '',
            isPrimaryKey: (r['pk'] as int) > 0,
            nullable: (r['notnull'] as int) == 0),
    ];
  }

  @override
  Future<int> countRows(String table, {QuerySpec? spec}) async {
    final where = whereClause(spec);
    return db
        .select('SELECT COUNT(*) c FROM ${_q(table)}'
            '${where == null ? '' : ' WHERE $where'}')
        .first['c'] as int;
  }

  @override
  Future<QueryResult> fetchRows(String table,
      {int offset = 0, int limit = 100, QuerySpec? spec}) async {
    final where = whereClause(spec);
    final order = orderClause(spec);
    final tail = '${where == null ? '' : ' WHERE $where'}'
        '${order == null ? '' : ' ORDER BY $order'}'
        ' LIMIT $limit OFFSET $offset';
    // rowid lets us address rows without a primary key. WITHOUT ROWID tables
    // and views don't have one, so fall back to a plain (read-only) select.
    try {
      final rs =
          db.select('SELECT rowid AS _rowid_, * FROM ${_q(table)}$tail');
      final cols = rs.columnNames.sublist(1);
      return QueryResult(
        columns: cols,
        rows: [for (final r in rs) r.values.sublist(1)],
        rowRefs: [for (final r in rs) r.values.first],
      );
    } on SqliteException {
      final rs = db.select('SELECT * FROM ${_q(table)}$tail');
      return QueryResult(
        columns: rs.columnNames,
        rows: [for (final r in rs) r.values.toList()],
      );
    }
  }

  @override
  Future<QueryResult> runRaw(String query) async {
    final head = query.trimLeft().toLowerCase();
    final isSelect = head.startsWith('select') ||
        head.startsWith('with') ||
        head.startsWith('pragma') ||
        head.startsWith('explain');
    if (isSelect) {
      final rs = db.select(query);
      return QueryResult(
        columns: rs.columnNames,
        rows: [for (final r in rs) r.values.toList()],
      );
    }
    db.execute(query);
    return QueryResult(
        affectedRows: db.updatedRows,
        message: '${db.updatedRows} row(s) affected');
  }

  @override
  Future<void> insertRow(String table, Map<String, CellEdit> values) async {
    final cols = values.keys.map(_q).join(', ');
    final vals = values.values.map(sqlLiteral).join(', ');
    db.execute('INSERT INTO ${_q(table)} ($cols) VALUES ($vals)');
  }

  @override
  Future<void> updateRow(
      String table, Object? rowRef, Map<String, CellEdit> values) async {
    if (rowRef == null) throw DriverException('Row is not editable (no rowid)');
    final sets =
        values.entries.map((e) => '${_q(e.key)} = ${sqlLiteral(e.value)}').join(', ');
    db.execute('UPDATE ${_q(table)} SET $sets WHERE rowid = $rowRef');
  }

  @override
  Future<void> deleteRow(String table, Object? rowRef) async {
    if (rowRef == null) throw DriverException('Row is not editable (no rowid)');
    db.execute('DELETE FROM ${_q(table)} WHERE rowid = $rowRef');
  }

  @override
  Future<String> backup(String destDir) async {
    final base = p.basenameWithoutExtension(profile.filePath);
    final dest = p.join(destDir, '${base}_backup_${timestamp()}.db');
    // VACUUM INTO makes a consistent, compacted copy even while open. On an
    // encrypted database SQLCipher keeps the copy encrypted with the same
    // key, so a backup never leaks the contents.
    db.execute("VACUUM INTO '${dest.replaceAll("'", "''")}'");
    return dest;
  }

  @override
  bool get supportsEncryptionManagement => true;

  @override
  Future<void> setPassword(String newPassword) async {
    final current = profile.password;
    if (current == newPassword) return;

    if (current.isNotEmpty && newPassword.isNotEmpty) {
      // Both encrypted: rekey in place, no file swap needed.
      db.execute("PRAGMA rekey = '${_esc(newPassword)}'");
      profile.password = newPassword;
      return;
    }

    // Encrypt (plain -> encrypted) or decrypt (encrypted -> plain): export the
    // whole database into a new file with the target key, then swap it in.
    final tmp = '${profile.filePath}.dbmtmp';
    final tmpFile = File(tmp);
    if (tmpFile.existsSync()) tmpFile.deleteSync();
    try {
      // KEY '' produces an unencrypted attached database.
      db.execute(
          "ATTACH DATABASE '${_esc(tmp)}' AS _target KEY '${_esc(newPassword)}'");
      db.execute("SELECT sqlcipher_export('_target')");
      db.execute('DETACH DATABASE _target');
    } catch (e) {
      if (tmpFile.existsSync()) tmpFile.deleteSync();
      throw DriverException('Could not change encryption: $e');
    }
    await close();
    File(profile.filePath).deleteSync();
    tmpFile.renameSync(profile.filePath);
    profile.password = newPassword;
    await connect(); // reopen with the new key (or none)
  }

  static String _esc(String s) => s.replaceAll("'", "''");

  String _q(String ident) => '"${ident.replaceAll('"', '""')}"';
}
