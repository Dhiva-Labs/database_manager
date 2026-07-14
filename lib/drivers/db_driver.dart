import '../models.dart';

/// Common interface every database backend implements.
abstract class DbDriver {
  final ConnectionProfile profile;
  DbDriver(this.profile);

  /// True for engines that speak SQL; false for MongoDB / LMDB.
  bool get supportsSql;

  /// Placeholder text shown in the query editor.
  String get queryHint;

  /// What a "table" is called in this engine (table / collection / sub-db).
  String get tableNoun => 'table';

  Future<void> connect();
  Future<void> close();

  Future<List<String>> listTables();
  Future<List<ColumnInfo>> describe(String table);
  Future<int> countRows(String table, {QuerySpec? spec});

  Future<QueryResult> fetchRows(String table,
      {int offset = 0, int limit = 100, QuerySpec? spec});

  /// Identifier quoting for this engine (overridden by MySQL for backticks).
  String quoteIdent(String ident) => '"${ident.replaceAll('"', '""')}"';

  /// WHERE clause for a [QuerySpec], or null when there are no filters.
  String? whereClause(QuerySpec? spec, {bool escapeBackslash = false}) {
    if (spec == null || spec.filters.isEmpty) return null;
    String strLit(String s) {
      var v = s.replaceAll("'", "''");
      if (escapeBackslash) v = v.replaceAll(r'\', r'\\');
      return "'$v'";
    }

    final parts = <String>[];
    for (final f in spec.filters.where((f) => f.column.isNotEmpty)) {
      final col = quoteIdent(f.column);
      final lit =
          sqlLiteral(CellEdit(f.value, false), escapeBackslash: escapeBackslash);
      parts.add(switch (f.op) {
        FilterOp.equals => '$col = $lit',
        FilterOp.notEquals => '$col <> $lit',
        FilterOp.contains => '$col LIKE ${strLit('%${f.value}%')}',
        FilterOp.startsWith => '$col LIKE ${strLit('${f.value}%')}',
        FilterOp.greaterThan => '$col > $lit',
        FilterOp.lessThan => '$col < $lit',
        FilterOp.greaterOrEqual => '$col >= $lit',
        FilterOp.lessOrEqual => '$col <= $lit',
        FilterOp.isNull => "($col IS NULL OR $col = '')",
        FilterOp.isNotNull => "($col IS NOT NULL AND $col <> '')",
      });
    }
    return parts.isEmpty ? null : parts.join(' AND ');
  }

  /// ORDER BY clause, or null when the spec doesn't sort.
  String? orderClause(QuerySpec? spec) {
    if (spec?.sortColumn == null) return null;
    return '${quoteIdent(spec!.sortColumn!)}${spec.sortDescending ? ' DESC' : ''}';
  }

  /// The runnable query text this spec translates to — shown in the UI so
  /// users can learn from it or copy it into the query tab.
  String describeQuery(String table, QuerySpec? spec, {int limit = 100}) {
    final where = whereClause(spec);
    final order = orderClause(spec);
    return 'SELECT * FROM ${quoteIdent(table)}'
        '${where == null ? '' : '\nWHERE $where'}'
        '${order == null ? '' : '\nORDER BY $order'}'
        '\nLIMIT $limit;';
  }

  /// Runs whatever the query tab holds: SQL, a Mongo command, an LMDB scan.
  Future<QueryResult> runRaw(String query);

  Future<void> insertRow(String table, Map<String, CellEdit> values);
  Future<void> updateRow(String table, Object? rowRef, Map<String, CellEdit> values);
  Future<void> deleteRow(String table, Object? rowRef);

  /// Writes a backup into [destDir]; returns the path of what was created.
  Future<String> backup(String destDir);

  /// True when this database can be encrypted / rekeyed by the app itself
  /// (SQLite via SQLCipher). Server engines manage encryption elsewhere.
  bool get supportsEncryptionManagement => false;

  /// Sets, changes, or removes the database password in place. An empty
  /// [newPassword] removes encryption. Updates [profile] password on success.
  Future<void> setPassword(String newPassword) async =>
      throw DriverException('Changing the password is not supported here.');
}

class DriverException implements Exception {
  final String message;
  DriverException(this.message);
  @override
  String toString() => message;
}

/// The database needs a (different) password — the UI catches this and
/// prompts the user, then retries the connection.
class PasswordRequiredException implements Exception {
  final String message;
  PasswordRequiredException(this.message);
  @override
  String toString() => message;
}

String timestamp() {
  final n = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${n.year}${two(n.month)}${two(n.day)}_${two(n.hour)}${two(n.minute)}${two(n.second)}';
}

/// Renders a [CellEdit] as a SQL literal. [escapeBackslash] is needed for
/// MySQL's default string syntax.
String sqlLiteral(CellEdit v, {bool escapeBackslash = false}) {
  if (v.isNull) return 'NULL';
  final t = v.text;
  final trimmed = t.trim();
  if (trimmed.isNotEmpty && num.tryParse(trimmed) != null && trimmed == t) {
    return trimmed;
  }
  final lower = trimmed.toLowerCase();
  if (lower == 'true' || lower == 'false') return lower.toUpperCase();
  var s = t.replaceAll("'", "''");
  if (escapeBackslash) s = s.replaceAll(r'\', r'\\');
  return "'$s'";
}
