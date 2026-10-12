import 'package:flutter/material.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';

import 'package:linux_cloud_connector/src/bridge/api.dart/accounts.dart'
    show KeyringProblem;

/// The dashboard body when the active account's sign-in is saved but the
/// system keyring will not hand it over. Each problem gets its own wording,
/// and none claims a cause the app cannot tell apart ("locked, or the unlock
/// was cancelled").
class KeyringProblemScreen extends StatelessWidget {
  const KeyringProblemScreen({
    super.key,
    required this.problem,
    required this.onCheckAgain,
  });

  final KeyringProblem problem;
  final VoidCallback onCheckAgain;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final body = switch (problem) {
      KeyringProblem.unreachable => l10n.dashboardKeyringUnreachableBody,
      KeyringProblem.refused => l10n.dashboardKeyringRefusedBody,
      KeyringProblem.pending => l10n.dashboardKeyringPendingBody,
    };
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline,
                    size: 72, color: Colors.blueGrey.shade300),
                const SizedBox(height: 16),
                Text(
                  l10n.dashboardKeyringTitle,
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Text(body,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 14)),
                const SizedBox(height: 8),
                Text(l10n.dashboardKeyringSessionKept,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 14, color: Colors.grey)),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: onCheckAgain,
                  icon: const Icon(Icons.refresh),
                  label: Text(l10n.dashboardCheckAgainButton),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
