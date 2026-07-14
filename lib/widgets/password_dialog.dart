import 'package:flutter/material.dart';

class PasswordResult {
  final String password;
  final bool remember;
  PasswordResult(this.password, this.remember);
}

/// Prompts for a database password. Returns null on cancel.
Future<PasswordResult?> showPasswordDialog(
  BuildContext context, {
  required String connectionName,
  String? message,
}) {
  return showDialog<PasswordResult>(
    context: context,
    builder: (_) => _PasswordDialog(name: connectionName, message: message),
  );
}

class _PasswordDialog extends StatefulWidget {
  final String name;
  final String? message;
  const _PasswordDialog({required this.name, this.message});

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _ctrl = TextEditingController();
  bool _show = false;
  bool _remember = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() =>
      Navigator.pop(context, PasswordResult(_ctrl.text, _remember));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.lock_outline, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(child: Text('Password for ${widget.name}')),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.message != null) ...[
              Text(widget.message!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error)),
              const SizedBox(height: 10),
            ],
            TextField(
              controller: _ctrl,
              autofocus: true,
              obscureText: !_show,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: 'Password',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
                  tooltip: _show ? 'Hide' : 'Show',
                  onPressed: () => setState(() => _show = !_show),
                ),
              ),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Remember this password'),
              subtitle: const Text('Stored as plain text on this computer',
                  style: TextStyle(fontSize: 11)),
              value: _remember,
              onChanged: (v) => setState(() => _remember = v ?? false),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Unlock')),
      ],
    );
  }
}
