import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/src/features/updates/github_releases.dart';
import 'package:linux_cloud_connector/src/features/updates/release_version.dart';
import 'package:linux_cloud_connector/src/features/updates/update_checker.dart';
import 'package:linux_cloud_connector/src/features/updates/update_policy.dart';
import 'package:linux_cloud_connector/src/features/updates/update_preferences.dart';
import 'package:linux_cloud_connector/src/version.dart';
import 'package:shared_preferences/shared_preferences.dart';

PublishedRelease _release(String tag) => PublishedRelease(
      tag: tag,
      prerelease: tag.contains('-preview.'),
      htmlUrl: '${kReleasesPagePrefix}tag/$tag',
    );

final _now = DateTime.utc(2026, 11, 6, 12);

/// A GitHub that answers from a script, and records what it was asked.
class _FakeGitHub {
  _FakeGitHub(this.answers);

  final List<FutureOr<ReleasesResponse> Function()> answers;
  final etagsSent = <String?>[];

  Future<ReleasesResponse> fetch({String? etag}) async {
    etagsSent.add(etag);
    return answers.removeAt(0)();
  }
}

ProviderContainer _container(
  _FakeGitHub github, {
  ReleaseVersion? installed,
}) {
  final c = ProviderContainer(overrides: [
    releasesFetcherProvider.overrideWithValue(github.fetch),
    installedVersionProvider.overrideWithValue(installed ??
        ReleaseVersion.tryParseTag('v27H1-preview.20261105.56')!),
    updateCheckClockProvider.overrideWithValue(() => _now),
  ]);
  addTearDown(c.dispose);
  // Keep the checker alive between reads, as the app's listener will.
  c.listen(updateCheckerProvider, (_, _) {});
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('nextUpdateCheckDelay', () {
    test('never checked: now, or after the startup delay', () {
      expect(nextUpdateCheckDelay(now: _now), Duration.zero);
      expect(
          nextUpdateCheckDelay(now: _now, minimum: kUpdateCheckStartupDelay),
          kUpdateCheckStartupDelay);
    });

    // A restart soon after a check does not check again.
    test('checked recently: when the interval is up', () {
      expect(
        nextUpdateCheckDelay(
            now: _now, lastChecked: _now.subtract(const Duration(hours: 2))),
        const Duration(hours: 10),
      );
    });

    test('overdue: now', () {
      expect(
        nextUpdateCheckDelay(
            now: _now, lastChecked: _now.subtract(const Duration(days: 3))),
        Duration.zero,
      );
    });

    test('failed since the last success: after the retry delay', () {
      expect(
        nextUpdateCheckDelay(
          now: _now,
          lastChecked: _now.subtract(const Duration(days: 1)),
          lastFailed: _now,
        ),
        kUpdateCheckRetryDelay,
      );
    });

    test('a clock set back does not postpone past one interval', () {
      expect(
        nextUpdateCheckDelay(
            now: _now, lastChecked: _now.add(const Duration(days: 30))),
        kUpdateCheckInterval,
      );
    });
  });

  group('checker', () {
    test('a check finds the newer preview', () async {
      final github = _FakeGitHub([
        () => ReleasesFetched([
              _release('v27H1-preview.20261112.57'),
              _release('v27H1-preview.20261105.56'),
            ], '"etag-1"'),
      ]);
      final c = _container(github);
      await c.read(updateCheckerProvider.notifier).checkNow();

      final state = c.read(updateCheckerProvider);
      expect(state.result!.available!.release.tag, 'v27H1-preview.20261112.57');
      expect(state.lastChecked, _now);
      expect(state.lastError, isNull);
      expect(state.checking, isFalse);
      expect(github.etagsSent, [null]);
    });

    test('an unchanged list is a 304 and keeps the result', () async {
      final github = _FakeGitHub([
        () => ReleasesFetched(
            [_release('v27H1-preview.20261112.57')], '"etag-1"'),
        () => const ReleasesNotModified(),
      ]);
      final c = _container(github);
      final checker = c.read(updateCheckerProvider.notifier);
      await checker.checkNow();
      await checker.checkNow();

      expect(github.etagsSent, [null, '"etag-1"']);
      expect(c.read(updateCheckerProvider).result!.available!.release.tag,
          'v27H1-preview.20261112.57');
    });

    test('a restart starts from the stored list, without a request', () async {
      await _container(_FakeGitHub([
        () => ReleasesFetched(
            [_release('v27H1-preview.20261112.57')], '"etag-1"'),
      ])).read(updateCheckerProvider.notifier).checkNow();

      final github = _FakeGitHub([() => const ReleasesNotModified()]);
      final c = _container(github);
      await c.read(updateCheckerProvider.notifier).loaded;

      final state = c.read(updateCheckerProvider);
      expect(state.result!.available!.release.tag, 'v27H1-preview.20261112.57');
      expect(state.lastChecked, _now);
      expect(github.etagsSent, isEmpty);

      // And the stored ETag goes out with the next check.
      await c.read(updateCheckerProvider.notifier).checkNow();
      expect(github.etagsSent, ['"etag-1"']);
    });

    test('changing channel re-evaluates without a request', () async {
      final github = _FakeGitHub([
        () => ReleasesFetched([
              _release('v27H1-preview.20261112.57'),
              _release('v26H2u1'),
            ], null),
      ]);
      final c = _container(github);
      await c.read(updateCheckerProvider.notifier).checkNow();
      expect(c.read(updateCheckerProvider).result!.available, isNotNull);

      await c
          .read(updateChannelProvider.notifier)
          .setChannel(ReleaseChannel.stable);
      expect(c.read(updateCheckerProvider).result!.available, isNull);
      expect(github.etagsSent, hasLength(1));
    });

    test('a failure is recorded and keeps the last result', () async {
      final github = _FakeGitHub([
        () => ReleasesFetched(
            [_release('v27H1-preview.20261112.57')], '"etag-1"'),
        () => throw const SocketException('Network is unreachable'),
      ]);
      final c = _container(github);
      final checker = c.read(updateCheckerProvider.notifier);
      await checker.checkNow();
      await checker.checkNow();

      final state = c.read(updateCheckerProvider);
      expect(state.lastError, isA<SocketException>());
      expect(state.result!.available!.release.tag, 'v27H1-preview.20261112.57');
      expect(state.checking, isFalse);
    });

    test('concurrent checks share one request', () async {
      final answer = Completer<ReleasesResponse>();
      final github = _FakeGitHub([() => answer.future]);
      final c = _container(github);
      final checker = c.read(updateCheckerProvider.notifier);
      final first = checker.checkNow();
      final second = checker.checkNow();
      await Future<void>.delayed(Duration.zero);
      expect(c.read(updateCheckerProvider).checking, isTrue);

      answer.complete(ReleasesFetched(const [], null));
      await Future.wait([first, second]);
      expect(github.etagsSent, hasLength(1));
    });
  });

  group('preferences', () {
    test('checking is on by default', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(updateCheckEnabledProvider);
      await c.read(updateCheckEnabledProvider.notifier).loaded;
      expect(c.read(updateCheckEnabledProvider), isTrue);
    });

    // Nothing stored: whoever upgrades from a preview to a stable build is
    // moved to the stable channel along with it.
    test('the channel follows the installed build until one is picked',
        () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(updateChannelProvider);
      await c.read(updateChannelProvider.notifier).loaded;
      expect(c.read(updateChannelProvider), kChannel);
      expect((await SharedPreferences.getInstance()).getString('update_channel'),
          isNull);
    });

    test('a picked channel and the switch are stored', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await c
          .read(updateChannelProvider.notifier)
          .setChannel(ReleaseChannel.stable);
      await c.read(updateCheckEnabledProvider.notifier).setEnabled(false);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('update_channel'), 'stable');
      expect(prefs.getBool('update_check_enabled'), isFalse);
    });

    test('an unknown stored channel falls back to the default', () {
      expect(parseUpdateChannel('beta'), isNull);
      expect(parseUpdateChannel(null), isNull);
      expect(parseUpdateChannel('preview'), ReleaseChannel.preview);
    });
  });

  group('cache', () {
    test('round-trips', () {
      final cache = decodeUpdateCheckCache(encodeUpdateCheckCache(
        UpdateCheckCache(
          releases: [_release('v27H1')],
          etag: '"e"',
          checkedAt: _now,
        ),
      ))!;
      expect(cache.releases.single.tag, 'v27H1');
      expect(cache.etag, '"e"');
      expect(cache.checkedAt, _now);
    });

    test('anything unreadable is no cache', () {
      for (final stored in ['', 'not json', '{}', '[]',
        '{"checkedAt": "yesterday", "etag": null, "releases": []}']) {
        expect(decodeUpdateCheckCache(stored), isNull, reason: stored);
      }
    });

    test('a stored page off the repository is dropped', () {
      final cache = decodeUpdateCheckCache(
          '{"checkedAt": "2026-11-06T12:00:00.000Z", "etag": null, '
          '"releases": [{"tag": "v27H1", "prerelease": false, '
          '"url": "https://evil.example/"}]}')!;
      expect(cache.releases, isEmpty);
    });
  });
}
