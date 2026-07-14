import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:database_manager/drivers/lmdb_driver.dart';
import 'package:database_manager/drivers/sqlite_driver.dart';
import 'package:database_manager/models.dart';
import 'package:database_manager/services/csv_export.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('dbman_test_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('SqliteDriver', () {
    late String dbPath;
    late SqliteDriver driver;

    setUp(() async {
      dbPath = '${tmp.path}/test.db';
      final db = sqlite3.open(dbPath);
      db.execute('''
        CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER);
        INSERT INTO users (name, age) VALUES ('alice', 30), ('bob', NULL);
      ''');
      db.close();
      driver = SqliteDriver(ConnectionProfile(
          id: '1', name: 't', kind: DbKind.sqlite, filePath: dbPath));
      await driver.connect();
    });

    tearDown(() => driver.close());

    test('list, count, fetch', () async {
      expect(await driver.listTables(), ['users']);
      expect(await driver.countRows('users'), 2);
      final page = await driver.fetchRows('users');
      expect(page.columns, ['id', 'name', 'age']);
      expect(page.rows.length, 2);
      expect(page.rows[0], [1, 'alice', 30]);
      expect(page.rowRefs[0], isNotNull);
    });

    test('runRaw select and dml', () async {
      final sel = await driver.runRaw('SELECT name FROM users ORDER BY id');
      expect(sel.rows, [
        ['alice'],
        ['bob']
      ]);
      final upd =
          await driver.runRaw("UPDATE users SET age = 99 WHERE name = 'bob'");
      expect(upd.affectedRows, 1);
    });

    test('insert, update, delete row', () async {
      await driver.insertRow('users', {
        'name': const CellEdit('carol', false),
        'age': const CellEdit('22', false),
      });
      expect(await driver.countRows('users'), 3);

      final page = await driver.fetchRows('users');
      final carolIdx =
          page.rows.indexWhere((r) => r[page.columns.indexOf('name')] == 'carol');
      await driver.updateRow('users', page.rowRefs[carolIdx], {
        'name': const CellEdit('carol2', false),
        'age': const CellEdit('', true),
      });
      final after = await driver.runRaw(
          "SELECT age FROM users WHERE name = 'carol2'");
      expect(after.rows.single.single, isNull);

      await driver.deleteRow('users', page.rowRefs[carolIdx]);
      expect(await driver.countRows('users'), 2);
    });

    test('backup produces an openable copy', () async {
      final dest = await driver.backup(tmp.path);
      expect(File(dest).existsSync(), isTrue);
      final copy = sqlite3.open(dest);
      expect(copy.select('SELECT COUNT(*) c FROM users').first['c'], 2);
      copy.close();
    });

    test('describe reports pk', () async {
      final cols = await driver.describe('users');
      expect(cols.firstWhere((c) => c.name == 'id').isPrimaryKey, isTrue);
    });
  });

  group('LmdbDriver', () {
    late LmdbDriver driver;

    setUp(() async {
      final envDir = Directory('${tmp.path}/env')..createSync();
      driver = LmdbDriver(ConnectionProfile(
          id: '2', name: 'l', kind: DbKind.lmdb, filePath: envDir.path));
      await driver.connect();
    });

    tearDown(() => driver.close());

    test('put, list, fetch, scan, update, delete', () async {
      await driver.insertRow('(main)', {
        'key': const CellEdit('hello', false),
        'value': const CellEdit('world', false),
      });
      await driver.insertRow('(main)', {
        'key': const CellEdit('hey', false),
        'value': const CellEdit('there', false),
      });
      expect(await driver.countRows('(main)'), 2);

      final page = await driver.fetchRows('(main)');
      expect(page.rows.map((r) => r[0]), containsAll(['hello', 'hey']));

      // prefix scan
      final scan = await driver.runRaw('hel');
      expect(scan.rows.length, 1);
      expect(scan.rows[0], ['hello', 'world']);

      await driver.updateRow('(main)', page.rowRefs[0], {
        'key': CellEdit(page.rows[0][0] as String, false),
        'value': const CellEdit('updated', false),
      });
      final after = await driver.fetchRows('(main)');
      expect(after.rows.map((r) => r[1]), contains('updated'));

      await driver.deleteRow('(main)', page.rowRefs[0]);
      expect(await driver.countRows('(main)'), 1);
    });

    test('backup creates a copy env', () async {
      await driver.insertRow('(main)', {
        'key': const CellEdit('k', false),
        'value': const CellEdit('v', false),
      });
      final destRoot = Directory('${tmp.path}/bk')..createSync();
      final dest = await driver.backup(destRoot.path);
      expect(File('$dest/data.mdb').existsSync(), isTrue);
    });
  });

  group('CSV', () {
    test('escapes commas, quotes, newlines and nulls', () {
      final csv = buildCsv([
        'a',
        'b'
      ], [
        ['x,y', 'he said "hi"'],
        [null, 'line1\nline2'],
        [42, true],
      ]);
      expect(csv.split('\n')[0], 'a,b');
      expect(csv, contains('"x,y"'));
      expect(csv, contains('"he said ""hi"""'));
      expect(csv, contains('"line1\nline2"'));
      expect(csv, contains('42,true'));
    });
  });
}
