import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models.dart';

/// Dialog to insert or edit a row. Returns column -> CellEdit, or null on
/// cancel.
Future<Map<String, CellEdit>?> showRowEditor(
  BuildContext context, {
  required String title,
  required List<String> columns,
  List<Object?>? initialValues,
  Set<String> readOnlyColumns = const {},
}) {
  return showDialog<Map<String, CellEdit>>(
    context: context,
    builder: (_) => _RowEditorDialog(
      title: title,
      columns: columns,
      initialValues: initialValues,
      readOnlyColumns: readOnlyColumns,
    ),
  );
}

class _RowEditorDialog extends StatefulWidget {
  final String title;
  final List<String> columns;
  final List<Object?>? initialValues;
  final Set<String> readOnlyColumns;

  const _RowEditorDialog({
    required this.title,
    required this.columns,
    this.initialValues,
    required this.readOnlyColumns,
  });

  @override
  State<_RowEditorDialog> createState() => _RowEditorDialogState();
}

class _RowEditorDialogState extends State<_RowEditorDialog> {
  late final List<TextEditingController> _ctrls;
  late final List<bool> _isNull;

  static String _asText(Object? v) {
    if (v == null) return '';
    if (v is Uint8List) {
      return '0x${v.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
    }
    return v.toString();
  }

  @override
  void initState() {
    super.initState();
    _ctrls = [
      for (var i = 0; i < widget.columns.length; i++)
        TextEditingController(text: _asText(widget.initialValues?[i]))
    ];
    _isNull = [
      for (var i = 0; i < widget.columns.length; i++)
        widget.initialValues != null && widget.initialValues![i] == null
    ];
  }

  @override
  void dispose() {
    for (final c in _ctrls) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 520,
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: widget.columns.length,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (context, i) {
            final col = widget.columns[i];
            final readOnly = widget.readOnlyColumns.contains(col);
            return Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _ctrls[i],
                    enabled: !readOnly && !_isNull[i],
                    maxLines: null,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                    decoration: InputDecoration(
                      labelText: col + (readOnly ? ' (read-only)' : ''),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value: _isNull[i],
                      onChanged: readOnly
                          ? null
                          : (v) => setState(() => _isNull[i] = v ?? false),
                    ),
                    const Text('NULL', style: TextStyle(fontSize: 10)),
                  ],
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final result = <String, CellEdit>{};
            for (var i = 0; i < widget.columns.length; i++) {
              if (widget.readOnlyColumns.contains(widget.columns[i])) continue;
              result[widget.columns[i]] =
                  CellEdit(_ctrls[i].text, _isNull[i]);
            }
            Navigator.pop(context, result);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
