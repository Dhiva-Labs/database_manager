import 'dart:convert';
import 'dart:io';

import 'package:mongo_dart/mongo_dart.dart';
import 'package:path/path.dart' as p;

import '../models.dart';
import 'db_driver.dart';

class MongoDriver extends DbDriver {
  MongoDriver(super.profile);

  Db? _db;
  Db get db => _db ?? (throw DriverException('Not connected'));

  @override
  bool get supportsSql => false;

  @override
  String get tableNoun => 'collection';

  @override
  String get queryHint =>
      'Enter a MongoDB command as JSON, e.g.\n'
      '{"find": "users", "filter": {"age": {"\$gt": 21}}, "limit": 50}\n'
      'or {"count": "users"} or {"aggregate": "users", "pipeline": [...], "cursor": {}}';

  String _uri() {
    final auth = profile.user.isEmpty
        ? ''
        : '${Uri.encodeComponent(profile.user)}:${Uri.encodeComponent(profile.password)}@';
    final dbName = profile.database.isEmpty ? 'test' : profile.database;
    final ssl = profile.useSsl ? '?ssl=true' : '';
    return 'mongodb://$auth${profile.host}:${profile.port}/$dbName$ssl';
  }

  @override
  Future<void> connect() async {
    _db = await Db.create(_uri());
    await db.open();
  }

  @override
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  @override
  Future<List<String>> listTables() async {
    final names = await db.getCollectionNames();
    return names.whereType<String>().toList()..sort();
  }

  @override
  Future<List<ColumnInfo>> describe(String table) async {
    // Schemaless: infer fields from a sample of documents.
    final docs =
        await db.collection(table).modernFind(limit: 50).toList();
    final keys = <String>{};
    for (final d in docs) {
      keys.addAll(d.keys);
    }
    return [
      for (final k in keys)
        ColumnInfo(k, type: 'field', isPrimaryKey: k == '_id'),
    ];
  }

  /// Converts a [QuerySpec] into a MongoDB filter document.
  static Map<String, dynamic> filterOf(QuerySpec? spec) {
    final m = <String, dynamic>{};
    if (spec == null) return m;
    for (final f in spec.filters.where((f) => f.column.isNotEmpty)) {
      Object? parsed = num.tryParse(f.value) ?? f.value;
      if (f.value == 'true') parsed = true;
      if (f.value == 'false') parsed = false;
      m[f.column] = switch (f.op) {
        FilterOp.equals => parsed,
        FilterOp.notEquals => {r'$ne': parsed},
        FilterOp.contains => {r'$regex': RegExp.escape(f.value), r'$options': 'i'},
        FilterOp.startsWith => {
            r'$regex': '^${RegExp.escape(f.value)}',
            r'$options': 'i'
          },
        FilterOp.greaterThan => {r'$gt': parsed},
        FilterOp.lessThan => {r'$lt': parsed},
        FilterOp.greaterOrEqual => {r'$gte': parsed},
        FilterOp.lessOrEqual => {r'$lte': parsed},
        FilterOp.isNull => null,
        FilterOp.isNotNull => {r'$ne': null},
      };
    }
    return m;
  }

  @override
  String describeQuery(String table, QuerySpec? spec, {int limit = 100}) {
    final cmd = <String, dynamic>{
      'find': table,
      if (spec != null && spec.filters.isNotEmpty) 'filter': filterOf(spec),
      if (spec?.sortColumn != null)
        'sort': {spec!.sortColumn!: spec.sortDescending ? -1 : 1},
      'limit': limit,
    };
    return const JsonEncoder.withIndent('  ').convert(cmd);
  }

  @override
  Future<int> countRows(String table, {QuerySpec? spec}) async =>
      db.collection(table).count(filterOf(spec));

  QueryResult _docsToResult(List<Map<String, dynamic>> docs) {
    final keys = <String>[];
    for (final d in docs) {
      for (final k in d.keys) {
        if (!keys.contains(k)) k == '_id' ? keys.insert(0, k) : keys.add(k);
      }
    }
    Object? cell(Object? v) {
      if (v == null || v is num || v is String || v is bool) return v;
      if (v is ObjectId) return v.oid;
      if (v is DateTime) return v.toIso8601String();
      return jsonEncode(v, toEncodable: (o) => o.toString());
    }

    return QueryResult(
      columns: keys,
      rows: [
        for (final d in docs) [for (final k in keys) cell(d[k])]
      ],
      rowRefs: [for (final d in docs) d['_id']],
    );
  }

  @override
  Future<QueryResult> fetchRows(String table,
      {int offset = 0, int limit = 100, QuerySpec? spec}) async {
    final docs = await db
        .collection(table)
        .modernFind(
          filter: filterOf(spec),
          sort: spec?.sortColumn == null
              ? null
              : {spec!.sortColumn!: spec.sortDescending ? -1 : 1},
          skip: offset > 0 ? offset : null,
          limit: limit,
        )
        .toList();
    return _docsToResult(docs);
  }

  @override
  Future<QueryResult> runRaw(String query) async {
    Map<String, Object> cmd;
    try {
      cmd = (jsonDecode(query) as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, v as Object));
    } catch (e) {
      throw DriverException('Command must be a JSON object. $e');
    }
    if (cmd.containsKey('aggregate') && !cmd.containsKey('cursor')) {
      cmd['cursor'] = <String, dynamic>{};
    }
    final res = await db.runCommand(cmd);
    if (res['cursor'] is Map && res['cursor']['firstBatch'] is List) {
      final batch = (res['cursor']['firstBatch'] as List)
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
      return _docsToResult(batch);
    }
    return QueryResult(
        message: const JsonEncoder.withIndent('  ')
            .convert(json.decode(json.encode(res, toEncodable: (o) => o.toString()))));
  }

  Map<String, dynamic> _editsToDoc(Map<String, CellEdit> values) {
    final doc = <String, dynamic>{};
    values.forEach((k, v) {
      if (k == '_id') return; // immutable
      doc[k] = v.toJsonish();
    });
    return doc;
  }

  @override
  Future<void> insertRow(String table, Map<String, CellEdit> values) async {
    await db.collection(table).insertOne(_editsToDoc(values));
  }

  @override
  Future<void> updateRow(
      String table, Object? rowRef, Map<String, CellEdit> values) async {
    if (rowRef == null) throw DriverException('Document has no _id');
    final doc = _editsToDoc(values);
    var mod = ModifierBuilder();
    doc.forEach((k, v) => mod = mod.set(k, v));
    await db.collection(table).updateOne(where.eq('_id', rowRef), mod);
  }

  @override
  Future<void> deleteRow(String table, Object? rowRef) async {
    if (rowRef == null) throw DriverException('Document has no _id');
    await db.collection(table).deleteOne(where.eq('_id', rowRef));
  }

  /// Dumps every collection as a JSON-lines file into a timestamped folder.
  @override
  Future<String> backup(String destDir) async {
    final dbName = profile.database.isEmpty ? 'test' : profile.database;
    final dir =
        Directory(p.join(destDir, '${dbName}_backup_${timestamp()}'));
    await dir.create(recursive: true);
    for (final coll in await listTables()) {
      final sink = File(p.join(dir.path, '$coll.jsonl')).openWrite();
      try {
        await for (final doc in db.collection(coll).modernFind()) {
          sink.writeln(jsonEncode(doc, toEncodable: (o) {
            if (o is ObjectId) return {r'$oid': o.oid};
            if (o is DateTime) return {r'$date': o.toIso8601String()};
            return o.toString();
          }));
        }
      } finally {
        await sink.close();
      }
    }
    return dir.path;
  }
}
