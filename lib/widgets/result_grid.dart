import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Scrollable (both axes) data grid with optional row tap / delete callbacks.
class ResultGrid extends StatefulWidget {
  final List<String> columns;
  final List<List<Object?>> rows;
  final void Function(int rowIndex)? onEditRow;
  final void Function(int rowIndex)? onDeleteRow;

  const ResultGrid({
    super.key,
    required this.columns,
    required this.rows,
    this.onEditRow,
    this.onDeleteRow,
  });

  @override
  State<ResultGrid> createState() => _ResultGridState();
}

class _ResultGridState extends State<ResultGrid> {
  final _hCtrl = ScrollController();
  final _vCtrl = ScrollController();

  @override
  void dispose() {
    _hCtrl.dispose();
    _vCtrl.dispose();
    super.dispose();
  }

  static String cellText(Object? v) {
    if (v == null) return 'NULL';
    if (v is Uint8List) {
      final hex = v
          .take(24)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      return '0x$hex${v.length > 24 ? '… (${v.length} bytes)' : ''}';
    }
    var s = v.toString();
    if (s.length > 200) s = '${s.substring(0, 200)}…';
    return s.replaceAll('\n', '⏎');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (widget.columns.isEmpty) {
      return const Center(child: Text('No data'));
    }
    final hasActions = widget.onEditRow != null || widget.onDeleteRow != null;
    return Align(
      alignment: Alignment.topLeft,
      child: Scrollbar(
        controller: _hCtrl,
        thumbVisibility: true,
        notificationPredicate: (n) => n.metrics.axis == Axis.horizontal,
        child: SingleChildScrollView(
          controller: _hCtrl,
          scrollDirection: Axis.horizontal,
          child: Scrollbar(
            controller: _vCtrl,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: _vCtrl,
              child: DataTable(
                headingRowColor: WidgetStatePropertyAll(
                  theme.colorScheme.surfaceContainerHighest,
                ),
                headingTextStyle: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
                dataRowMinHeight: 36,
                dataRowMaxHeight: 42,
                columnSpacing: 28,
                columns: [
                  for (final c in widget.columns) DataColumn(label: Text(c)),
                  if (hasActions) const DataColumn(label: Text('')),
                ],
                rows: [
                  for (var i = 0; i < widget.rows.length; i++)
                    DataRow(
                      cells: [
                        for (final v in widget.rows[i])
                          DataCell(
                            Text(
                              cellText(v),
                              style: v == null
                                  ? TextStyle(
                                      color: theme.disabledColor,
                                      fontStyle: FontStyle.italic,
                                    )
                                  : const TextStyle(fontFamily: 'monospace'),
                            ),
                            onTap: widget.onEditRow == null
                                ? null
                                : () => widget.onEditRow!(i),
                          ),
                        if (hasActions)
                          DataCell(
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (widget.onEditRow != null)
                                  IconButton(
                                    icon: const Icon(
                                      Icons.edit_outlined,
                                      size: 17,
                                    ),
                                    tooltip: 'Edit row',
                                    onPressed: () => widget.onEditRow!(i),
                                  ),
                                if (widget.onDeleteRow != null)
                                  IconButton(
                                    icon: Icon(
                                      Icons.delete_outline,
                                      size: 17,
                                      color: theme.colorScheme.error,
                                    ),
                                    tooltip: 'Delete row',
                                    onPressed: () => widget.onDeleteRow!(i),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
