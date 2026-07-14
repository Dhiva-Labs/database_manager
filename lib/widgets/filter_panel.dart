import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';

/// Plain-English "Find rows" builder: pick a column, a condition, and a
/// value — no SQL knowledge needed. Shows the query it generates so curious
/// users and developers can copy it into the Query tab.
class FilterPanel extends StatefulWidget {
  final List<String> columns;
  final QuerySpec spec;
  final String generatedQuery;
  final void Function(QuerySpec spec) onApply;
  final void Function(String query)? onOpenInQueryTab;

  const FilterPanel({
    super.key,
    required this.columns,
    required this.spec,
    required this.generatedQuery,
    required this.onApply,
    this.onOpenInQueryTab,
  });

  @override
  State<FilterPanel> createState() => _FilterPanelState();
}

class _FilterPanelState extends State<FilterPanel> {
  late List<FilterCondition> _filters;
  String? _sortColumn;
  bool _sortDesc = false;
  bool _showQuery = false;

  @override
  void initState() {
    super.initState();
    _loadFrom(widget.spec);
  }

  @override
  void didUpdateWidget(FilterPanel old) {
    super.didUpdateWidget(old);
    if (!identical(old.spec, widget.spec)) _loadFrom(widget.spec);
  }

  void _loadFrom(QuerySpec spec) {
    _filters = [
      for (final f in spec.filters)
        FilterCondition(column: f.column, op: f.op, value: f.value)
    ];
    _sortColumn = spec.sortColumn;
    _sortDesc = spec.sortDescending;
  }

  void _apply() {
    widget.onApply(QuerySpec(
      filters: [
        for (final f in _filters)
          if (f.column.isNotEmpty) f
      ],
      sortColumn: _sortColumn,
      sortDescending: _sortDesc,
    ));
  }

  Widget _conditionRow(int i) {
    final f = _filters[i];
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Text(i == 0 ? 'Where' : 'and',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(width: 8),
          SizedBox(
            width: 170,
            child: DropdownButtonFormField<String>(
              initialValue: f.column.isEmpty ? null : f.column,
              hint: const Text('column'),
              isDense: true,
              decoration: const InputDecoration(
                  border: OutlineInputBorder(), isDense: true),
              items: [
                for (final c in widget.columns)
                  DropdownMenuItem(value: c, child: Text(c))
              ],
              onChanged: (v) => setState(() => f.column = v ?? ''),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 150,
            child: DropdownButtonFormField<FilterOp>(
              initialValue: f.op,
              isDense: true,
              decoration: const InputDecoration(
                  border: OutlineInputBorder(), isDense: true),
              items: [
                for (final op in FilterOp.values)
                  DropdownMenuItem(value: op, child: Text(op.label))
              ],
              onChanged: (v) => setState(() => f.op = v ?? FilterOp.equals),
            ),
          ),
          const SizedBox(width: 8),
          if (f.op.needsValue)
            Expanded(
              child: TextFormField(
                initialValue: f.value,
                decoration: const InputDecoration(
                    hintText: 'value',
                    border: OutlineInputBorder(),
                    isDense: true),
                onChanged: (v) => f.value = v,
                onFieldSubmitted: (_) => _apply(),
              ),
            )
          else
            const Spacer(),
          IconButton(
            tooltip: 'Remove condition',
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() => _filters.removeAt(i)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < _filters.length; i++) _conditionRow(i),
          Row(
            children: [
              TextButton.icon(
                onPressed: () => setState(() => _filters.add(
                    FilterCondition(column: widget.columns.firstOrNull ?? ''))),
                icon: const Icon(Icons.add, size: 16),
                label: Text(_filters.isEmpty
                    ? 'Add a condition (e.g. "name contains john")'
                    : 'Add another condition'),
              ),
              const SizedBox(width: 16),
              Text('Sort by', style: theme.textTheme.bodySmall),
              const SizedBox(width: 8),
              SizedBox(
                width: 150,
                child: DropdownButtonFormField<String?>(
                  initialValue: _sortColumn,
                  isDense: true,
                  decoration: const InputDecoration(
                      border: OutlineInputBorder(), isDense: true),
                  items: [
                    const DropdownMenuItem<String?>(
                        value: null, child: Text('—')),
                    for (final c in widget.columns)
                      DropdownMenuItem<String?>(value: c, child: Text(c)),
                  ],
                  onChanged: (v) => setState(() => _sortColumn = v),
                ),
              ),
              IconButton(
                tooltip: _sortDesc ? 'Largest first' : 'Smallest first',
                icon: Icon(
                    _sortDesc ? Icons.arrow_downward : Icons.arrow_upward,
                    size: 18),
                onPressed: () => setState(() => _sortDesc = !_sortDesc),
              ),
              const Spacer(),
              TextButton(
                onPressed: () {
                  setState(() {
                    _filters.clear();
                    _sortColumn = null;
                    _sortDesc = false;
                  });
                  widget.onApply(const QuerySpec());
                },
                child: const Text('Clear'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _apply,
                icon: const Icon(Icons.search, size: 18),
                label: const Text('Find rows'),
              ),
            ],
          ),
          // The query behind the buttons — bridge from "clicking" to "writing".
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 28),
                  textStyle: theme.textTheme.bodySmall),
              onPressed: () => setState(() => _showQuery = !_showQuery),
              icon: Icon(_showQuery ? Icons.expand_less : Icons.expand_more,
                  size: 16),
              label: const Text('Show the query this runs'),
            ),
          ),
          if (_showQuery)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: SelectableText(
                      widget.generatedQuery,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy query',
                    icon: const Icon(Icons.copy, size: 16),
                    onPressed: () => Clipboard.setData(
                        ClipboardData(text: widget.generatedQuery)),
                  ),
                  if (widget.onOpenInQueryTab != null)
                    IconButton(
                      tooltip: 'Open in Query tab to customize',
                      icon: const Icon(Icons.open_in_new, size: 16),
                      onPressed: () =>
                          widget.onOpenInQueryTab!(widget.generatedQuery),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
