import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:database_manager/drivers/db_driver.dart';
import 'package:database_manager/drivers/mongo_driver.dart';
import 'package:database_manager/drivers/sqlite_driver.dart';
import 'package:database_manager/models.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('dbman_feat_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  ConnectionProfile sqliteProfile(String path, {String password = ''}) =>
      ConnectionProfile(
          id: 'x',
          name: 't',
          kind: DbKind.sqlite,
          filePath: path,
          password: password);

  group('encrypted SQLite (SQLCipher)', () {
    test('bundled library is SQLCipher', () {
      final db = sqlite3.openInMemory();
      final v = db.select('PRAGMA cipher_version');
      db.close();
      expect(v, isNotEmpty, reason: 'cipher_version empty: not SQLCipher');
    });

    test('open with correct / wrong / missing password', () async {
      final path = '${tmp.path}/secret.db';
      final db = sqlite3.open(path);
      db.execute("PRAGMA key = 'hunter2'");
      db.execute(
          "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT);"
          "INSERT INTO notes (body) VALUES ('top secret');");
      db.close();

      // Correct password works.
      final ok = SqliteDriver(sqliteProfile(path, password: 'hunter2'));
      await ok.connect();
      expect(await ok.countRows('notes'), 1);
      await ok.close();

      // No password -> PasswordRequiredException.
      final noPw = SqliteDriver(sqliteProfile(path));
      await expectLater(
          noPw.connect(), throwsA(isA<PasswordRequiredException>()));

      // Wrong password -> PasswordRequiredException.
      final wrong = SqliteDriver(sqliteProfile(path, password: 'nope'));
      await expectLater(
          wrong.connect(), throwsA(isA<PasswordRequiredException>()));
    });

    test('plain database still opens without a password', () async {
      final path = '${tmp.path}/plain.db';
      final db = sqlite3.open(path);
      db.execute('CREATE TABLE t (a); INSERT INTO t VALUES (1);');
      db.close();
      final driver = SqliteDriver(sqliteProfile(path));
      await driver.connect();
      expect(await driver.countRows('t'), 1);
      await driver.close();
    });

    test('encrypt -> rekey -> decrypt lifecycle via setPassword', () async {
      final path = '${tmp.path}/lifecycle.db';
      final db = sqlite3.open(path);
      db.execute("CREATE TABLE t (v TEXT); INSERT INTO t VALUES ('keep me');");
      db.close();

      final profile = sqliteProfile(path);
      final driver = SqliteDriver(profile);
      await driver.connect();
      expect(driver.supportsEncryptionManagement, isTrue);

      // Encrypt a plaintext database.
      await driver.setPassword('one');
      expect(profile.password, 'one');
      expect(await driver.countRows('t'), 1); // still reads after reconnect

      // The file on disk is now unreadable without the key.
      expect(SqliteDriver.hasSqliteHeaderForTest(path), isFalse);
      await expectLater(SqliteDriver(sqliteProfile(path)).connect(),
          throwsA(isA<PasswordRequiredException>()));

      // Rekey in place.
      await driver.setPassword('two');
      expect(profile.password, 'two');
      await expectLater(
          SqliteDriver(sqliteProfile(path, password: 'one')).connect(),
          throwsA(isA<PasswordRequiredException>()));
      final ok = SqliteDriver(sqliteProfile(path, password: 'two'));
      await ok.connect();
      expect((await ok.runRaw('SELECT v FROM t')).rows.single.single, 'keep me');
      await ok.close();

      // Decrypt back to plaintext.
      await driver.setPassword('');
      expect(profile.password, '');
      expect(SqliteDriver.hasSqliteHeaderForTest(path), isTrue);
      final plain = SqliteDriver(sqliteProfile(path));
      await plain.connect();
      expect(await plain.countRows('t'), 1);
      await plain.close();

      await driver.close();
    });

    test('encrypted backup stays encrypted (no leak)', () async {
      final path = '${tmp.path}/enc_bk.db';
      final db = sqlite3.open(path);
      db.execute("PRAGMA key = 'pw'");
      db.execute("CREATE TABLE t (v TEXT); INSERT INTO t VALUES ('secret');");
      db.close();

      final driver = SqliteDriver(sqliteProfile(path, password: 'pw'));
      await driver.connect();
      final backupPath = await driver.backup(tmp.path);
      await driver.close();

      // Backup must NOT be openable without the key...
      expect(SqliteDriver.hasSqliteHeaderForTest(backupPath), isFalse);
      // ...but must open with the original key.
      final restored = SqliteDriver(ConnectionProfile(
          id: 'r',
          name: 'r',
          kind: DbKind.sqlite,
          filePath: backupPath,
          password: 'pw'));
      await restored.connect();
      expect((await restored.runRaw('SELECT v FROM t')).rows.single.single,
          'secret');
      await restored.close();
    });
  });

  group('QuerySpec filters', () {
    late SqliteDriver driver;

    setUp(() async {
      final path = '${tmp.path}/people.db';
      final db = sqlite3.open(path);
      db.execute('''
        CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT, age INTEGER);
        INSERT INTO people (name, age) VALUES
          ('alice', 30), ('bob', 45), ('carol', 25), ('dave', NULL);
      ''');
      db.close();
      driver = SqliteDriver(sqliteProfile(path));
      await driver.connect();
    });

    tearDown(() => driver.close());

    test('contains + sort', () async {
      final spec = QuerySpec(
        filters: [
          FilterCondition(
              column: 'name', op: FilterOp.contains, value: 'a')
        ],
        sortColumn: 'age',
        sortDescending: true,
      );
      final page = await driver.fetchRows('people', spec: spec);
      // alice, carol, dave contain 'a'; sorted by age desc (NULL sorts last
      // in DESC for sqlite? NULLs sort first in ASC, last in DESC).
      expect(page.rows.length, 3);
      expect(await driver.countRows('people', spec: spec), 3);
      final names = [for (final r in page.rows) r[1]];
      expect(names, containsAll(['alice', 'carol', 'dave']));
    });

    test('numeric comparison', () async {
      final spec = QuerySpec(filters: [
        FilterCondition(
            column: 'age', op: FilterOp.greaterOrEqual, value: '30')
      ]);
      final page = await driver.fetchRows('people', spec: spec);
      expect([for (final r in page.rows) r[1]],
          unorderedEquals(['alice', 'bob']));
    });

    test('is empty matches NULL', () async {
      final spec = QuerySpec(filters: [
        FilterCondition(column: 'age', op: FilterOp.isNull)
      ]);
      final page = await driver.fetchRows('people', spec: spec);
      expect([for (final r in page.rows) r[1]], ['dave']);
    });

    test('filtered rows are still editable (rowRefs present)', () async {
      final spec = QuerySpec(filters: [
        FilterCondition(column: 'name', op: FilterOp.equals, value: 'bob')
      ]);
      final page = await driver.fetchRows('people', spec: spec);
      expect(page.rowRefs.single, isNotNull);
      await driver.updateRow('people', page.rowRefs.single, {
        'name': const CellEdit('bob', false),
        'age': const CellEdit('46', false),
      });
      final after = await driver
          .runRaw("SELECT age FROM people WHERE name = 'bob'");
      expect(after.rows.single.single, 46);
    });

    test('describeQuery shows runnable SQL', () {
      final spec = QuerySpec(
        filters: [
          FilterCondition(column: 'name', op: FilterOp.contains, value: 'a')
        ],
        sortColumn: 'age',
      );
      final sql = driver.describeQuery('people', spec);
      expect(sql, contains('SELECT * FROM "people"'));
      expect(sql, contains('WHERE "name" LIKE \'%a%\''));
      expect(sql, contains('ORDER BY "age"'));
    });

    test('quotes are escaped in filter values', () async {
      final spec = QuerySpec(filters: [
        FilterCondition(
            column: 'name', op: FilterOp.equals, value: "o'brien")
      ]);
      // Must not throw a syntax error.
      final page = await driver.fetchRows('people', spec: spec);
      expect(page.rows, isEmpty);
    });
  });

  group('Mongo filter building', () {
    test('spec converts to a Mongo filter document', () {
      final f = MongoDriver.filterOf(QuerySpec(filters: [
        FilterCondition(column: 'age', op: FilterOp.greaterThan, value: '21'),
        FilterCondition(
            column: 'name', op: FilterOp.contains, value: 'jo.hn'),
        FilterCondition(column: 'email', op: FilterOp.isNull),
      ]));
      expect(f['age'], {r'$gt': 21});
      expect((f['name'] as Map)[r'$regex'], r'jo\.hn');
      expect(f['email'], isNull);
      expect(f.containsKey('email'), isTrue);
    });
  });
}
