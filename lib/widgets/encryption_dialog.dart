import 'package:flutter/material.dart';

/// What the user chose to do with the database's encryption.
class EncryptionChange {
  /// The new password. Empty string means "remove encryption".
  final String newPassword;
  const EncryptionChange(this.newPassword);
}

/// Lets the user set, change, or remove a SQLite database password.
/// [isEncrypted] reflects the current state. Returns null on cancel.
Future<EncryptionChange?> showEncryptionDialog(
  BuildContext context, {
  required bool isEncrypted,
}) {
  return showDialog<EncryptionChange>(
    context: context,
    builder: (_) => _EncryptionDialog(isEncrypted: isEncrypted),
  );
}

class _EncryptionDialog extends StatefulWidget {
  final bool isEncrypted;
  const _EncryptionDialog({required this.isEncrypted});

  @override
  State<_EncryptionDialog> createState() => _EncryptionDialogState();
}

class _EncryptionDialogState extends State<_EncryptionDialog> {
  final _pw = TextEditingController();
  final _confirm = TextEditingController();
  bool _remove = false;
  bool _show = false;
  String? _error;

  @override
  void dispose() {
    _pw.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _submit() {
    if (_remove) {
      Navigator.pop(context, const EncryptionChange(''));
      return;
    }
    if (_pw.text.isEmpty) {
      setState(() => _error = 'Enter a password.');
      return;
    }
    if (_pw.text != _confirm.text) {
      setState(() => _error = 'The two passwords do not match.');
      return;
    }
    Navigator.pop(context, EncryptionChange(_pw.text));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = widget.isEncrypted ? 'Change password' : 'Encrypt database';
    return AlertDialog(
      title: Row(
        children: [
          Icon(widget.isEncrypted ? Icons.lock : Icons.lock_open,
              color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(title),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.isEncrypted
                  ? 'This database is encrypted. Set a new password below, '
                      'or remove encryption entirely.'
                  : 'This database is not encrypted. Set a password to '
                      'protect it — you will need it to open the file from now on.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 14),
            if (widget.isEncrypted)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Remove encryption (make it a plain file)'),
                value: _remove,
                onChanged: (v) => setState(() {
                  _remove = v ?? false;
                  _error = null;
                }),
              ),
            if (!_remove) ...[
              TextField(
                controller: _pw,
                autofocus: true,
                obscureText: !_show,
                onChanged: (_) => setState(() => _error = null),
                decoration: InputDecoration(
                  labelText: 'New password',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: IconButton(
                    icon: Icon(
                        _show ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _show = !_show),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _confirm,
                obscureText: !_show,
                onSubmitted: (_) => _submit(),
                onChanged: (_) => setState(() => _error = null),
                decoration: const InputDecoration(
                  labelText: 'Confirm password',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  style: TextStyle(color: theme.colorScheme.error, fontSize: 12)),
            ],
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline,
                      size: 16, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'The whole file is rewritten. A backup first is a good idea.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: _submit,
          style: _remove
              ? FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error)
              : null,
          child: Text(_remove ? 'Remove encryption' : 'Apply'),
        ),
      ],
    );
  }
}
