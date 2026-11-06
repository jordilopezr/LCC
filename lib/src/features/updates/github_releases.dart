import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:linux_cloud_connector/src/features/updates/update_policy.dart';

/// The repository whose releases the update checker reads.
const kReleasesRepo = 'jordilopezr/LCC';

/// Every published release page lives under this prefix. A release whose
/// html_url does not is dropped: the notice opens that URL, and it must not
/// be able to point anywhere else.
const kReleasesPagePrefix = 'https://github.com/$kReleasesRepo/releases/';

/// One page, as large as the API allows, newest first. It has to reach back
/// to the current stable: previews of the next edition keep coming after it,
/// and a stable user is only offered — or told they are unsupported — if the
/// newest stable is on the page.
final kReleasesApiUri = Uri.parse(
    'https://api.github.com/repos/$kReleasesRepo/releases?per_page=100');

/// A release list is a few hundred kilobytes; anything far past that is not
/// what the API returns, and is not read into memory.
const _maxResponseBytes = 8 * 1024 * 1024;

const _connectTimeout = Duration(seconds: 10);
const _totalTimeout = Duration(seconds: 30);

/// What a request for the release list came back with.
sealed class ReleasesResponse {
  const ReleasesResponse();
}

/// 304: the list has not changed since the response with this ETag.
class ReleasesNotModified extends ReleasesResponse {
  const ReleasesNotModified();
}

class ReleasesFetched extends ReleasesResponse {
  const ReleasesFetched(this.releases, this.etag);

  final List<PublishedRelease> releases;

  /// Sent back on the next request, so an unchanged list costs a 304 rather
  /// than the whole page. Null if GitHub sent none.
  final String? etag;
}

/// Fetches the release list. [etag] is the ETag of the list already held, if
/// any.
typedef ReleasesFetcher = Future<ReleasesResponse> Function({String? etag});

/// [ReleasesFetcher] against the GitHub REST API, unauthenticated: the
/// repository is public, and 60 requests an hour per IP is far more than a
/// check every few hours needs.
///
/// Honours `https_proxy` / `no_proxy` from the environment, which dart:io does
/// not do on its own; behind a corporate proxy the check would otherwise
/// always fail.
Future<ReleasesResponse> fetchReleasesFromGitHub({String? etag}) async {
  final client = HttpClient()
    ..connectionTimeout = _connectTimeout
    ..findProxy = HttpClient.findProxyFromEnvironment;
  try {
    return await _fetch(client, etag).timeout(_totalTimeout);
  } finally {
    client.close(force: true);
  }
}

Future<ReleasesResponse> _fetch(HttpClient client, String? etag) async {
  final request = await client.getUrl(kReleasesApiUri);
  request.headers
    ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
    ..set('X-GitHub-Api-Version', '2022-11-28')
    // GitHub rejects requests without one. No version in it: the check
    // should not tell anyone more than that it happened.
    ..set(HttpHeaders.userAgentHeader, 'Lightweight-Cloud-Connector');
  if (etag != null) request.headers.set(HttpHeaders.ifNoneMatchHeader, etag);

  final response = await request.close();
  if (response.statusCode == HttpStatus.notModified) {
    await response.drain<void>();
    return const ReleasesNotModified();
  }
  if (response.statusCode != HttpStatus.ok) {
    await response.drain<void>();
    throw HttpException('GitHub answered ${response.statusCode}',
        uri: kReleasesApiUri);
  }

  final bytes = <int>[];
  await for (final chunk in response) {
    bytes.addAll(chunk);
    if (bytes.length > _maxResponseBytes) {
      throw HttpException('Release list larger than $_maxResponseBytes bytes',
          uri: kReleasesApiUri);
    }
  }
  return ReleasesFetched(
    parseReleases(utf8.decode(bytes)),
    response.headers.value(HttpHeaders.etagHeader),
  );
}

/// The published releases in a GitHub release-list response.
///
/// Drafts (which the unauthenticated API does not return anyway) and entries
/// missing a field are skipped rather than failing the whole list, as is any
/// release whose page is not under [kReleasesPagePrefix]. Throws
/// [FormatException] if the body is not a JSON list at all.
List<PublishedRelease> parseReleases(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! List) {
    throw const FormatException('Release list is not a JSON array');
  }
  return [
    for (final entry in decoded)
      if (entry case {
            'tag_name': final String tag,
            'prerelease': final bool prerelease,
            'draft': false,
            'html_url': final String htmlUrl,
          } when htmlUrl.startsWith(kReleasesPagePrefix))
        PublishedRelease(tag: tag, prerelease: prerelease, htmlUrl: htmlUrl),
  ];
}
