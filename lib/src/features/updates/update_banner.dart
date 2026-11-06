import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:linux_cloud_connector/src/features/updates/update_checker.dart';
import 'package:linux_cloud_connector/src/features/updates/update_notice.dart';
import 'package:linux_cloud_connector/src/features/updates/update_policy.dart';
import 'package:linux_cloud_connector/src/features/updates/update_settings_section.dart';
import 'package:linux_cloud_connector/src/services/notification_service.dart';
import 'package:linux_cloud_connector/src/utils/open_external.dart';

/// Tells the desktop about [notice], whose release [version] describes for
/// the user.
typedef UpdateDesktopNotifier = Future<void> Function(
    UpdateNotice notice, String version);

/// How the desktop hears about a release. Overridden in tests.
final updateDesktopNotifierProvider = Provider<UpdateDesktopNotifier>(
  (ref) => (notice, version) => NotificationService().notifyUpdateAvailable(
        tag: notice.tag,
        version: version,
        edition: ref.read(installedVersionProvider).edition,
        unsupported: notice.unsupported,
      ),
);

/// Non-modal banner at the top of the dashboard about a release the user
/// does not have, with "view on GitHub", "later" and — unless the installed
/// edition is out of support — "skip this version".
///
/// It is always mounted, signed in or not, so it is also what keeps the
/// update checker running from start, and what sends the one desktop
/// notification each release gets.
class UpdateBanner extends ConsumerStatefulWidget {
  const UpdateBanner({super.key});

  @override
  ConsumerState<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends ConsumerState<UpdateBanner> {
  static const _notifiedKey = 'update_notified_tag';

  /// The release a notification was last considered for on this run, so
  /// that two changes in a row do not both get past the stored check.
  String? _notifying;

  @override
  void initState() {
    super.initState();
    ref.listenManual(pendingUpdateProvider, (_, next) => _maybeNotify(next),
        fireImmediately: true);
  }

  /// One notification per release, ever: it is for when LCC is in the
  /// background; the banner covers the rest.
  Future<void> _maybeNotify(UpdateNotice? notice) async {
    if (notice == null || notice.tag == _notifying) return;
    _notifying = notice.tag;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_notifiedKey) == notice.tag) return;
    await prefs.setString(_notifiedKey, notice.tag);
    if (!mounted) return;
    final version =
        describeRelease(AppLocalizations.of(context), notice.release.version);
    await ref.read(updateDesktopNotifierProvider)(notice, version);
  }

  @override
  Widget build(BuildContext context) {
    // Watched here, not only through the notice, so the checker runs even
    // while there is nothing to show.
    ref.watch(updateCheckerProvider);
    final notice = ref.watch(updateNoticeProvider);
    if (notice == null) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final foreground = notice.unsupported
        ? scheme.onErrorContainer
        : scheme.onSecondaryContainer;
    final version = describeRelease(l10n, notice.release.version);
    final newerStable = notice.newerStable;

    return MaterialBanner(
      backgroundColor: notice.unsupported
          ? scheme.errorContainer
          : scheme.secondaryContainer,
      leading: Icon(
        notice.unsupported ? Icons.gpp_maybe : Icons.system_update,
        color: foreground,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            notice.unsupported
                ? l10n.updatesUnsupportedBody(
                    ref.watch(installedVersionProvider).edition, version)
                : l10n.updatesAvailableBody(version),
            style: TextStyle(color: foreground),
          ),
          if (newerStable != null) ...[
            const SizedBox(height: 4),
            Text(
              l10n.updatesNewerStableHint(
                  describeRelease(l10n, newerStable.version)),
              style: TextStyle(color: foreground, fontSize: 12),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () =>
              ref.read(updateDismissedTagProvider.notifier).dismiss(notice.tag),
          child: Text(l10n.updatesLater),
        ),
        if (!notice.unsupported)
          TextButton(
            onPressed: () =>
                ref.read(updateSkippedTagProvider.notifier).skip(notice.tag),
            child: Text(l10n.updatesSkipVersion),
          ),
        FilledButton.icon(
          // One of this repository's release pages: anything else was
          // dropped when the list was read.
          onPressed: () => openExternal(notice.release.release.htmlUrl),
          icon: const Icon(Icons.open_in_new, size: 16),
          label: Text(l10n.updatesViewRelease),
        ),
      ],
    );
  }
}

/// The update line of the About dialog: what the last check found, skipped
/// releases included — About answers "am I up to date?", it does not nag.
/// Nothing until a check has been made; otherwise it brings its own space
/// above.
class UpdateAboutStatus extends ConsumerWidget {
  const UpdateAboutStatus({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(updateCheckerProvider).result;
    if (result == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: _buildLine(context, ref, result),
    );
  }

  Widget _buildLine(
      BuildContext context, WidgetRef ref, UpdateCheckResult result) {
    final l10n = AppLocalizations.of(context);
    final notice = updateNoticeFor(result: result);

    if (notice == null) {
      return Row(
        children: [
          Icon(Icons.check_circle_outline,
              size: 14, color: Colors.green.shade600),
          const SizedBox(width: 6),
          Expanded(
            child: Text(l10n.settingsUpdatesUpToDate,
                style: const TextStyle(fontSize: 12)),
          ),
        ],
      );
    }

    final version = describeRelease(l10n, notice.release.version);
    final color = notice.unsupported
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.primary;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(
              notice.unsupported ? Icons.gpp_maybe : Icons.system_update,
              size: 14,
              color: color),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                notice.unsupported
                    ? l10n.updatesUnsupportedBody(
                        ref.watch(installedVersionProvider).edition, version)
                    : l10n.settingsUpdatesAvailable(version),
                style: TextStyle(fontSize: 12, color: color),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => openExternal(notice.release.release.htmlUrl),
                icon: const Icon(Icons.open_in_new, size: 14),
                label: Text(l10n.updatesViewRelease,
                    style: const TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
