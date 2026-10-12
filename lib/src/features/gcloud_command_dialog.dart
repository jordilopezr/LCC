import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';

/// Show a command the user has to run themselves, copyable, with a refresh for
/// when they come back from their terminal.
///
/// Under the gcloud engine LCC does not touch gcloud's own credentials, so this
/// is what "Add account", "Remove account" and the dashboard login button do
/// instead. Without the refresh the user would have to close and reopen the app
/// for LCC to re-read the account list.
Future<void> showGcloudCommandDialog(
  BuildContext context, {
  required String command,
  required String explanation,
  required Future<void> Function() onRefresh,
}) async {
  final l10n = AppLocalizations.of(context);
  // The confirmation lives on the button itself rather than in a SnackBar: one
  // raised while this dialog is open paints under the modal barrier, so the
  // user copies the command and sees nothing. Held here, in the call's scope,
  // so it survives the StatefulBuilder's rebuilds and dies with the dialog.
  var copied = false;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(l10n.gcloudCommandTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(explanation),
              const SizedBox(height: 12),
              SelectableText(
                command,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            icon: Icon(copied ? Icons.check : Icons.copy, size: 18),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: command));
              if (!dialogContext.mounted) return;
              setState(() => copied = true);
            },
            label:
                Text(copied ? l10n.gcloudCommandCopied : l10n.gcloudCommandCopy),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              await onRefresh();
            },
            child: Text(l10n.gcloudCommandRefresh),
          ),
        ],
      ),
    ),
  );
}
