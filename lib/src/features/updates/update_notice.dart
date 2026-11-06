import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:linux_cloud_connector/src/features/updates/update_checker.dart';
import 'package:linux_cloud_connector/src/features/updates/update_policy.dart';

/// What to tell the user about a release they do not have.
class UpdateNotice {
  const UpdateNotice({
    required this.release,
    required this.unsupported,
    required this.newerStable,
  });

  /// The release the notice points to.
  final ReleaseCandidate release;

  /// The installed stable edition gets no more security patches. Such a
  /// notice cannot be skipped for good, only put off until the next start.
  final bool unsupported;

  /// A stable release newer than the installed build, when [release] is a
  /// preview: the preview user can switch channel to get it.
  final ReleaseCandidate? newerStable;

  String get tag => release.release.tag;
}

/// The notice for [result], or null when there is nothing to say.
///
/// A skipped release is not mentioned again, but a newer one is. An
/// unsupported installation ignores skipping: the user is told until they
/// upgrade.
UpdateNotice? updateNoticeFor({
  required UpdateCheckResult? result,
  String? skippedTag,
}) {
  if (result == null) return null;
  // On the preview channel, a stable user out of support is pointed at the
  // stable release that restores patches, not at whatever preview is newest.
  final target = result.installedUnsupported
      ? result.newerStable ?? result.available
      : result.available;
  if (target == null) return null;
  if (!result.installedUnsupported && target.release.tag == skippedTag) {
    return null;
  }
  return UpdateNotice(
    release: target,
    unsupported: result.installedUnsupported,
    newerStable: identical(target, result.newerStable) ? null : result.newerStable,
  );
}

/// The release the user chose to skip, by tag. Loading until read, so that a
/// skipped release is never shown while the preference is still on its way.
final updateSkippedTagProvider =
    AsyncNotifierProvider<UpdateSkippedTagNotifier, String?>(
        UpdateSkippedTagNotifier.new);

class UpdateSkippedTagNotifier extends AsyncNotifier<String?> {
  static const _prefsKey = 'update_skipped_tag';

  @override
  Future<String?> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefsKey);
  }

  Future<void> skip(String tag) async {
    await future;
    state = AsyncData(tag);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, tag);
  }
}

/// The notice the user put off with "later", by tag. Kept for this run only.
final updateDismissedTagProvider =
    NotifierProvider<UpdateDismissedTagNotifier, String?>(
        UpdateDismissedTagNotifier.new);

class UpdateDismissedTagNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void dismiss(String tag) => state = tag;
}

/// The release still waiting for the user: skipped ones excluded, put-off
/// ones not. Drives the About indicator.
final pendingUpdateProvider = Provider<UpdateNotice?>((ref) {
  final skipped = ref.watch(updateSkippedTagProvider);
  if (!skipped.hasValue) return null;
  return updateNoticeFor(
    result: ref.watch(updateCheckerProvider).result,
    skippedTag: skipped.value,
  );
});

/// The notice the banner shows: the pending one, unless put off.
final updateNoticeProvider = Provider<UpdateNotice?>((ref) {
  final notice = ref.watch(pendingUpdateProvider);
  if (notice == null || notice.tag == ref.watch(updateDismissedTagProvider)) {
    return null;
  }
  return notice;
});
