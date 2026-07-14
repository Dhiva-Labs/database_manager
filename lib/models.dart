import 'dart:convert';

enum DbKind { sqlite, mysql, postgres, mongodb, lmdb }

extension DbKindInfo on DbKind {
  String get label => switch (this) {
        DbKind.sqlite => 'SQLite',
        DbKind.mysql => 'MySQL / MariaDB',
        DbKind.postgres => 'PostgreSQL',
        DbKind.mongodb => 'MongoDB',
        DbKind.lmdb => 'LMDB',
      };

  bool get isFileBased => this == DbKind.sqlite || this == DbKind.lmdb;

  int get defaultPort => switch (this) {
        DbKind.mysql => 3306,
        DbKind.postgres => 5432,
        DbKind.mongodb => 27017,
        _ => 0,
      };
}

class ConnectionProfile {
  String id;
  String name;
  DbKind kind;
  String filePath; // sqlite / lmdb
  String host;
  int port;
  String user;
  String password;
  String database;
  bool useSsl;

  /// Never store the password; prompt for it on every connect.
  bool askPassword;

  ConnectionProfile({
    required this.id,
    required this.name,
    required this.kind,
    this.filePath = '',
    this.host = 'localhost',
    this.port = 0,
    this.user = '',
    this.password = '',
    this.database = '',
    this.useSsl = false,
    this.askPassword = false,
  });

  String get subtitle => kind.isFileBased
      ? filePath
      : '$host:$port${database.isEmpty ? '' : '/$database'}';

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind.name,
        'filePath': filePath,
        'host': host,
        'port': port,
        'user': user,
        'password': password,
        'database': database,
        'useSsl': useSsl,
        'askPassword': askPassword,
      };

  factory ConnectionProfile.fromJson(Map<String, dynamic> j) =>
      ConnectionProfile(
        id: j['id'] as String,
        name: j['name'] as String,
        kind: DbKind.values.firstWhere((k) => k.name == j['kind'],
            orElse: () => DbKind.sqlite),
        filePath: j['filePath'] as String? ?? '',
        host: j['host'] as String? ?? 'localhost',
        port: j['port'] as int? ?? 0,
        user: j['user'] as String? ?? '',
        password: j['password'] as String? ?? '',
        database: j['database'] as String? ?? '',
        useSsl: j['useSsl'] as bool? ?? false,
        askPassword: j['askPassword'] as bool? ?? false,
      );

  ConnectionProfile copy() => ConnectionProfile.fromJson(toJson());
}

/// Result of any query / table page fetch.
class QueryResult {
  final List<String> columns;
  final List<List<Object?>> rows;

  /// Driver-specific handle used to address a row for UPDATE / DELETE.
  /// Parallel to [rows]; null entries mean the row is not editable.
  final List<Object?> rowRefs;
  final int? affectedRows;
  final String? message;

  QueryResult({
    this.columns = const [],
    this.rows = const [],
    List<Object?>? rowRefs,
    this.affectedRows,
    this.message,
  }) : rowRefs = rowRefs ?? List.filled(rows.length, null);

  bool get hasRows => columns.isNotEmpty;
}

class ColumnInfo {
  final String name;
  final String type;
  final bool isPrimaryKey;
  final bool nullable;

  ColumnInfo(this.name,
      {this.type = '', this.isPrimaryKey = false, this.nullable = true});
}

/// Plain-English filter operators for the visual query builder.
enum FilterOp {
  equals('is'),
  notEquals('is not'),
  contains('contains'),
  startsWith('starts with'),
  greaterThan('is more than'),
  lessThan('is less than'),
  greaterOrEqual('is at least'),
  lessOrEqual('is at most'),
  isNull('is empty'),
  isNotNull('is not empty');

  final String label;
  const FilterOp(this.label);

  bool get needsValue => this != FilterOp.isNull && this != FilterOp.isNotNull;
}

class FilterCondition {
  String column;
  FilterOp op;
  String value;
  FilterCondition({required this.column, this.op = FilterOp.equals, this.value = ''});
}

/// A structured "find rows" request built in the UI without writing SQL.
class QuerySpec {
  final List<FilterCondition> filters;
  final String? sortColumn;
  final bool sortDescending;

  const QuerySpec({
    this.filters = const [],
    this.sortColumn,
    this.sortDescending = false,
  });

  bool get isEmpty => filters.isEmpty && sortColumn == null;
}

/// Value coming back from the row-editor dialog.
class CellEdit {
  final String text;
  final bool isNull;
  const CellEdit(this.text, this.isNull);

  /// Best-effort conversion for document stores: JSON if it parses, else text.
  Object? toJsonish() {
    if (isNull) return null;
    try {
      return jsonDecode(text);
    } catch (_) {
      return text;
    }
  }
}
