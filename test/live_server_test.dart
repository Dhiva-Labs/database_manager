// Integration tests against real servers. Each group is skipped when its
// server isn't running, so `flutter test` stays green on machines without
// them. Expected local setup (see README "Testing against live servers"):
//   PostgreSQL on 127.0.0.1:55432  (dbadmin / testpass123, db shopdb)
//   MySQL/MariaDB on 127.0.0.1:53306 (testuser / testpass123, db shopdb)
//   MongoDB on 127.0.0.1:57017 (no auth)
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:database_manager/drivers/db_driver.dart';
import 'package:database_manager/drivers/mongo_driver.dart';
import 'package:database_manager/drivers/mysql_driver.dart';
import 'package:database_manager/drivers/postgres_driver.dart';
import 'package:database_manager/models.dart';

Future<bool> reachable(int port) async {
  try {
    final s = await Socket.connect('127.0.0.1', port,
        timeout: const Duration(seconds: 2));
    s.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// Shared CRUD exercise for the SQL drivers: assumes a `products` table
/// seeded with 5 rows, one of them named "O'Reilly Book".
Future<void> exerciseSqlDriver(DbDriver driver) async {
  final tables = await driver.listTables();
  expect(tables, contains('products'));

  final cols = await driver.describe('products');
  expect(cols.firstWhere((c) => c.name == 'id').isPrimaryKey, isTrue);

  expect(await driver.countRows('products'), 5);

  // Paged fetch with editable refs.
  final page = await driver.fetchRows('products', limit: 3);
  expect(page.rows.length, 3);
  expect(page.columns, contains('name'));
  expect(page.rowRefs.every((r) => r != null), isTrue);

  // Filters: numeric compare + contains with a quote in the data.
  final cheap = await driver.fetchRows('products',
      spec: QuerySpec(filters: [
        FilterCondition(
            column: 'price', op: FilterOp.lessThan, value: '50')
      ]));
  expect(cheap.rows.length, 3, reason: 'Mouse, Keyboard, O\'Reilly < 50');

  final quoted = await driver.fetchRows('products',
      spec: QuerySpec(filters: [
        FilterCondition(
            column: 'name', op: FilterOp.contains, value: "O'Reilly")
      ]));
  expect(quoted.rows.length, 1);

  // Sorted fetch.
  final sorted = await driver.fetchRows('products',
      spec: const QuerySpec(sortColumn: 'price', sortDescending: true));
  final nameIdx = sorted.columns.indexOf('name');
  expect(sorted.rows.first[nameIdx].toString(), 'Laptop');

  // Raw SQL, both directions.
  final sel = await driver
      .runRaw("SELECT name FROM products WHERE stock = 0");
  expect(sel.rows.single.single.toString(), 'Monitor');
  final upd = await driver
      .runRaw("UPDATE products SET stock = 1 WHERE name = 'Monitor'");
  expect(upd.affectedRows, 1);
  await driver.runRaw("UPDATE products SET stock = 0 WHERE name = 'Monitor'");

  // Insert -> update -> delete round trip through the grid API.
  await driver.insertRow('products', {
    'name': const CellEdit('Webcam', false),
    'price': const CellEdit('59.99', false),
    'stock': const CellEdit('7', false),
    'active': const CellEdit('true', false),
  });
  expect(await driver.countRows('products'), 6);

  final spec = QuerySpec(filters: [
    FilterCondition(column: 'name', op: FilterOp.equals, value: 'Webcam')
  ]);
  var found = await driver.fetchRows('products', spec: spec);
  expect(found.rows.length, 1);
  final stockIdx = found.columns.indexOf('stock');

  await driver.updateRow('products', found.rowRefs.single, {
    'stock': const CellEdit('99', false),
  });
  found = await driver.fetchRows('products', spec: spec);
  expect(found.rows.single[stockIdx].toString(), '99');

  await driver.deleteRow('products', found.rowRefs.single);
  expect(await driver.countRows('products'), 5);
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('dbman_live_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('PostgreSQL (live)', () {
    late PostgresDriver driver;

    setUp(() async {
      if (!await reachable(55432)) {
        markTestSkipped('PostgreSQL not running on 55432');
        return;
      }
      driver = PostgresDriver(ConnectionProfile(
        id: 'pg',
        name: 'pg',
        kind: DbKind.postgres,
        host: '127.0.0.1',
        port: 55432,
        user: 'dbadmin',
        password: 'testpass123',
        database: 'shopdb',
      ));
      await driver.connect();
    });

    tearDown(() async {
      if (await reachable(55432)) await driver.close();
    });

    test('full CRUD + filters + raw SQL', () async {
      if (!await reachable(55432)) return;
      await exerciseSqlDriver(driver);
    });

    test('table without a primary key is editable via ctid', () async {
      if (!await reachable(55432)) return;
      final page = await driver.fetchRows('no_pk_table');
      expect(page.rowRefs.every((r) => r != null), isTrue);
      await driver.updateRow('no_pk_table', page.rowRefs.first,
          {'note': const CellEdit('first-edited', false)});
      final after = await driver.fetchRows('no_pk_table',
          spec: QuerySpec(filters: [
            FilterCondition(
                column: 'note', op: FilterOp.equals, value: 'first-edited')
          ]));
      expect(after.rows.length, 1);
      await driver.updateRow('no_pk_table', after.rowRefs.first,
          {'note': const CellEdit('first', false)});
    });

    test('backup writes a SQL dump', () async {
      if (!await reachable(55432)) return;
      final path = await driver.backup(tmp.path);
      final dump = await File(path).readAsString();
      expect(dump, contains('CREATE TABLE IF NOT EXISTS "products"'));
      expect(dump, contains("'Laptop'"));
      expect(dump, contains('PRIMARY KEY'));
    });

    test('wrong password fails with an auth-looking error', () async {
      if (!await reachable(55432)) return;
      final bad = PostgresDriver(ConnectionProfile(
        id: 'bad',
        name: 'bad',
        kind: DbKind.postgres,
        host: '127.0.0.1',
        port: 55432,
        user: 'dbadmin',
        password: 'wrong',
        database: 'shopdb',
      ));
      Object? error;
      try {
        await bad.connect();
      } catch (e) {
        error = e;
      }
      expect(error, isNotNull);
      expect(error.toString().toLowerCase(), contains('password'));
    });
  });

  group('MySQL/MariaDB (live)', () {
    late MysqlDriver driver;

    setUp(() async {
      if (!await reachable(53306)) {
        markTestSkipped('MySQL/MariaDB not running on 53306');
        return;
      }
      driver = MysqlDriver(ConnectionProfile(
        id: 'my',
        name: 'my',
        kind: DbKind.mysql,
        host: '127.0.0.1',
        port: 53306,
        user: 'testuser',
        password: 'testpass123',
        database: 'shopdb',
      ));
      await driver.connect();
    });

    tearDown(() async {
      if (await reachable(53306)) await driver.close();
    });

    test('full CRUD + filters + raw SQL', () async {
      if (!await reachable(53306)) return;
      await exerciseSqlDriver(driver);
    });

    test('backup writes a SQL dump', () async {
      if (!await reachable(53306)) return;
      final path = await driver.backup(tmp.path);
      final dump = await File(path).readAsString();
      expect(dump, contains('CREATE TABLE'));
      expect(dump, contains("'Laptop'"));
    });
  });

  group('MongoDB (live)', () {
    late MongoDriver driver;

    setUp(() async {
      if (!await reachable(57017)) {
        markTestSkipped('MongoDB not running on 57017');
        return;
      }
      driver = MongoDriver(ConnectionProfile(
        id: 'mg',
        name: 'mg',
        kind: DbKind.mongodb,
        host: '127.0.0.1',
        port: 57017,
        database: 'shopdb',
      ));
      await driver.connect();
      // Start from a clean collection each run.
      try {
        await driver.runRaw('{"drop": "customers"}');
      } catch (_) {/* didn't exist yet */}
    });

    tearDown(() async {
      if (await reachable(57017)) await driver.close();
    });

    test('insert, list, filter, edit, delete, command, backup', () async {
      if (!await reachable(57017)) return;

      // insertRow creates the collection implicitly.
      await driver.insertRow('customers', {
        'name': const CellEdit('Asha', false),
        'age': const CellEdit('63', false),
        'tags': const CellEdit('["vip","chennai"]', false),
      });
      await driver.insertRow('customers', {
        'name': const CellEdit('Vikram', false),
        'age': const CellEdit('35', false),
      });

      expect(await driver.listTables(), contains('customers'));
      expect(await driver.countRows('customers'), 2);

      // Nested JSON round-trips.
      final page = await driver.fetchRows('customers');
      expect(page.columns, contains('_id'));
      expect(page.rowRefs.every((r) => r != null), isTrue);

      // Filter builder -> Mongo filter.
      final seniors = await driver.fetchRows('customers',
          spec: QuerySpec(filters: [
            FilterCondition(
                column: 'age', op: FilterOp.greaterThan, value: '50')
          ]));
      expect(seniors.rows.length, 1);
      final nameIdx = seniors.columns.indexOf('name');
      expect(seniors.rows.single[nameIdx], 'Asha');

      // Raw command tab.
      final res = await driver.runRaw(
          '{"find": "customers", "filter": {"name": "Vikram"}}');
      expect(res.rows.length, 1);

      // Edit + delete via grid refs.
      await driver.updateRow('customers', seniors.rowRefs.single, {
        'age': const CellEdit('64', false),
      });
      final after = await driver.fetchRows('customers',
          spec: QuerySpec(filters: [
            FilterCondition(
                column: 'name', op: FilterOp.equals, value: 'Asha')
          ]));
      final ageIdx = after.columns.indexOf('age');
      expect(after.rows.single[ageIdx], 64);

      await driver.deleteRow('customers', after.rowRefs.single);
      expect(await driver.countRows('customers'), 1);

      // Backup: JSONL per collection.
      final dir = await driver.backup(tmp.path);
      final files = Directory(dir).listSync().map((f) => f.path).toList();
      expect(files.any((f) => f.endsWith('customers.jsonl')), isTrue);
      final jsonl = await File(
              files.firstWhere((f) => f.endsWith('customers.jsonl')))
          .readAsString();
      expect(jsonl, contains('Vikram'));
    });
  });
}
