import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:linux_cloud_connector/src/features/updates/github_releases.dart';
import 'package:linux_cloud_connector/src/features/updates/release_version.dart';
import 'package:linux_cloud_connector/src/features/updates/update_policy.dart';
import 'package:linux_cloud_connector/src/features/updates/update_preferences.dart';

/// Time between automatic checks. Releases come out days apart; twice a day
/// finds one soon enough without the check being noticeable.
const kUpdateCheckInterval = Duration(hours: 12);

/// The first automatic check waits this long after start, so it never
/// competes with sign-in and the first project load.
const kUpdateCheckStartupDelay = Duration(seconds: 20);

/// After a failed check (offline, proxy, GitHub down), the next attempt comes
/// this much later instead of a full interval.
const kUpdateCheckRetryDelay = Duration(hours: 1);

/// How long until the next automatic check.
///
/// Due a full interval after the last successful check, or a retry delay
/// after a failure newer than it; never sooner than [minimum], and never
/// later than an interval from now, so a clock set back cannot postpone
/// checks indefinitely.
Duration nextUpdateCheckDelay({
  required DateTime now,
  DateTime? lastChecked,
  DateTime? lastFailed,
  Duration minimum = Duration.zero,
}) {
  final DateTime due;
  if (lastFailed != null &&
      (lastChecked == null || lastFailed.isAfter(lastChecked))) {
    due = lastFailed.add(kUpdateCheckRetryDelay);
  } else if (lastChecked != null) {
    due = lastChecked.add(kUpdateCheckInterval);
  } else {
    due = now;
  }
  final delay = due.difference(now);
  if (delay < minimum) return minimum;
  if (delay > kUpdateCheckInterval) return kUpdateCheckInterval;
  return delay;
}

/// Where the release list comes from. Overridden in tests.
final releasesFetcherProvider =
    Provider<ReleasesFetcher>((ref) => fetchReleasesFromGitHub);

/// The build to compare releases against. Overridden in tests.
final installedVersionProvider =
    Provider<ReleaseVersion>((ref) => ReleaseVersion.installed);

/// The clock the checker schedules by. Overridden in tests.
final updateCheckClockProvider =
    Provider<DateTime Function()>((ref) => DateTime.now);

/// What the update checker knows right now.
class UpdateCheckState {
  const UpdateCheckState({
    required this.result,
    required this.lastChecked,
    required this.checking,
    required this.lastError,
  });

  /// Null until a release list has been fetched, now or on an earlier run.
  final UpdateCheckResult? result;

  /// The last check that reached GitHub, on this run or an earlier one.
  final DateTime? lastChecked;

  /// A request is in flight.
  final bool checking;

  /// Why the latest attempt failed; null once one succeeds. Automatic checks
  /// never show it: only a manual "check now" has someone waiting for it.
  final Object? lastError;
}

/// Checks GitHub for new releases: on its own, a short while after start and
/// every [kUpdateCheckInterval] while checking is enabled, and on request.
///
/// The release list is kept on disk with its ETag. A restart therefore knows
/// the last result before any request, does not check again before the
/// interval is up, and an unchanged list costs GitHub a 304.
///
/// Failures are only logged and kept in [UpdateCheckState.lastError]: a check
/// that cannot reach GitHub has nothing to tell the user unless they asked.
class UpdateCheckerNotifier extends Notifier<UpdateCheckState> {
  static const _cacheKey = 'update_check_cache';

  Timer? _timer;
  Future<void>? _inFlight;
  List<PublishedRelease>? _releases;
  String? _etag;
  DateTime? _lastChecked;
  DateTime? _lastFailed;
  Object? _lastError;
  bool _checking = false;

  /// Scheduling starts once the stored list and preference have been read;
  /// until then a preference change has nothing to reschedule.
  bool _scheduling = false;

  /// The read of the stored release list, started by [build].
  late Future<void> loaded;

  @override
  UpdateCheckState build() {
    ref.onDispose(() => _timer?.cancel());
    ref.listen(updateChannelProvider, (_, _) => _emit());
    ref.listen(updateCheckEnabledProvider, (_, _) {
      if (_scheduling) _schedule();
    });
    loaded = _loadCache();
    unawaited(_startScheduling());
    return _snapshot();
  }

  /// Checks now, whatever the schedule or the enabled switch. A call while a
  /// check is in flight shares it.
  Future<void> checkNow() =>
      _inFlight ??= _check().whenComplete(() => _inFlight = null);

  Future<void> _startScheduling() async {
    await loaded;
    await ref.read(updateCheckEnabledProvider.notifier).loaded;
    if (!ref.mounted) return;
    _scheduling = true;
    _schedule(minimum: kUpdateCheckStartupDelay);
  }

  void _schedule({Duration minimum = Duration.zero}) {
    _timer?.cancel();
    _timer = null;
    if (!ref.read(updateCheckEnabledProvider)) return;
    final delay = nextUpdateCheckDelay(
      now: ref.read(updateCheckClockProvider)(),
      lastChecked: _lastChecked,
      lastFailed: _lastFailed,
      minimum: minimum,
    );
    _timer = Timer(delay, () => unawaited(checkNow()));
  }

  Future<void> _check() async {
    await loaded;
    if (!ref.mounted) return;
    _timer?.cancel();
    _checking = true;
    _emit();
    try {
      final response = await ref.read(releasesFetcherProvider)(
          etag: _releases == null ? null : _etag);
      if (!ref.mounted) return;
      if (response case ReleasesFetched(:final releases, :final etag)) {
        _releases = releases;
        _etag = etag;
      }
      _lastChecked = ref.read(updateCheckClockProvider)();
      _lastFailed = null;
      _lastError = null;
      await _saveCache();
    } catch (e) {
      debugPrint('Update check failed: $e');
      if (!ref.mounted) return;
      _lastFailed = ref.read(updateCheckClockProvider)();
      _lastError = e;
    } finally {
      if (ref.mounted) {
        _checking = false;
        _emit();
        if (_scheduling) _schedule();
      }
    }
  }

  UpdateCheckState _snapshot() {
    final releases = _releases;
    return UpdateCheckState(
      result: releases == null
          ? null
          : evaluateUpdate(
              installed: ref.read(installedVersionProvider),
              channel: ref.read(updateChannelProvider),
              releases: releases,
            ),
      lastChecked: _lastChecked,
      checking: _checking,
      lastError: _lastError,
    );
  }

  void _emit() => state = _snapshot();

  Future<void> _loadCache() async {
    final prefs = await SharedPreferences.getInstance();
    final cache = decodeUpdateCheckCache(prefs.getString(_cacheKey));
    // No check can have finished first: checks wait on this read.
    if (cache == null || !ref.mounted) return;
    _releases = cache.releases;
    _etag = cache.etag;
    _lastChecked = cache.checkedAt;
    _emit();
  }

  Future<void> _saveCache() async {
    final releases = _releases;
    final checkedAt = _lastChecked;
    if (releases == null || checkedAt == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _cacheKey,
      encodeUpdateCheckCache(UpdateCheckCache(
        releases: releases,
        etag: _etag,
        checkedAt: checkedAt,
      )),
    );
  }
}

final updateCheckerProvider =
    NotifierProvider<UpdateCheckerNotifier, UpdateCheckState>(
        UpdateCheckerNotifier.new);

/// The release list as stored between runs: only what the policy reads, a
/// few dozen bytes per release instead of the API's kilobytes.
class UpdateCheckCache {
  const UpdateCheckCache({
    required this.releases,
    required this.etag,
    required this.checkedAt,
  });

  final List<PublishedRelease> releases;
  final String? etag;
  final DateTime checkedAt;
}

String encodeUpdateCheckCache(UpdateCheckCache cache) => jsonEncode({
      'checkedAt': cache.checkedAt.toUtc().toIso8601String(),
      'etag': cache.etag,
      'releases': [
        for (final r in cache.releases)
          {'tag': r.tag, 'prerelease': r.prerelease, 'url': r.htmlUrl},
      ],
    });

/// The stored cache, or null if there is none or it cannot be read — in
/// which case the next check simply fetches the whole list again.
UpdateCheckCache? decodeUpdateCheckCache(String? stored) {
  if (stored == null) return null;
  try {
    if (jsonDecode(stored) case {
          'checkedAt': final String checkedAt,
          'etag': final String? etag,
          'releases': final List<Object?> releases,
        }) {
      return UpdateCheckCache(
        checkedAt: DateTime.parse(checkedAt),
        etag: etag,
        releases: [
          for (final r in releases)
            if (r case {
                  'tag': final String tag,
                  'prerelease': final bool prerelease,
                  'url': final String url,
                } when url.startsWith(kReleasesPagePrefix))
              PublishedRelease(tag: tag, prerelease: prerelease, htmlUrl: url),
        ],
      );
    }
  } on FormatException {
    // Falls through: unreadable is the same as absent.
  }
  return null;
}
