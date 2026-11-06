import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/src/features/updates/release_version.dart';
import 'package:linux_cloud_connector/src/version.dart';

ReleaseVersion _v(String tag) => ReleaseVersion.tryParseTag(tag)!;

void main() {
  group('tryParseTag', () {
    test('a preview tag carries edition and build', () {
      final v = _v('v27H1-preview.20261105.56');
      expect(v.edition, '27H1');
      expect(v.channel, ReleaseChannel.preview);
      expect(v.update, 0);
      expect(v.build, const BuildStamp(20261105, 56));
    });

    test('a stable tag carries edition and update, but no build', () {
      final base = _v('v27H1');
      expect(base.channel, ReleaseChannel.stable);
      expect(base.update, 0);
      expect(base.build, isNull);
      expect(_v('v27H1u2').update, 2);
    });

    // The first stable was tagged without the v.
    test('the leading v is optional', () {
      expect(_v('26H2'), _v('v26H2'));
    });

    test('tags outside the scheme are not versions', () {
      for (final tag in [
        'v26H2u1-rc2',
        'v27H3',
        'v27H1u0',
        'v27H1u01',
        'v27H1-preview.20261105.056',
        'v27H1-preview.2026110.56',
        'v27H1u1-preview.20261105.56',
        'v3.0.0',
        '',
      ]) {
        expect(ReleaseVersion.tryParseTag(tag), isNull, reason: tag);
      }
    });

    test('tag gives the tag back', () {
      for (final tag in ['v27H1-preview.20261105.56', 'v27H1', 'v27H1u2']) {
        expect(_v(tag).tag, tag);
      }
    });
  });

  group('ordering', () {
    test('edition, then preview before stable, then update, then build', () {
      const ordered = [
        'v26H2',
        'v26H2u1',
        'v27H1-preview.20261105.56',
        'v27H1-preview.20261112.57',
        'v27H1',
        'v27H1u1',
        'v27H1u2',
        'v27H2-preview.20261201.60',
        'v27H2',
        'v28H1-preview.20270101.70',
      ];
      final shuffled = ordered.map(_v).toList()..shuffle();
      shuffled.sort();
      expect(shuffled.map((v) => v.tag), ordered.map((t) => _v(t).tag));
    });

    test('the build sequence compares as a number', () {
      expect(_v('v27H1-preview.20261105.10') > _v('v27H1-preview.20261105.9'),
          isTrue);
    });

    // An installed stable knows its build; its tag does not. They are still
    // the same version, or the checker would offer a stable its own release.
    test('a stable with a known build equals its tag', () {
      final installed = ReleaseVersion.fromValues(
        edition: '27H1',
        update: 1,
        channel: ReleaseChannel.stable,
        build: '20261120.60',
      );
      expect(installed, _v('v27H1u1'));
      expect(installed.hashCode, _v('v27H1u1').hashCode);
      expect(installed.compareTo(_v('v27H1u1')), 0);
    });
  });

  group('installed', () {
    // The Release workflow builds the tag from version.dart, so the installed
    // version must read back as that same tag.
    test('version.dart is a well-formed version whose tag parses back', () {
      final installed = ReleaseVersion.installed;
      expect(installed.edition, kEdition);
      expect(installed.channel, kChannel);
      expect(installed.update, kUpdate);
      expect(installed.build.toString(), kBuild);
      expect(ReleaseVersion.tryParseTag(installed.tag), installed);
    });

    test('a preview with an update is malformed', () {
      expect(
        () => ReleaseVersion.fromValues(
          edition: '27H1',
          update: 1,
          channel: ReleaseChannel.preview,
          build: '20261105.56',
        ),
        throwsFormatException,
      );
    });
  });
}
