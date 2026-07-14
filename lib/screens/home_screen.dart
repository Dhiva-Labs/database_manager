import 'package:flutter/material.dart';

import '../drivers/db_driver.dart';
import '../drivers/driver_factory.dart';
import '../models.dart';
import '../services/connection_store.dart';
import '../widgets/password_dialog.dart';
import 'connection_editor.dart';
import 'workspace_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _store = ConnectionStore();
  bool _loading = true;
  String? _connectingId;

  @override
  void initState() {
    super.initState();
    _store.load().then((_) {
      if (mounted) setState(() => _loading = false);
    });
  }

  IconData _icon(DbKind kind) => switch (kind) {
        DbKind.sqlite => Icons.insert_drive_file_outlined,
        DbKind.mysql => Icons.storage,
        DbKind.postgres => Icons.account_tree_outlined,
        DbKind.mongodb => Icons.eco_outlined,
        DbKind.lmdb => Icons.memory,
      };

  Future<void> _addOrEdit({ConnectionProfile? existing}) async {
    final result = await showConnectionEditor(context, existing: existing);
    if (result == null) return;
    setState(() {
      final idx = _store.profiles.indexWhere((p) => p.id == result.id);
      if (idx >= 0) {
        _store.profiles[idx] = result;
      } else {
        _store.profiles.add(result);
      }
    });
    await _store.save();
  }

  /// True when the error from a server engine smells like a bad password,
  /// so re-prompting can help.
  static bool _looksLikeAuthError(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('password') ||
        s.contains('access denied') ||
        s.contains('authentication') ||
        s.contains('auth failed');
  }

  Future<void> _open(ConnectionProfile profile) async {
    // Work on a copy so a typed-in password is never saved accidentally.
    final attempt = profile.copy();
    var needPrompt = profile.askPassword;
    String? promptMessage;

    setState(() => _connectingId = profile.id);
    try {
      while (true) {
        if (needPrompt) {
          if (!mounted) return;
          final entry = await showPasswordDialog(context,
              connectionName: profile.name, message: promptMessage);
          if (entry == null) return; // user cancelled
          attempt.password = entry.password;
          if (entry.remember) {
            profile.password = entry.password;
            profile.askPassword = false;
            await _store.save();
          }
        }
        final driver = createDriver(attempt);
        try {
          await driver.connect();
          if (!mounted) return;
          await Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => WorkspaceScreen(
                    driver: driver,
                    onPasswordChanged: (newPassword) async {
                      // Keep the saved profile in step with the new key. For
                      // "ask every time" connections we never persist it.
                      if (!profile.askPassword) {
                        profile.password = newPassword;
                        await _store.save();
                      }
                    },
                  )));
          return;
        } on PasswordRequiredException catch (e) {
          await driver.close();
          needPrompt = true;
          promptMessage = e.message;
        } catch (e) {
          await driver.close();
          // A wrong stored/typed password on a server: offer to retype it.
          if (!profile.kind.isFileBased && _looksLikeAuthError(e)) {
            needPrompt = true;
            promptMessage = 'Sign-in failed: $e';
            continue;
          }
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('Connection failed: $e'),
              backgroundColor: Theme.of(context).colorScheme.error,
            ));
          }
          return;
        }
      }
    } finally {
      if (mounted) setState(() => _connectingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Database Manager'),
        centerTitle: false,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addOrEdit(),
        icon: const Icon(Icons.add),
        label: const Text('New connection'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _store.profiles.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.dns_outlined,
                          size: 72, color: theme.disabledColor),
                      const SizedBox(height: 16),
                      Text('No connections yet',
                          style: theme.textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(
                        'Add a SQLite file, LMDB directory, or a\n'
                        'MySQL / PostgreSQL / MongoDB server.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _store.profiles.length,
                  itemBuilder: (context, i) {
                    final p = _store.profiles[i];
                    final connecting = _connectingId == p.id;
                    return Card(
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor:
                              theme.colorScheme.primaryContainer,
                          child: Icon(_icon(p.kind),
                              color: theme.colorScheme.onPrimaryContainer),
                        ),
                        title: Text(p.name),
                        subtitle: Text('${p.kind.label} · ${p.subtitle}',
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: connecting ? null : () => _open(p),
                        trailing: connecting
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : PopupMenuButton<String>(
                                onSelected: (v) async {
                                  switch (v) {
                                    case 'edit':
                                      await _addOrEdit(existing: p);
                                    case 'duplicate':
                                      final copy = p.copy()
                                        ..id = DateTime.now()
                                            .microsecondsSinceEpoch
                                            .toString()
                                        ..name = '${p.name} (copy)';
                                      setState(
                                          () => _store.profiles.add(copy));
                                      await _store.save();
                                    case 'delete':
                                      setState(() =>
                                          _store.profiles.removeAt(i));
                                      await _store.save();
                                  }
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                      value: 'edit', child: Text('Edit')),
                                  PopupMenuItem(
                                      value: 'duplicate',
                                      child: Text('Duplicate')),
                                  PopupMenuItem(
                                      value: 'delete', child: Text('Delete')),
                                ],
                              ),
                      ),
                    );
                  },
                ),
    );
  }
}
