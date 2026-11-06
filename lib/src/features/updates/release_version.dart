import 'package:linux_cloud_connector/src/version.dart';

/// A release version as the update checker sees it: read from a release tag,
/// or from version.dart for the installed build.
///
/// Tags follow the scheme the Release workflow enforces
/// (scripts/check_release_version.sh):
///
/// ```text
/// preview  v<edition>-preview.<build>   v27H1-preview.20261105.56
/// stable   v<edition>[u<update>]        v27H1, v27H1u2
/// ```
///
/// Ordering is edition, then channel (an edition's previews come before its
/// stable), then update, then build. A stable tag carries no build: stables
/// keep their edition's build across updates, so it never decides their order,
/// and two stables of the same edition and update are the same version even if
/// only one of them knows its build.
class ReleaseVersion implements Comparable<ReleaseVersion> {
  ReleaseVersion._({
    required this.editionYear,
    required this.editionHalf,
    required this.update,
    required this.channel,
    required this.build,
  });

  /// Two-digit year of the edition: 27 in 27H1.
  final int editionYear;

  /// Half of the year: 1 or 2.
  final int editionHalf;

  /// Security patch number within a stable edition; always 0 on a preview.
  final int update;

  final ReleaseChannel channel;

  /// Build stamp. Null on a version read from a stable tag.
  final BuildStamp? build;

  static final _previewTag =
      RegExp(r'^v?(\d{2})H([12])-preview\.(\d{8})\.(0|[1-9]\d*)$');
  static final _stableTag = RegExp(r'^v?(\d{2})H([12])(?:u([1-9]\d*))?$');
  static final _edition = RegExp(r'^(\d{2})H([12])$');

  /// The version a release tag names, or null if the tag predates the scheme
  /// (such as `v26H2u1-rc2`). The leading `v` is optional, as on the first
  /// stable tag, `26H2`.
  static ReleaseVersion? tryParseTag(String tag) {
    final preview = _previewTag.firstMatch(tag);
    if (preview != null) {
      return ReleaseVersion._(
        editionYear: int.parse(preview[1]!),
        editionHalf: int.parse(preview[2]!),
        update: 0,
        channel: ReleaseChannel.preview,
        build: BuildStamp(int.parse(preview[3]!), int.parse(preview[4]!)),
      );
    }
    final stable = _stableTag.firstMatch(tag);
    if (stable != null) {
      return ReleaseVersion._(
        editionYear: int.parse(stable[1]!),
        editionHalf: int.parse(stable[2]!),
        update: stable[3] == null ? 0 : int.parse(stable[3]!),
        channel: ReleaseChannel.stable,
        build: null,
      );
    }
    return null;
  }

  /// The installed build, from version.dart.
  ///
  /// Throws if version.dart is malformed. The Release workflow refuses to
  /// build a release whose version.dart does not parse, and a test pins this
  /// getter, so that is a development error rather than something a user
  /// can hit.
  static final ReleaseVersion installed = fromValues(
    edition: kEdition,
    update: kUpdate,
    channel: kChannel,
    build: kBuild,
  );

  /// A version from the values version.dart declares.
  static ReleaseVersion fromValues({
    required String edition,
    required int update,
    required ReleaseChannel channel,
    required String build,
  }) {
    final e = _edition.firstMatch(edition);
    if (e == null) throw FormatException('Not an edition (YYH1/YYH2)', edition);
    if (update < 0 || (channel == ReleaseChannel.preview && update != 0)) {
      throw FormatException('Invalid update for a $channel build', update);
    }
    return ReleaseVersion._(
      editionYear: int.parse(e[1]!),
      editionHalf: int.parse(e[2]!),
      update: update,
      channel: channel,
      build: BuildStamp.parse(build),
    );
  }

  /// '27H1'.
  String get edition => '${editionYear.toString().padLeft(2, '0')}H$editionHalf';

  /// The tag this version is released under.
  String get tag => switch (channel) {
        ReleaseChannel.preview => 'v$edition-preview.$build',
        ReleaseChannel.stable => update == 0 ? 'v$edition' : 'v${edition}u$update',
      };

  /// Compares editions only: negative if this edition is older than [other]'s.
  int compareEdition(ReleaseVersion other) {
    final byYear = editionYear.compareTo(other.editionYear);
    return byYear != 0 ? byYear : editionHalf.compareTo(other.editionHalf);
  }

  @override
  int compareTo(ReleaseVersion other) {
    final byEdition = compareEdition(other);
    if (byEdition != 0) return byEdition;
    final byChannel = channel.index.compareTo(other.channel.index);
    if (byChannel != 0) return byChannel;
    final byUpdate = update.compareTo(other.update);
    if (byUpdate != 0) return byUpdate;
    if (channel == ReleaseChannel.stable) return 0;
    return build!.compareTo(other.build!);
  }

  bool operator >(ReleaseVersion other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is ReleaseVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(editionYear, editionHalf, channel, update,
      channel == ReleaseChannel.preview ? build : null);

  @override
  String toString() => tag;
}

/// A build stamp, YYYYMMDD.n. Its two parts compare as numbers, so
/// 20261105.9 comes before 20261105.10.
class BuildStamp implements Comparable<BuildStamp> {
  const BuildStamp(this.date, this.sequence);

  final int date;
  final int sequence;

  static final _pattern = RegExp(r'^(\d{8})\.(0|[1-9]\d*)$');

  static BuildStamp parse(String stamp) {
    final m = _pattern.firstMatch(stamp);
    if (m == null) throw FormatException('Not a build stamp (YYYYMMDD.n)', stamp);
    return BuildStamp(int.parse(m[1]!), int.parse(m[2]!));
  }

  @override
  int compareTo(BuildStamp other) {
    final byDate = date.compareTo(other.date);
    return byDate != 0 ? byDate : sequence.compareTo(other.sequence);
  }

  @override
  bool operator ==(Object other) =>
      other is BuildStamp && date == other.date && sequence == other.sequence;

  @override
  int get hashCode => Object.hash(date, sequence);

  @override
  String toString() => '${date.toString().padLeft(8, '0')}.$sequence';
}
