import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models.dart';

/// Dialog to create or edit a connection profile. Returns the profile or
/// null on cancel.
Future<ConnectionProfile?> showConnectionEditor(BuildContext context,
    {ConnectionProfile? existing}) {
  return showDialog<ConnectionProfile>(
    context: context,
    builder: (_) => _ConnectionEditorDialog(existing: existing),
  );
}

class _ConnectionEditorDialog extends StatefulWidget {
  final ConnectionProfile? existing;
  const _ConnectionEditorDialog({this.existing});

  @override
  State<_ConnectionEditorDialog> createState() =>
      _ConnectionEditorDialogState();
}

class _ConnectionEditorDialogState extends State<_ConnectionEditorDialog> {
  late DbKind _kind;
  late final TextEditingController _name;
  late final TextEditingController _file;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _user;
  late final TextEditingController _password;
  late final TextEditingController _database;
  late bool _ssl;
  late bool _askPassword;
  bool _portTouched = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _kind = e?.kind ?? DbKind.sqlite;
    _name = TextEditingController(text: e?.name ?? '');
    _file = TextEditingController(text: e?.filePath ?? '');
    _host = TextEditingController(text: e?.host ?? 'localhost');
    _port = TextEditingController(
        text: (e?.port ?? _kind.defaultPort).toString());
    _user = TextEditingController(text: e?.user ?? '');
    _password = TextEditingController(text: e?.password ?? '');
    _database = TextEditingController(text: e?.database ?? '');
    _ssl = e?.useSsl ?? false;
    _askPassword = e?.askPassword ?? false;
    _portTouched = e != null;
  }

  @override
  void dispose() {
    for (final c in [_name, _file, _host, _port, _user, _password, _database]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _browse() async {
    if (_kind == DbKind.lmdb) {
      final dir = await FilePicker
          .getDirectoryPath(dialogTitle: 'Select LMDB environment directory');
      if (dir != null) setState(() => _file.text = dir);
    } else {
      final res = await FilePicker
          .pickFiles(dialogTitle: 'Select SQLite database file');
      final path = res?.files.single.path;
      if (path != null) setState(() => _file.text = path);
    }
  }

  InputDecoration _dec(String label) => InputDecoration(
      labelText: label, border: const OutlineInputBorder(), isDense: true);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'New connection' : 'Edit connection'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final k in DbKind.values)
                    ChoiceChip(
                      label: Text(k.label),
                      selected: _kind == k,
                      onSelected: (sel) {
                        if (!sel) return;
                        setState(() {
                          _kind = k;
                          if (!_portTouched) {
                            _port.text = k.defaultPort.toString();
                          }
                        });
                      },
                    ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(controller: _name, decoration: _dec('Connection name')),
              const SizedBox(height: 12),
              if (_kind.isFileBased) ...[
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _file,
                      decoration: _dec(_kind == DbKind.lmdb
                          ? 'LMDB directory (or data.mdb)'
                          : 'SQLite file'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _browse,
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: const Text('Browse'),
                  ),
                ]),
                if (_kind == DbKind.lmdb)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Requires the system liblmdb library '
                      '(Ubuntu: sudo apt install liblmdb0).',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                if (_kind == DbKind.sqlite) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    decoration: _dec(
                        'Password (only for encrypted / SQLCipher databases)'),
                  ),
                ],
              ] else ...[
                Row(children: [
                  Expanded(
                      flex: 3,
                      child:
                          TextField(controller: _host, decoration: _dec('Host'))),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _port,
                      decoration: _dec('Port'),
                      keyboardType: TextInputType.number,
                      onChanged: (_) => _portTouched = true,
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                TextField(
                    controller: _database,
                    decoration: _dec(_kind == DbKind.mongodb
                        ? 'Database (default: test)'
                        : 'Database')),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                      child: TextField(
                          controller: _user, decoration: _dec('Username'))),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _password,
                      obscureText: true,
                      decoration: _dec('Password'),
                    ),
                  ),
                ]),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Use SSL / TLS'),
                  value: _ssl,
                  onChanged: (v) => setState(() => _ssl = v),
                ),
              ],
              if (_kind != DbKind.lmdb)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Ask for the password every time'),
                  subtitle: const Text(
                      'More secure: the password is never saved to disk',
                      style: TextStyle(fontSize: 11)),
                  value: _askPassword,
                  onChanged: (v) => setState(() => _askPassword = v),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final p = widget.existing?.copy() ??
                ConnectionProfile(
                    id: DateTime.now().microsecondsSinceEpoch.toString(),
                    name: '',
                    kind: _kind);
            p
              ..kind = _kind
              ..filePath = _file.text.trim()
              ..host = _host.text.trim()
              ..port = int.tryParse(_port.text.trim()) ?? _kind.defaultPort
              ..user = _user.text.trim()
              ..password = _askPassword ? '' : _password.text
              ..database = _database.text.trim()
              ..useSsl = _ssl
              ..askPassword = _askPassword;
            p.name = _name.text.trim().isEmpty
                ? (_kind.isFileBased
                    ? (p.filePath.split('/').lastOrNull ?? p.kind.label)
                    : '${p.kind.label} @ ${p.host}')
                : _name.text.trim();
            if (_kind.isFileBased && p.filePath.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('Choose a database file / directory first')));
              return;
            }
            Navigator.pop(context, p);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
