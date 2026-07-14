import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:postgres/postgres.dart';

import '../models.dart';
import 'db_driver.dart';

class PostgresDriver extends DbDriver {
  PostgresDriver(super.profile);

  Connection? _conn;
  Connection get conn => _conn ?? (throw DriverException('Not connected'));

  @override
  bool get supportsSql => true;

  @override
  String get queryHint => 'SELECT * FROM my_table LIMIT 100;';

  @override
  Future<void> connect() async {
    _conn = await Connection.open(
      Endpoint(
        host: profile.host,
        port: profile.port,
        database: profile.database,
        username: profile.user,
        password: profile.password,
      ),
      settings: ConnectionSettings(
        sslMode: profile.useSsl ? SslMode.require : SslMode.disable,
        connectTimeout: const Duration(seconds: 10),
      ),
    );
  }

  @override
  Future<void> close() async {
    await _conn?.close();
    _conn = null;
  }

  @override
  Future<List<String>> listTables() async {
    final rs = await conn.execute(
        "SELECT table_name FROM information_schema.tables "
        "WHERE table_schema = 'public' ORDER BY table_name");
    return [for (final r in rs) r[0] as String];
  }

  @override
  Future<List<ColumnInfo>> describe(String table) async {
    final rs = await conn.execute(
      Sql.named('''
        SELECT c.column_name, c.data_type, c.is_nullable,
               EXISTS (
                 SELECT 1 FROM information_schema.key_column_usage k
                 JOIN information_schema.table_constraints tc
                   ON tc.constraint_name = k.constraint_name
                  AND tc.table_schema = k.table_schema
                 WHERE tc.constraint_type = 'PRIMARY KEY'
                   AND k.table_schema = 'public' AND k.table_name = c.table_name
                   AND k.column_name = c.column_name
               ) AS is_pk
        FROM information_schema.columns c
        WHERE c.table_schema = 'public' AND c.table_name = @t
        ORDER BY c.ordinal_position
      '''),
      parameters: {'t': table},
    );
    return [
      for (final r in rs)
        ColumnInfo(r[0] as String,
            type: r[1] as String,
            nullable: r[2] == 'YES',
            isPrimaryKey: r[3] as bool),
    ];
  }

  @override
  Future<int> countRows(String table, {QuerySpec? spec}) async {
    final where = whereClause(spec);
    final rs = await conn.execute('SELECT COUNT(*) FROM ${_q(table)}'
        '${where == null ? '' : ' WHERE $where'}');
    return rs.first[0] as int;
  }

  @override
  Future<QueryResult> fetchRows(String table,
      {int offset = 0, int limit = 100, QuerySpec? spec}) async {
    final where = whereClause(spec);
    final order = orderClause(spec);
    final tail = '${where == null ? '' : ' WHERE $where'}'
        '${order == null ? '' : ' ORDER BY $order'}'
        ' LIMIT $limit OFFSET $offset';
    // ctid addresses a physical row, so tables without a primary key stay
    // editable. Views have no ctid — fall back to a read-only select.
    try {
      final rs = await conn.execute(
          'SELECT ctid::text AS _ctid_, * FROM ${_q(table)}$tail');
      final cols = [
        for (final c in rs.schema.columns.skip(1)) c.columnName ?? '?'
      ];
      return QueryResult(
        columns: cols,
        rows: [for (final r in rs) r.sublist(1)],
        rowRefs: [for (final r in rs) r[0]],
      );
    } on ServerException {
      final rs = await conn.execute('SELECT * FROM ${_q(table)}$tail');
      return QueryResult(
        columns: [for (final c in rs.schema.columns) c.columnName ?? '?'],
        rows: [for (final r in rs) r.toList()],
      );
    }
  }

  @override
  Future<QueryResult> runRaw(String query) async {
    final rs = await conn.execute(query);
    if (rs.schema.columns.isNotEmpty) {
      return QueryResult(
        columns: [for (final c in rs.schema.columns) c.columnName ?? '?'],
        rows: [for (final r in rs) r.toList()],
      );
    }
    return QueryResult(
        affectedRows: rs.affectedRows,
        message: '${rs.affectedRows} row(s) affected');
  }

  @override
  Future<void> insertRow(String table, Map<String, CellEdit> values) async {
    final cols = values.keys.map(_q).join(', ');
    final vals = values.values.map(sqlLiteral).join(', ');
    await conn.execute('INSERT INTO ${_q(table)} ($cols) VALUES ($vals)');
  }

  @override
  Future<void> updateRow(
      String table, Object? rowRef, Map<String, CellEdit> values) async {
    if (rowRef == null) throw DriverException('Row is not editable');
    final sets =
        values.entries.map((e) => '${_q(e.key)} = ${sqlLiteral(e.value)}').join(', ');
    await conn.execute(
        "UPDATE ${_q(table)} SET $sets WHERE ctid = '$rowRef'::tid");
  }

  @override
  Future<void> deleteRow(String table, Object? rowRef) async {
    if (rowRef == null) throw DriverException('Row is not editable');
    await conn
        .execute("DELETE FROM ${_q(table)} WHERE ctid = '$rowRef'::tid");
  }

  /// Plain-SQL dump: CREATE TABLE (from information_schema) + INSERTs.
  @override
  Future<String> backup(String destDir) async {
    final dest = p.join(
        destDir, '${profile.database}_backup_${timestamp()}.sql');
    final sink = File(dest).openWrite();
    sink.writeln('-- Database Manager backup of ${profile.database}'
        ' (${DateTime.now().toIso8601String()})');
    try {
      for (final table in await listTables()) {
        final cols = await describe(table);
        sink.writeln('\n-- Table: $table');
        sink.writeln('CREATE TABLE IF NOT EXISTS ${_q(table)} (');
        final pk = [for (final c in cols.where((c) => c.isPrimaryKey)) _q(c.name)];
        final defs = [
          for (final c in cols)
            '  ${_q(c.name)} ${c.type}${c.nullable ? '' : ' NOT NULL'}',
          if (pk.isNotEmpty) '  PRIMARY KEY (${pk.join(', ')})',
        ];
        sink.writeln('${defs.join(',\n')}\n);');

        final rs = await conn.execute('SELECT * FROM ${_q(table)}');
        final names =
            [for (final c in rs.schema.columns) _q(c.columnName ?? '?')].join(', ');
        for (final row in rs) {
          final vals = row.map(_pgLiteral).join(', ');
          sink.writeln('INSERT INTO ${_q(table)} ($names) VALUES ($vals);');
        }
      }
    } finally {
      await sink.close();
    }
    return dest;
  }

  String _pgLiteral(Object? v) {
    if (v == null) return 'NULL';
    if (v is num || v is BigInt) return v.toString();
    if (v is bool) return v ? 'TRUE' : 'FALSE';
    if (v is DateTime) return "'${v.toIso8601String()}'";
    if (v is List<int>) {
      final hex = v.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      return "'\\x$hex'";
    }
    return "'${v.toString().replaceAll("'", "''")}'";
  }

  String _q(String ident) => '"${ident.replaceAll('"', '""')}"';
}
