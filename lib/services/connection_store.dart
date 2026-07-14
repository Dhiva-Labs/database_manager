import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models.dart';

/// Persists connection profiles as JSON in the app-support directory.
/// Note: passwords are stored in plain text in this file.
class ConnectionStore {
  List<ConnectionProfile> profiles = [];

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, 'connections.json'));
  }

  Future<void> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final list = jsonDecode(await f.readAsString()) as List;
      profiles = [
        for (final e in list) ConnectionProfile.fromJson(e as Map<String, dynamic>)
      ];
    } catch (_) {
      profiles = [];
    }
  }

  Future<void> save() async {
    final f = await _file();
    await f.writeAsString(
        const JsonEncoder.withIndent('  ').convert([for (final p in profiles) p.toJson()]));
  }
}
