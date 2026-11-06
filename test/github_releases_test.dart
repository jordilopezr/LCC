import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/src/features/updates/github_releases.dart';

Map<String, Object?> _entry(
  String tag, {
  bool prerelease = false,
  bool draft = false,
  String? htmlUrl,
}) =>
    {
      'tag_name': tag,
      'prerelease': prerelease,
      'draft': draft,
      'html_url': htmlUrl ?? '$kReleasesPagePrefix' 'tag/$tag',
      // The API sends much more; none of it is read.
      'assets': [
        {'name': 'lightweight-cloud-connector_${tag}_amd64.deb'},
      ],
      'body': '## Notes',
    };

void main() {
  group('parseReleases', () {
    test('reads tag, pre-release flag and page of each release', () {
      final releases = parseReleases(jsonEncode([
        _entry('v27H1-preview.20261105.56', prerelease: true),
        _entry('v26H2u1'),
      ]));
      expect(releases.map((r) => r.tag),
          ['v27H1-preview.20261105.56', 'v26H2u1']);
      expect(releases.map((r) => r.prerelease), [true, false]);
      expect(releases.first.htmlUrl,
          'https://github.com/jordilopezr/LCC/releases/tag/v27H1-preview.20261105.56');
    });

    test('drafts are not releases', () {
      expect(parseReleases(jsonEncode([_entry('v27H1', draft: true)])), isEmpty);
    });

    // The notice opens html_url; it must not lead off the repository.
    test('a release whose page is elsewhere is dropped', () {
      for (final url in [
        'https://evil.example/jordilopezr/LCC/releases/tag/v27H1',
        'https://github.com/someone-else/LCC/releases/tag/v27H1',
        'http://github.com/jordilopezr/LCC/releases/tag/v27H1',
        'https://github.com.evil.example/jordilopezr/LCC/releases/tag/v27H1',
      ]) {
        expect(parseReleases(jsonEncode([_entry('v27H1', htmlUrl: url)])),
            isEmpty,
            reason: url);
      }
    });

    test('an entry missing a field is skipped, not fatal', () {
      final releases = parseReleases(jsonEncode([
        {'tag_name': 'v27H1', 'draft': false},
        {'tag_name': 42, 'prerelease': false, 'draft': false, 'html_url': ''},
        'not an object',
        _entry('v26H2u1'),
      ]));
      expect(releases.map((r) => r.tag), ['v26H2u1']);
    });

    test('a body that is not a list fails', () {
      expect(() => parseReleases('{"message": "API rate limit exceeded"}'),
          throwsFormatException);
      expect(() => parseReleases('<html>'), throwsFormatException);
    });
  });
}
