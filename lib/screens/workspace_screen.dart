import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../drivers/db_driver.dart';
import '../models.dart';
import '../services/csv_export.dart';
import '../widgets/encryption_dialog.dart';
import '../widgets/filter_panel.dart';
import '../widgets/result_grid.dart';
import '../widgets/row_editor.dart';

class WorkspaceScreen extends StatefulWidget {
  final DbDriver driver;

  /// Called after the database password is changed, so the caller can persist
  /// the updated profile. Receives the new password ('' when removed).
  final void Function(String newPassword)? onPasswordChanged;

  const WorkspaceScreen(
      {super.key, required this.driver, this.onPasswordChanged});

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen>
    with SingleTickerProviderStateMixin {
  DbDriver get driver => widget.driver;

  late final TabController _tabs;
  final _tableFilter = TextEditingController();
  final _queryCtrl = TextEditingController();

  List<String> _tables = [];
  String? _selectedTable;

  // Data tab state
  QueryResult? _page;
  int _offset = 0;
  static const int _limit = 100;
  int? _totalRows;
  bool _loadingData = false;
  String? _dataError;
  QuerySpec _spec = const QuerySpec();
  bool _showFilter = false;

  // Query tab state
  QueryResult? _queryResult;
  String? _queryError;
  Duration? _queryTime;
  bool _running = false;

  bool _backingUp = false;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _refreshTables();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _tableFilter.dispose();
    _queryCtrl.dispose();
    driver.close();
    super.dispose();
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Theme.of(context).colorScheme.error : null,
    ));
  }

  Future<void> _refreshTables() async {
    try {
      final tables = await driver.listTables();
      setState(() {
        _tables = tables;
        if (_selectedTable == null && tables.isNotEmpty) {
          _selectTable(tables.first);
        }
      });
    } catch (e) {
      _snack('Could not list ${driver.tableNoun}s: $e', error: true);
    }
  }

  Future<void> _selectTable(String table) async {
    setState(() {
      _selectedTable = table;
      _offset = 0;
      _totalRows = null;
      _page = null;
      _dataError = null;
      _spec = const QuerySpec();
    });
    await _loadPage();
  }

  void _applySpec(QuerySpec spec) {
    setState(() {
      _spec = spec;
      _offset = 0;
      _totalRows = null;
    });
    _loadPage();
  }

  Future<void> _loadPage() async {
    final table = _selectedTable;
    if (table == null) return;
    setState(() {
      _loadingData = true;
      _dataError = null;
    });
    try {
      final page = await driver.fetchRows(table,
          offset: _offset, limit: _limit, spec: _spec.isEmpty ? null : _spec);
      int? total = _totalRows;
      total ??= await driver.countRows(table,
          spec: _spec.isEmpty ? null : _spec);
      if (!mounted) return;
      setState(() {
        _page = page;
        _totalRows = total;
      });
    } catch (e) {
      if (mounted) setState(() => _dataError = '$e');
    } finally {
      if (mounted) setState(() => _loadingData = false);
    }
  }

  Future<void> _runQuery() async {
    final q = _queryCtrl.text.trim();
    if (q.isEmpty && driver.supportsSql) return;
    setState(() {
      _running = true;
      _queryError = null;
    });
    final sw = Stopwatch()..start();
    try {
      final res = await driver.runRaw(q);
      sw.stop();
      if (!mounted) return;
      setState(() {
        _queryResult = res;
        _queryTime = sw.elapsed;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _queryError = '$e';
          _queryResult = null;
        });
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _exportTableCsv() async {
    final table = _selectedTable;
    if (table == null) return;
    try {
      // Export everything matching the current filter, not just this page.
      final all = await driver.fetchRows(table,
          offset: 0, limit: 1 << 31, spec: _spec.isEmpty ? null : _spec);
      final path = await exportCsv('$table.csv', all.columns, all.rows);
      if (path != null) _snack('Exported ${all.rows.length} rows to $path');
    } catch (e) {
      _snack('Export failed: $e', error: true);
    }
  }

  Future<void> _exportQueryCsv() async {
    final res = _queryResult;
    if (res == null || !res.hasRows) return;
    try {
      final path = await exportCsv('query_result.csv', res.columns, res.rows);
      if (path != null) _snack('Exported ${res.rows.length} rows to $path');
    } catch (e) {
      _snack('Export failed: $e', error: true);
    }
  }

  Future<void> _backup() async {
    final dir = await FilePicker
        .getDirectoryPath(dialogTitle: 'Choose backup destination folder');
    if (dir == null) return;
    setState(() => _backingUp = true);
    try {
      final created = await driver.backup(dir);
      _snack('Backup created: $created');
    } catch (e) {
      _snack('Backup failed: $e', error: true);
    } finally {
      if (mounted) setState(() => _backingUp = false);
    }
  }

  Future<void> _changePassword() async {
    final wasEncrypted = driver.profile.password.isNotEmpty;
    final change =
        await showEncryptionDialog(context, isEncrypted: wasEncrypted);
    if (change == null) return;
    setState(() => _backingUp = true); // reuse the busy flag for the app bar
    try {
      await driver.setPassword(change.newPassword);
      widget.onPasswordChanged?.call(change.newPassword);
      // The table list survives, but reconnecting (encrypt/decrypt) clears it.
      await _refreshTables();
      if (_selectedTable != null) await _loadPage();
      _snack(change.newPassword.isEmpty
          ? 'Encryption removed — this is now a plain database.'
          : wasEncrypted
              ? 'Password changed.'
              : 'Database encrypted. You will need this password to open it.');
    } catch (e) {
      _snack('Could not change password: $e', error: true);
    } finally {
      if (mounted) setState(() => _backingUp = false);
    }
  }

  Future<void> _insertRow() async {
    final table = _selectedTable;
    final page = _page;
    if (table == null || page == null) return;
    List<String> columns = page.columns;
    if (columns.isEmpty) {
      columns = [for (final c in await driver.describe(table)) c.name];
    }
    if (!mounted) return;
    final edits = await showRowEditor(context,
        title: 'Insert into $table', columns: columns);
    if (edits == null) return;
    try {
      await driver.insertRow(table, edits);
      _snack('Row inserted');
      _totalRows = null;
      await _loadPage();
    } catch (e) {
      _snack('Insert failed: $e', error: true);
    }
  }

  Future<void> _editRow(int index) async {
    final table = _selectedTable;
    final page = _page;
    if (table == null || page == null) return;
    if (page.rowRefs[index] == null) {
      _snack('This row cannot be edited (no row identifier)', error: true);
      return;
    }
    final readOnly = driver.tableNoun == 'collection' ? {'_id'} : <String>{};
    final edits = await showRowEditor(
      context,
      title: 'Edit row',
      columns: page.columns,
      initialValues: page.rows[index],
      readOnlyColumns: readOnly,
    );
    if (edits == null) return;
    try {
      await driver.updateRow(table, page.rowRefs[index], edits);
      _snack('Row updated');
      await _loadPage();
    } catch (e) {
      _snack('Update failed: $e', error: true);
    }
  }

  Future<void> _deleteRow(int index) async {
    final table = _selectedTable;
    final page = _page;
    if (table == null || page == null) return;
    if (page.rowRefs[index] == null) {
      _snack('This row cannot be deleted (no row identifier)', error: true);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete row?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await driver.deleteRow(table, page.rowRefs[index]);
      _snack('Row deleted');
      _totalRows = null;
      await _loadPage();
    } catch (e) {
      _snack('Delete failed: $e', error: true);
    }
  }

  // ---------- UI ----------

  Widget _tableList() {
    final filter = _tableFilter.text.toLowerCase();
    final visible = [
      for (final t in _tables)
        if (filter.isEmpty || t.toLowerCase().contains(filter)) t
    ];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: TextField(
            controller: _tableFilter,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Filter ${driver.tableNoun}s',
              prefixIcon: const Icon(Icons.search, size: 18),
              isDense: true,
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: visible.length,
            itemBuilder: (context, i) {
              final t = visible[i];
              return ListTile(
                dense: true,
                leading: const Icon(Icons.table_chart_outlined, size: 18),
                title:
                    Text(t, maxLines: 1, overflow: TextOverflow.ellipsis),
                selected: t == _selectedTable,
                onTap: () {
                  _selectTable(t);
                  _tabs.animateTo(0);
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _dataTab() {
    final theme = Theme.of(context);
    if (_selectedTable == null) {
      return Center(child: Text('Select a ${driver.tableNoun} on the left'));
    }
    final page = _page;
    final from = _offset + 1;
    final to = _offset + (page?.rows.length ?? 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '$_selectedTable'
                  '${_totalRows == null ? '' : '  ·  $_totalRows rows'}'
                  '${_spec.filters.isEmpty ? '' : ' (filtered)'}',
                  style: theme.textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Badge(
                isLabelVisible: _spec.filters.isNotEmpty,
                label: Text('${_spec.filters.length}'),
                child: IconButton(
                  tooltip: 'Find rows without writing a query',
                  isSelected: _showFilter,
                  onPressed: () => setState(() => _showFilter = !_showFilter),
                  icon: const Icon(Icons.filter_alt_outlined),
                  selectedIcon: const Icon(Icons.filter_alt),
                ),
              ),
              IconButton(
                tooltip: 'Previous page',
                onPressed: _offset > 0 && !_loadingData
                    ? () {
                        _offset = (_offset - _limit).clamp(0, 1 << 31);
                        _loadPage();
                      }
                    : null,
                icon: const Icon(Icons.chevron_left),
              ),
              Text(page == null ? '…' : '$from–$to'),
              IconButton(
                tooltip: 'Next page',
                onPressed: page != null &&
                        page.rows.length == _limit &&
                        !_loadingData
                    ? () {
                        _offset += _limit;
                        _loadPage();
                      }
                    : null,
                icon: const Icon(Icons.chevron_right),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed: _insertRow,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Insert'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _exportTableCsv,
                icon: const Icon(Icons.file_download_outlined, size: 18),
                label: const Text('Export CSV'),
              ),
              IconButton(
                tooltip: 'Refresh',
                onPressed: () {
                  _totalRows = null;
                  _loadPage();
                },
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        if (_showFilter && page != null)
          FilterPanel(
            columns: page.columns,
            spec: _spec,
            generatedQuery: driver.describeQuery(_selectedTable!, _spec,
                limit: _limit),
            onApply: _applySpec,
            onOpenInQueryTab: (q) {
              _queryCtrl.text = q;
              _tabs.animateTo(1);
            },
          ),
        const Divider(height: 1),
        Expanded(
          child: _loadingData && page == null
              ? const Center(child: CircularProgressIndicator())
              : _dataError != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(_dataError!,
                            style:
                                TextStyle(color: theme.colorScheme.error)),
                      ),
                    )
                  : page == null || page.rows.isEmpty
                      ? const Center(child: Text('No rows'))
                      : ResultGrid(
                          columns: page.columns,
                          rows: page.rows,
                          onEditRow: _editRow,
                          onDeleteRow: _deleteRow,
                        ),
        ),
      ],
    );
  }

  Widget _queryTab() {
    final theme = Theme.of(context);
    final res = _queryResult;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.enter,
                      control: true): _runQuery,
                },
                child: TextField(
                  controller: _queryCtrl,
                  maxLines: 6,
                  minLines: 3,
                  style:
                      const TextStyle(fontFamily: 'monospace', fontSize: 13),
                  decoration: InputDecoration(
                    hintText: driver.queryHint,
                    hintMaxLines: 4,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: _running ? null : _runQuery,
                    icon: _running
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.play_arrow, size: 18),
                    label: Text(_running ? 'Running…' : 'Run  (Ctrl+Enter)'),
                  ),
                  const SizedBox(width: 12),
                  if (res != null && res.hasRows)
                    OutlinedButton.icon(
                      onPressed: _exportQueryCsv,
                      icon:
                          const Icon(Icons.file_download_outlined, size: 18),
                      label: const Text('Export CSV'),
                    ),
                  const Spacer(),
                  if (_queryTime != null && _queryError == null)
                    Text(
                      '${res?.hasRows == true ? '${res!.rows.length} rows · ' : ''}'
                      '${_queryTime!.inMilliseconds} ms',
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _queryError != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: SelectableText(_queryError!,
                        style: TextStyle(color: theme.colorScheme.error)),
                  ),
                )
              : res == null
                  ? Center(
                      child: Text('Run a query to see results',
                          style: theme.textTheme.bodySmall))
                  : res.hasRows
                      ? ResultGrid(columns: res.columns, rows: res.rows)
                      : Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: SelectableText(
                                res.message ?? 'Done',
                                style: theme.textTheme.bodyMedium),
                          ),
                        ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(driver.profile.name),
        actions: [
          IconButton(
            tooltip: 'Refresh ${driver.tableNoun} list',
            onPressed: _refreshTables,
            icon: const Icon(Icons.refresh),
          ),
          if (driver.supportsEncryptionManagement)
            IconButton(
              tooltip: driver.profile.password.isEmpty
                  ? 'Encrypt with a password'
                  : 'Change or remove password',
              onPressed: _backingUp ? null : _changePassword,
              icon: Icon(driver.profile.password.isEmpty
                  ? Icons.lock_open_outlined
                  : Icons.lock_outline),
            ),
          const SizedBox(width: 4),
          FilledButton.tonalIcon(
            onPressed: _backingUp ? null : _backup,
            icon: _backingUp
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save_alt, size: 18),
            label: Text(_backingUp ? 'Backing up…' : 'Backup'),
          ),
          const SizedBox(width: 12),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(icon: Icon(Icons.table_rows_outlined, size: 18), text: 'Data'),
            Tab(icon: Icon(Icons.code, size: 18), text: 'Query'),
          ],
        ),
      ),
      body: Row(
        children: [
          SizedBox(width: 240, child: _tableList()),
          const VerticalDivider(width: 1),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [_dataTab(), _queryTab()],
            ),
          ),
        ],
      ),
    );
  }
}
