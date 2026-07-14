import '../models.dart';
import 'db_driver.dart';
import 'lmdb_driver.dart';
import 'mongo_driver.dart';
import 'mysql_driver.dart';
import 'postgres_driver.dart';
import 'sqlite_driver.dart';

DbDriver createDriver(ConnectionProfile profile) => switch (profile.kind) {
      DbKind.sqlite => SqliteDriver(profile),
      DbKind.mysql => MysqlDriver(profile),
      DbKind.postgres => PostgresDriver(profile),
      DbKind.mongodb => MongoDriver(profile),
      DbKind.lmdb => LmdbDriver(profile),
    };
