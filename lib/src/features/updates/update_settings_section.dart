import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';

import 'package:linux_cloud_connector/src/features/updates/release_version.dart';
import 'package:linux_cloud_connector/src/features/updates/update_checker.dart';
import 'package:linux_cloud_connector/src/features/updates/update_preferences.dart';
import 'package:linux_cloud_connector/src/utils/open_external.dart';
import 'package:linux_cloud_connector/src/version.dart';

/// A release as the user reads it: "27H2 Preview (build 20270310.4)",
/// "27H1 Stable", "27H1 Stable, update 2".
String describeRelease(AppLocalizations l10n, ReleaseVersion version) {
  final build = version.build;
  if (version.channel == ReleaseChannel.preview && build != null) {
    return l10n.updatesVersionPreview(version.edition, build.toString());
  }
  if (version.update > 0) {
    return l10n.updatesVersionStableUpdate(
        version.edition, version.update.toString());
  }
  return l10n.updatesVersionStable(version.edition);
}

/// The "Updates" section of the settings dialog: the automatic check switch,
/// the release channel, and a manual check with its outcome.
class UpdateSettingsSection extends ConsumerStatefulWidget {
  const UpdateSettingsSection({super.key});

  @override
  ConsumerState<UpdateSettingsSection> createState() =>
      _UpdateSettingsSectionState();
}

class _UpdateSettingsSectionState extends ConsumerState<UpdateSettingsSection> {
  /// The user pressed "check now" while this section was open. Only then is a
  /// failure shown: automatic checks fail quietly.
  bool _checkedHere = false;

  void _checkNow() {
    setState(() => _checkedHere = true);
    unawaited(ref.read(updateCheckerProvider.notifier).checkNow());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final enabled = ref.watch(updateCheckEnabledProvider);
    final channel = ref.watch(updateChannelProvider);
    final check = ref.watch(updateCheckerProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.settingsUpdatesTitle,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          title: Text(l10n.settingsUpdatesAutoCheck),
          subtitle: Text(l10n.settingsUpdatesAutoCheckSubtitle),
          value: enabled,
          onChanged: (value) =>
              ref.read(updateCheckEnabledProvider.notifier).setEnabled(value),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 16, top: 8, bottom: 4),
          child: Text(
            l10n.settingsUpdatesChannelLabel,
            style: const TextStyle(fontSize: 13, color: Colors.grey),
          ),
        ),
        for (final option in ReleaseChannel.values.reversed)
          // ignore: deprecated_member_use
          RadioListTile<ReleaseChannel>(
            title: Text(_channelLabel(l10n, option)),
            subtitle: Text(_channelDescription(l10n, option),
                style: const TextStyle(fontSize: 11)),
            value: option,
            // ignore: deprecated_member_use
            groupValue: channel,
            // ignore: deprecated_member_use
            onChanged: (value) {
              if (value != null) {
                ref.read(updateChannelProvider.notifier).setChannel(value);
              }
            },
          ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _buildStatus(l10n, check)),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: check.checking ? null : _checkNow,
                icon: check.checking
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 18),
                label: Text(l10n.settingsUpdatesCheckNow),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStatus(AppLocalizations l10n, UpdateCheckState check) {
    final lastChecked = check.lastChecked;
    final available = check.result?.available;
    final failed = !check.checking && _checkedHere && check.lastError != null;

    final String outcome;
    if (check.checking) {
      outcome = l10n.settingsUpdatesChecking;
    } else if (failed) {
      outcome = l10n.settingsUpdatesCheckFailed;
    } else if (available != null) {
      outcome = l10n.settingsUpdatesAvailable(
          describeRelease(l10n, available.version));
    } else if (check.result != null) {
      outcome = l10n.settingsUpdatesUpToDate;
    } else {
      outcome = l10n.settingsUpdatesNeverChecked;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          outcome,
          style: TextStyle(
            fontSize: 13,
            fontWeight: available != null && !failed ? FontWeight.w600 : null,
            color: failed ? Theme.of(context).colorScheme.error : null,
          ),
        ),
        if (lastChecked != null) ...[
          const SizedBox(height: 2),
          Text(l10n.settingsUpdatesLastChecked(lastChecked.toLocal()),
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        ],
        if (available != null && !check.checking)
          TextButton.icon(
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
            ),
            // The URL is one of this repository's release pages: anything
            // else was dropped when the list was read.
            onPressed: () => openExternal(available.release.htmlUrl),
            icon: const Icon(Icons.open_in_new, size: 16),
            label: Text(l10n.updatesViewRelease),
          ),
      ],
    );
  }

  String _channelLabel(AppLocalizations l10n, ReleaseChannel channel) =>
      switch (channel) {
        ReleaseChannel.stable => l10n.settingsUpdatesChannelStable,
        ReleaseChannel.preview => l10n.settingsUpdatesChannelPreview,
      };

  String _channelDescription(AppLocalizations l10n, ReleaseChannel channel) =>
      switch (channel) {
        ReleaseChannel.stable => l10n.settingsUpdatesChannelStableDesc,
        ReleaseChannel.preview => l10n.settingsUpdatesChannelPreviewDesc,
      };
}
