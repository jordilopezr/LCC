import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import '../bridge/api.dart/api.dart';
import '../services/storage_service.dart';
import 'settings_dialog.dart';

/// Show the "native sign-in is now the default" notice, once, and only to
/// someone who arrived at the new default without asking for it.
///
/// Both conditions matter. The flag stops it repeating; `storedEngine(slot:
/// 'auth') == null` stops it reaching someone who already picked an engine by
/// hand — nothing changed for them, so there is nothing to explain.
Future<void> maybeShowEngineChangeNotice(BuildContext context) async {
  final bool show;
  try {
    final storage = StorageService();
    if (storage.getEngineChangeNoticeSeen()) return;
    if (await storedEngine(slot: 'auth') != null) return;
    // Marked BEFORE showing: if the app is closed with the dialog open, not
    // showing it again beats showing it every launch.
    await storage.setEngineChangeNoticeSeen();
    show = true;
  } catch (e) {
    // Callers fire this and walk away, so an exception here would surface as an
    // unhandled async error and take the dashboard down with it. A notice that
    // cannot work out whether to appear simply does not appear.
    debugPrint('Engine change notice skipped: $e');
    return;
  }
  if (!show || !context.mounted) return;

  final l10n = AppLocalizations.of(context);
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.engineNoticeTitle),
      content: SingleChildScrollView(child: Text(l10n.engineNoticeBody)),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.pop(dialogContext);
            showSettingsDialog(context);
          },
          child: Text(l10n.engineNoticeOpenSettings),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(l10n.engineNoticeGotIt),
        ),
      ],
    ),
  );
}
