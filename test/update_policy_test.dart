import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/src/features/updates/release_version.dart';
import 'package:linux_cloud_connector/src/features/updates/update_policy.dart';
import 'package:linux_cloud_connector/src/version.dart';

PublishedRelease _release(String tag, {bool? prerelease}) => PublishedRelease(
      tag: tag,
      prerelease: prerelease ?? tag.contains('-preview.'),
      htmlUrl: 'https://github.com/jordilopezr/LCC/releases/tag/$tag',
    );

// The releases on GitHub when the checker was written (2026-11-06), legacy
// tags included.
final _today = [
  _release('v27H1-preview.20261105.56'),
  _release('v27H1-preview.20261105.55'),
  _release('v27H1-preview.20261104.54'),
  _release('v27H1-preview.20261012.50'),
  _release('v26H2u1'),
  _release('26H2'),
];

final _preview56 = ReleaseVersion.tryParseTag('v27H1-preview.20261105.56')!;

ReleaseVersion _stable(String edition, int update) => ReleaseVersion.fromValues(
      edition: edition,
      update: update,
      channel: ReleaseChannel.stable,
      build: '20261120.60',
    );

UpdateCheckResult _check(
  ReleaseVersion installed,
  ReleaseChannel channel,
  List<PublishedRelease> releases,
) =>
    evaluateUpdate(installed: installed, channel: channel, releases: releases);

void main() {
  group('preview build', () {
    test('up to date with the newest preview', () {
      final r = _check(_preview56, ReleaseChannel.preview, _today);
      expect(r.available, isNull);
      expect(r.installedUnsupported, isFalse);
    });

    test('offered the next preview iteration', () {
      final r = _check(_preview56, ReleaseChannel.preview,
          [..._today, _release('v27H1-preview.20261112.57')]);
      expect(r.available!.release.tag, 'v27H1-preview.20261112.57');
      expect(r.newerStable, isNull);
    });

    test('offered the stable of its edition when it ships', () {
      final r = _check(
          _preview56, ReleaseChannel.preview, [..._today, _release('v27H1')]);
      expect(r.available!.release.tag, 'v27H1');
      expect(r.newerStable, isNull);
    });

    test('offered the next edition preview, and told the stable shipped', () {
      final r = _check(_preview56, ReleaseChannel.preview, [
        ..._today,
        _release('v27H1'),
        _release('v27H2-preview.20261201.60'),
      ]);
      expect(r.available!.release.tag, 'v27H2-preview.20261201.60');
      expect(r.newerStable!.release.tag, 'v27H1');
    });

    // A preview user who switched to stable: 26H2u1 is older than their
    // preview, so nothing until 27H1 ships stable.
    test('on the stable channel, nothing until a newer stable ships', () {
      expect(_check(_preview56, ReleaseChannel.stable, _today).available,
          isNull);
      expect(
        _check(_preview56, ReleaseChannel.stable, [
          ..._today,
          _release('v27H1-preview.20261112.57'),
        ]).available,
        isNull,
      );
      expect(
        _check(_preview56, ReleaseChannel.stable, [..._today, _release('v27H1')])
            .available!
            .release
            .tag,
        'v27H1',
      );
    });

    test('a preview is never unsupported', () {
      final r = _check(_preview56, ReleaseChannel.preview,
          [..._today, _release('v27H1'), _release('v27H2')]);
      expect(r.installedUnsupported, isFalse);
    });
  });

  group('stable build', () {
    final releases = [
      ..._today,
      _release('v27H1'),
      _release('v27H1u1'),
      _release('v27H2-preview.20261201.60'),
    ];

    test('up to date with its own release', () {
      final r = _check(_stable('27H1', 1), ReleaseChannel.stable, releases);
      expect(r.available, isNull);
      expect(r.installedUnsupported, isFalse);
    });

    test('offered the next security patch, not the next edition preview', () {
      final r = _check(_stable('27H1', 1), ReleaseChannel.stable,
          [...releases, _release('v27H1u2')]);
      expect(r.available!.release.tag, 'v27H1u2');
      expect(r.installedUnsupported, isFalse);
    });

    test('unsupported once the next edition ships stable', () {
      final r = _check(_stable('27H1', 1), ReleaseChannel.stable,
          [...releases, _release('v27H2')]);
      expect(r.available!.release.tag, 'v27H2');
      expect(r.installedUnsupported, isTrue);
    });

    test('on the preview channel, offered the next edition preview', () {
      final r = _check(_stable('27H1', 1), ReleaseChannel.preview, releases);
      expect(r.available!.release.tag, 'v27H2-preview.20261201.60');
      expect(r.newerStable, isNull);
      expect(r.installedUnsupported, isFalse);
    });
  });

  group('trust', () {
    // The pre-release box unticked by hand on a preview, or ticked on a
    // stable: either way the release stays off the stable channel.
    test('a release either the tag or GitHub calls preview is a preview', () {
      final installed = _stable('26H2', 1);
      expect(
        _check(installed, ReleaseChannel.stable,
            [_release('v27H1', prerelease: true)]).available,
        isNull,
      );
      expect(
        _check(installed, ReleaseChannel.stable,
            [_release('v27H1-preview.20261105.56', prerelease: false)])
            .available,
        isNull,
      );
      expect(
        _check(installed, ReleaseChannel.preview,
                [_release('v27H1', prerelease: true)])
            .available!
            .channel,
        ReleaseChannel.preview,
      );
    });

    // A stable marked pre-release has not shipped as far as the policy is
    // concerned, so it does not close the installed edition either.
    test('a stable marked pre-release does not make the installed unsupported',
        () {
      final r = _check(_stable('26H2', 1), ReleaseChannel.preview,
          [_release('v27H1', prerelease: true)]);
      expect(r.installedUnsupported, isFalse);
    });

    test('tags outside the scheme are ignored', () {
      final r = _check(_stable('26H2', 1), ReleaseChannel.stable,
          [_release('v26H2u1-rc2'), _release('v99.0.0')]);
      expect(r.available, isNull);
    });
  });
}
