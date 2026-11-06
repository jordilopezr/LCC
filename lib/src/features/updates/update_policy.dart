import 'package:linux_cloud_connector/src/features/updates/release_version.dart';
import 'package:linux_cloud_connector/src/version.dart';

/// A published (non-draft) GitHub release, as far as the update policy needs
/// to know it.
class PublishedRelease {
  const PublishedRelease({
    required this.tag,
    required this.prerelease,
    required this.htmlUrl,
  });

  final String tag;

  /// GitHub's "pre-release" flag.
  final bool prerelease;

  /// The release page, which the notice links to.
  final String htmlUrl;
}

/// A release the policy considered: its version, read from the tag, and the
/// channel it is offered on.
class ReleaseCandidate {
  const ReleaseCandidate(this.release, this.version, this.channel);

  final PublishedRelease release;
  final ReleaseVersion version;

  /// Preview if either the tag or GitHub's flag says so. The workflow sets
  /// both from the same tag, so they only disagree if the pre-release box was
  /// changed by hand on publishing; then the release is kept away from
  /// stable-channel users rather than offered to them by mistake.
  final ReleaseChannel channel;
}

/// What the update check found.
class UpdateCheckResult {
  const UpdateCheckResult({
    required this.available,
    required this.newerStable,
    required this.installedUnsupported,
  });

  /// The newest release on the selected channel, if newer than the installed
  /// build. Null when up to date.
  final ReleaseCandidate? available;

  /// The newest stable release, when it is newer than the installed build and
  /// [available] is a preview: lets a preview user see that the edition they
  /// are testing has shipped, and that they could switch to stable.
  final ReleaseCandidate? newerStable;

  /// The installed build is a stable edition that gets no more security
  /// patches, because a later edition has shipped stable. The notice is then
  /// stronger and cannot be skipped for good.
  final bool installedUnsupported;
}

/// Decides what to tell the user, given the releases published on GitHub.
///
/// [channel] is the one selected in Settings, which may differ from the
/// installed build's: a preview user who switched to stable is offered only
/// stables, and none until a stable newer than their preview ships.
///
/// Releases whose tag predates the versioning scheme are ignored.
UpdateCheckResult evaluateUpdate({
  required ReleaseVersion installed,
  required ReleaseChannel channel,
  required Iterable<PublishedRelease> releases,
}) {
  ReleaseCandidate? newest;
  ReleaseCandidate? newestStable;

  for (final release in releases) {
    final version = ReleaseVersion.tryParseTag(release.tag);
    if (version == null) continue;
    final candidate = ReleaseCandidate(
      release,
      version,
      release.prerelease ? ReleaseChannel.preview : version.channel,
    );

    if (candidate.channel == ReleaseChannel.stable &&
        (newestStable == null || version > newestStable.version)) {
      newestStable = candidate;
    }
    final visible = channel == ReleaseChannel.preview ||
        candidate.channel == ReleaseChannel.stable;
    if (visible && (newest == null || version > newest.version)) {
      newest = candidate;
    }
  }

  final available =
      newest != null && newest.version > installed ? newest : null;
  final newerStable = available != null &&
          available.channel == ReleaseChannel.preview &&
          newestStable != null &&
          newestStable.version > installed
      ? newestStable
      : null;
  final installedUnsupported = installed.channel == ReleaseChannel.stable &&
      newestStable != null &&
      newestStable.version.compareEdition(installed) > 0;

  return UpdateCheckResult(
    available: available,
    newerStable: newerStable,
    installedUnsupported: installedUnsupported,
  );
}
