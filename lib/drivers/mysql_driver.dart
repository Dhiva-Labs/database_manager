import 'dart:io';

import 'package:mysql_client/mysql_client.dart';
import 'package:path/path.dart' as p;

import '../models.dart';
import 'db_driver.dart';

class MysqlDriver extends DbDriver {
  MysqlDriver(super.profile);

  MySQLConnection? _conn;
  MySQLConnection get conn => _conn ?? (throw DriverException('Not connected'));

  final Map<String, List<ColumnInfo>> _describeCache = {};

  @override
  bool get supportsSql => true;

  @override
  String get queryHint => 'SELECT * FROM my_table LIMIT 100;';

  @override
  Future<void> connect() async {
    _conn = await MySQLConnection.createConnection(
      host: profile.host,
      port: profile.port,
      userName: profile.user,
      password: profile.password,
      databaseName: profile.database.isEmpty ? null : profile.database,
      secure: profile.useSsl,
    );
    await conn.connect();
  }

  @override
  Future<void> close() async {
    await _conn?.close();
    _conn = null;
  }

  @override
  Future<List<String>> listTables() async {
    final rs = await conn.execute('SHOW TABLES');
    return [for (final r in rs.rows) r.colAt(0) ?? ''];
  }

  @override
  Future<List<ColumnInfo>> describe(String table) async {
    final rs = await conn.execute('SHOW COLUMNS FROM ${_q(table)}');
    final cols = [
      for (final r in rs.rows)
        ColumnInfo(r.colAt(0) ?? '',
            type: r.colAt(1) ?? '',
            nullable: r.colAt(2) == 'YES',
            isPrimaryKey: r.colAt(3) == 'PRI'),
    ];
    _describeCache[table] = cols;
    return cols;
  }

  @override
  String quoteIdent(String ident) => '`${ident.replaceAll('`', '``')}`';

  @override
  String? whereClause(QuerySpec? spec, {bool escapeBackslash = true}) =>
      super.whereClause(spec, escapeBackslash: true);

  @override
  Future<int> countRows(String table, {QuerySpec? spec}) async {
    final where = whereClause(spec);
    final rs = await conn.execute('SELECT COUNT(*) FROM ${_q(table)}'
        '${where == null ? '' : ' WHERE $where'}');
    return int.parse(rs.rows.first.colAt(0) ?? '0');
  }

  @override
  Future<QueryResult> fetchRows(String table,
      {int offset = 0, int limit = 100, QuerySpec? spec}) async {
    final cols = await describe(table);
    final where = whereClause(spec);
    final order = orderClause(spec);
    final rs = await conn.execute('SELECT * FROM ${_q(table)}'
        '${where == null ? '' : ' WHERE $where'}'
        '${order == null ? '' : ' ORDER BY $order'}'
        ' LIMIT $limit OFFSET $offset');
    final names = [for (final c in rs.cols) c.name];
    final rows = [
      for (final r in rs.rows) [for (var i = 0; i < names.length; i++) r.colAt(i)]
    ];
    // A row is addressed by its primary-key values; without a PK we match on
    // every column (LIMIT 1) — see _whereFor().
    final pkCols = [for (final c in cols.where((c) => c.isPrimaryKey)) c.name];
    final refs = <Object?>[];
    for (final row in rows) {
      final ref = <String, String?>{};
      final keyCols = pkCols.isNotEmpty ? pkCols : names;
      for (final k in keyCols) {
        ref[k] = row[names.indexOf(k)];
      }
      refs.add(ref);
    }
    return QueryResult(columns: names, rows: rows, rowRefs: refs);
  }

  @override
  Future<QueryResult> runRaw(String query) async {
    final rs = await conn.execute(query);
    if (rs.cols.isNotEmpty) {
      final names = [for (final c in rs.cols) c.name];
      return QueryResult(
        columns: names,
        rows: [
          for (final r in rs.rows)
            [for (var i = 0; i < names.length; i++) r.colAt(i)]
        ],
      );
    }
    return QueryResult(
        affectedRows: rs.affectedRows.toInt(),
        message: '${rs.affectedRows} row(s) affected');
  }

  String _whereFor(Object? rowRef) {
    final ref = (rowRef as Map).cast<String, String?>();
    return ref.entries.map((e) {
      if (e.value == null) return '${_q(e.key)} IS NULL';
      final v = e.value!.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
      return "${_q(e.key)} = '$v'";
    }).join(' AND ');
  }

  @override
  Future<void> insertRow(String table, Map<String, CellEdit> values) async {
    final cols = values.keys.map(_q).join(', ');
    final vals = values.values
        .map((v) => sqlLiteral(v, escapeBackslash: true))
        .join(', ');
    await conn.execute('INSERT INTO ${_q(table)} ($cols) VALUES ($vals)');
  }

  @override
  Future<void> updateRow(
      String table, Object? rowRef, Map<String, CellEdit> values) async {
    if (rowRef == null) throw DriverException('Row is not editable');
    final sets = values.entries
        .map((e) => '${_q(e.key)} = ${sqlLiteral(e.value, escapeBackslash: true)}')
        .join(', ');
    await conn.execute(
        'UPDATE ${_q(table)} SET $sets WHERE ${_whereFor(rowRef)} LIMIT 1');
  }

  @override
  Future<void> deleteRow(String table, Object? rowRef) async {
    if (rowRef == null) throw DriverException('Row is not editable');
    await conn.execute(
        'DELETE FROM ${_q(table)} WHERE ${_whereFor(rowRef)} LIMIT 1');
  }

  /// Plain-SQL dump using SHOW CREATE TABLE + INSERT statements.
  @override
  Future<String> backup(String destDir) async {
    final dest =
        p.join(destDir, '${profile.database}_backup_${timestamp()}.sql');
    final sink = File(dest).openWrite();
    sink.writeln('-- Database Manager backup of ${profile.database}'
        ' (${DateTime.now().toIso8601String()})');
    try {
      for (final table in await listTables()) {
        final create = await conn.execute('SHOW CREATE TABLE ${_q(table)}');
        sink.writeln('\n-- Table: $table');
        sink.writeln('${create.rows.first.colAt(1)};');
        final rs = await conn.execute('SELECT * FROM ${_q(table)}');
        final names = [for (final c in rs.cols) _q(c.name)].join(', ');
        for (final r in rs.rows) {
          final vals = <String>[];
          for (var i = 0; i < rs.cols.length; i++) {
            final v = r.colAt(i);
            vals.add(v == null
                ? 'NULL'
                : "'${v.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'");
          }
          sink.writeln(
              'INSERT INTO ${_q(table)} ($names) VALUES (${vals.join(', ')});');
        }
      }
    } finally {
      await sink.close();
    }
    return dest;
  }

  String _q(String ident) => '`${ident.replaceAll('`', '``')}`';
}
