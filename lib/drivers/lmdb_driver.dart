import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import '../models.dart';
import 'db_driver.dart';
import 'lmdb_bindings.dart';

const String _mainDb = '(main)';

/// Key-value browser for LMDB environments. Keys and values are shown as
/// UTF-8 text when they decode cleanly, otherwise as 0x… hex (hex is also
/// accepted as input).
class LmdbDriver extends DbDriver {
  LmdbDriver(super.profile);

  late Lmdb _lmdb;
  Pointer<Void> _env = nullptr;
  bool _readOnly = false;

  @override
  bool get supportsSql => false;

  @override
  String get tableNoun => 'sub-database';

  @override
  String get queryHint =>
      'Key prefix scan: type a prefix (or leave empty for all keys),\n'
      'optionally "dbname: prefix" to scan a named sub-database.';

  @override
  Future<void> connect() async {
    _lmdb = Lmdb.open();

    // Users may pick the env directory, its data.mdb, or a standalone
    // NOSUBDIR file.
    var path = profile.filePath;
    var flags = 0;
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.notFound) {
      throw DriverException('Path not found: $path');
    }
    if (type == FileSystemEntityType.file) {
      if (p.basename(path) == 'data.mdb') {
        path = p.dirname(path);
      } else {
        flags |= mdbNosubdir;
      }
    }

    int rc;
    final envPtr = malloc<Pointer<Void>>();
    try {
      rc = _lmdb.envCreate(envPtr);
      _check(rc, 'mdb_env_create');
      _env = envPtr.value;
    } finally {
      malloc.free(envPtr);
    }
    _lmdb.envSetMaxdbs(_env, 256);
    // Reserving generous address space is free on 64-bit and lets writes grow.
    _lmdb.envSetMapsize(_env, 4 * 1024 * 1024 * 1024);

    final cPath = path.toNativeUtf8();
    try {
      rc = _lmdb.envOpen(_env, cPath, flags, 436 /* 0664 */);
      if (rc != 0) {
        // Retry read-only (e.g. no write permission / locked env).
        rc = _lmdb.envOpen(_env, cPath, flags | mdbRdonly, 436);
        _readOnly = true;
      }
      if (rc != 0) {
        _lmdb.envClose(_env);
        _env = nullptr;
        throw DriverException('mdb_env_open: ${_lmdb.errText(rc)}');
      }
    } finally {
      malloc.free(cPath);
    }
    // Validate it really is an LMDB env.
    _withTxn(readOnly: true, (txn) => _openDbi(txn, _mainDb));
  }

  @override
  Future<void> close() async {
    if (_env != nullptr) {
      _lmdb.envClose(_env);
      _env = nullptr;
    }
  }

  void _check(int rc, String op) {
    if (rc != 0) throw DriverException('$op: ${_lmdb.errText(rc)}');
  }

  T _withTxn<T>(T Function(Pointer<Void> txn) body, {bool readOnly = false}) {
    if (readOnly == false && _readOnly) {
      throw DriverException('Environment was opened read-only');
    }
    final txnPtr = malloc<Pointer<Void>>();
    Pointer<Void> txn;
    try {
      _check(
          _lmdb.txnBegin(_env, nullptr, readOnly ? mdbRdonly : 0, txnPtr),
          'mdb_txn_begin');
      txn = txnPtr.value;
    } finally {
      malloc.free(txnPtr);
    }
    try {
      final result = body(txn);
      _check(_lmdb.txnCommit(txn), 'mdb_txn_commit');
      return result;
    } catch (_) {
      _lmdb.txnAbort(txn);
      rethrow;
    }
  }

  int _openDbi(Pointer<Void> txn, String name, {bool create = false}) {
    final dbiPtr = malloc<Uint32>();
    final cName = name == _mainDb ? nullptr : name.toNativeUtf8();
    try {
      final rc =
          _lmdb.dbiOpen(txn, cName.cast(), create ? mdbCreate : 0, dbiPtr);
      _check(rc, 'mdb_dbi_open($name)');
      return dbiPtr.value;
    } finally {
      malloc.free(dbiPtr);
      if (cName != nullptr) malloc.free(cName);
    }
  }

  // ---- text <-> bytes ----
  static String _display(Uint8List b) {
    try {
      final s = utf8.decode(b);
      if (s.runes.every((r) => r >= 0x20 || r == 0x09 || r == 0x0a || r == 0x0d)) {
        return s;
      }
    } catch (_) {}
    return '0x${b.map((x) => x.toRadixString(16).padLeft(2, '0')).join()}';
  }

  static Uint8List _parse(String s) {
    if (s.startsWith('0x') && s.length > 2 && s.length.isOdd == false) {
      final hex = s.substring(2);
      if (RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) {
        final out = Uint8List(hex.length ~/ 2);
        for (var i = 0; i < out.length; i++) {
          out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
        }
        return out;
      }
    }
    return Uint8List.fromList(utf8.encode(s));
  }

  @override
  Future<List<String>> listTables() async {
    return _withTxn(readOnly: true, (txn) {
      final names = <String>[_mainDb];
      final dbi = _openDbi(txn, _mainDb);
      _scan(txn, dbi, (key, value) {
        // Entries in the main DB that are themselves sub-databases.
        final name = () {
          try {
            return utf8.decode(key);
          } catch (_) {
            return null;
          }
        }();
        if (name != null) {
          try {
            _openDbi(txn, name);
            names.add(name);
          } catch (_) {/* plain key, not a sub-db */}
        }
        return true;
      });
      return names;
    });
  }

  /// Iterates dbi entries; [visit] returns false to stop.
  void _scan(Pointer<Void> txn, int dbi,
      bool Function(Uint8List key, Uint8List value) visit,
      {Uint8List? startKey}) {
    final curPtr = malloc<Pointer<Void>>();
    _check(_lmdb.cursorOpen(txn, dbi, curPtr), 'mdb_cursor_open');
    final cursor = curPtr.value;
    malloc.free(curPtr);
    final key = malloc<MDBVal>();
    final val = malloc<MDBVal>();
    Pointer<Uint8> seekData = nullptr;
    try {
      int op;
      if (startKey != null && startKey.isNotEmpty) {
        seekData = malloc<Uint8>(startKey.length);
        seekData.asTypedList(startKey.length).setAll(0, startKey);
        key.ref.mvSize = startKey.length;
        key.ref.mvData = seekData.cast();
        op = mdbSetRange;
      } else {
        op = mdbFirst;
      }
      var rc = _lmdb.cursorGet(cursor, key, val, op);
      while (rc == 0) {
        if (!visit(mdbValBytes(key), mdbValBytes(val))) break;
        rc = _lmdb.cursorGet(cursor, key, val, mdbNextOp);
      }
      if (rc != 0 && rc != mdbNotfound) _check(rc, 'mdb_cursor_get');
    } finally {
      _lmdb.cursorClose(cursor);
      malloc.free(key);
      malloc.free(val);
      if (seekData != nullptr) malloc.free(seekData);
    }
  }

  @override
  Future<List<ColumnInfo>> describe(String table) async => [
        ColumnInfo('key', type: 'bytes', isPrimaryKey: true, nullable: false),
        ColumnInfo('value', type: 'bytes', nullable: false),
      ];

  /// LMDB filtering happens client-side on the displayed key/value text.
  static bool _matches(QuerySpec? spec, String key, String value) {
    if (spec == null) return true;
    for (final f in spec.filters.where((f) => f.column.isNotEmpty)) {
      final s = f.column == 'value' ? value : key;
      final ok = switch (f.op) {
        FilterOp.equals => s == f.value,
        FilterOp.notEquals => s != f.value,
        FilterOp.contains => s.toLowerCase().contains(f.value.toLowerCase()),
        FilterOp.startsWith => s.startsWith(f.value),
        FilterOp.greaterThan => s.compareTo(f.value) > 0,
        FilterOp.lessThan => s.compareTo(f.value) < 0,
        FilterOp.greaterOrEqual => s.compareTo(f.value) >= 0,
        FilterOp.lessOrEqual => s.compareTo(f.value) <= 0,
        FilterOp.isNull => s.isEmpty,
        FilterOp.isNotNull => s.isNotEmpty,
      };
      if (!ok) return false;
    }
    return true;
  }

  @override
  String describeQuery(String table, QuerySpec? spec, {int limit = 100}) {
    final prefix = spec?.filters
        .where((f) => f.column == 'key' && f.op == FilterOp.startsWith)
        .map((f) => f.value)
        .firstOrNull;
    return '${table == _mainDb ? '' : '$table: '}${prefix ?? ''}'
        '${spec == null || spec.filters.isEmpty ? '' : '   (filtered scan)'}';
  }

  @override
  Future<int> countRows(String table, {QuerySpec? spec}) async {
    return _withTxn(readOnly: true, (txn) {
      final dbi = _openDbi(txn, table);
      var n = 0;
      _scan(txn, dbi, (k, v) {
        if (_matches(spec, _display(k), _display(v))) n++;
        return true;
      });
      return n;
    });
  }

  @override
  Future<QueryResult> fetchRows(String table,
      {int offset = 0, int limit = 100, QuerySpec? spec}) async {
    return _withTxn(readOnly: true, (txn) {
      final dbi = _openDbi(txn, table);
      final rows = <List<Object?>>[];
      final refs = <Object?>[];
      var i = 0;
      _scan(txn, dbi, (k, v) {
        final key = _display(k);
        final value = _display(v);
        if (!_matches(spec, key, value)) return true;
        if (i >= offset) {
          rows.add([key, value]);
          refs.add(k);
        }
        i++;
        return rows.length < limit;
      });
      return QueryResult(columns: ['key', 'value'], rows: rows, rowRefs: refs);
    });
  }

  @override
  Future<QueryResult> runRaw(String query) async {
    // "[dbname:] prefix" -> prefix scan
    var dbName = _mainDb;
    var prefix = query.trim();
    final colon = prefix.indexOf(':');
    if (colon > 0) {
      final candidate = prefix.substring(0, colon).trim();
      final tables = await listTables();
      if (tables.contains(candidate)) {
        dbName = candidate;
        prefix = prefix.substring(colon + 1).trim();
      }
    }
    final prefixBytes = _parse(prefix);
    return _withTxn(readOnly: true, (txn) {
      final dbi = _openDbi(txn, dbName);
      final rows = <List<Object?>>[];
      _scan(txn, dbi, startKey: prefixBytes.isEmpty ? null : prefixBytes,
          (k, v) {
        if (prefixBytes.isNotEmpty) {
          if (k.length < prefixBytes.length) return false;
          for (var i = 0; i < prefixBytes.length; i++) {
            if (k[i] != prefixBytes[i]) return false;
          }
        }
        rows.add([_display(k), _display(v)]);
        return rows.length < 1000;
      });
      return QueryResult(
          columns: ['key', 'value'],
          rows: rows,
          message: '${rows.length} entr${rows.length == 1 ? 'y' : 'ies'} in $dbName');
    });
  }

  void _putBytes(String table, Uint8List key, Uint8List value) {
    _withTxn((txn) {
      final dbi = _openDbi(txn, table, create: table != _mainDb);
      final k = mdbValFrom(key);
      final v = mdbValFrom(value);
      try {
        _check(_lmdb.put(txn, dbi, k, v, 0), 'mdb_put');
      } finally {
        malloc.free(k.ref.mvData);
        malloc.free(k);
        malloc.free(v.ref.mvData);
        malloc.free(v);
      }
    });
  }

  @override
  Future<void> insertRow(String table, Map<String, CellEdit> values) async {
    final key = values['key'];
    final value = values['value'];
    if (key == null || key.isNull) throw DriverException('Key is required');
    _putBytes(table, _parse(key.text), _parse(value?.isNull ?? true ? '' : value!.text));
  }

  @override
  Future<void> updateRow(
      String table, Object? rowRef, Map<String, CellEdit> values) async {
    if (rowRef == null) throw DriverException('Missing key reference');
    final origKey = rowRef as Uint8List;
    final newKey = values['key'];
    final value = values['value'];
    final newKeyBytes =
        newKey == null || newKey.isNull ? origKey : _parse(newKey.text);
    final valueBytes = _parse(value == null || value.isNull ? '' : value.text);
    _withTxn((txn) {
      final dbi = _openDbi(txn, table);
      if (!_bytesEqual(origKey, newKeyBytes)) {
        final ok = mdbValFrom(origKey);
        try {
          _lmdb.del(txn, dbi, ok, nullptr); // ignore not-found
        } finally {
          malloc.free(ok.ref.mvData);
          malloc.free(ok);
        }
      }
      final k = mdbValFrom(newKeyBytes);
      final v = mdbValFrom(valueBytes);
      try {
        _check(_lmdb.put(txn, dbi, k, v, 0), 'mdb_put');
      } finally {
        malloc.free(k.ref.mvData);
        malloc.free(k);
        malloc.free(v.ref.mvData);
        malloc.free(v);
      }
    });
  }

  @override
  Future<void> deleteRow(String table, Object? rowRef) async {
    if (rowRef == null) throw DriverException('Missing key reference');
    _withTxn((txn) {
      final dbi = _openDbi(txn, table);
      final k = mdbValFrom(rowRef as Uint8List);
      try {
        _check(_lmdb.del(txn, dbi, k, nullptr), 'mdb_del');
      } finally {
        malloc.free(k.ref.mvData);
        malloc.free(k);
      }
    });
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Uses mdb_env_copy2 (compacting) — a consistent hot backup.
  @override
  Future<String> backup(String destDir) async {
    final base = p.basenameWithoutExtension(profile.filePath);
    final dir = Directory(p.join(destDir, '${base}_backup_${timestamp()}'));
    await dir.create(recursive: true);
    final cPath = dir.path.toNativeUtf8();
    try {
      _check(_lmdb.envCopy2(_env, cPath, mdbCpCompact), 'mdb_env_copy2');
    } finally {
      malloc.free(cPath);
    }
    return dir.path;
  }
}
