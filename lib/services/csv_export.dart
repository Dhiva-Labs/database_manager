import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

String _cell(Object? v) {
  if (v == null) return '';
  String s;
  if (v is Uint8List) {
    s = '0x${v.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  } else if (v is DateTime) {
    s = v.toIso8601String();
  } else if (v is Map || v is List) {
    s = jsonEncode(v);
  } else {
    s = v.toString();
  }
  if (s.contains(',') || s.contains('"') || s.contains('\n') || s.contains('\r')) {
    s = '"${s.replaceAll('"', '""')}"';
  }
  return s;
}

String buildCsv(List<String> columns, List<List<Object?>> rows) {
  final sb = StringBuffer();
  sb.writeln(columns.map(_cell).join(','));
  for (final row in rows) {
    sb.writeln(row.map(_cell).join(','));
  }
  return sb.toString();
}

/// Asks the user where to save and writes the CSV. Returns the path, or null
/// if cancelled.
Future<String?> exportCsv(
    String suggestedName, List<String> columns, List<List<Object?>> rows) async {
  final csv = buildCsv(columns, rows);
  final bytes = Uint8List.fromList(utf8.encode(csv));
  final path = await FilePicker.saveFile(
    dialogTitle: 'Export CSV',
    fileName: suggestedName,
    type: FileType.custom,
    allowedExtensions: ['csv'],
    bytes: bytes,
  );
  if (path == null) return null;
  final f = File(path);
  // On desktop, saveFile only returns the path; write the file ourselves.
  if (!await f.exists() || (await f.length()) == 0) {
    await f.writeAsBytes(bytes);
  }
  return path;
}
