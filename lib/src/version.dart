/// Single source of truth for the public-facing version shown in the UI.
///
/// These are the *marketing* identifiers (edition line, update number, build
/// stamp) displayed in the About/Settings panels. They are intentionally
/// decoupled from the internal pubspec semver (`version:` in pubspec.yaml),
/// which is never shown to users. Bump these here — and only here — per
/// release; every display reads from this file, so the values cannot drift
/// out of sync across screens.
///
/// The release tag is derived from these values, and the Release workflow
/// refuses a tag that does not match them (scripts/check_release_version.sh):
///
/// ```text
/// preview  v<edition>-preview.<build>   v27H1-preview.20261105.56
/// stable   v<edition>[u<update>]        v27H1, v27H1u2
/// ```
///
/// Lifecycle, which the same script enforces against the published releases:
/// - A preview iteration bumps [kBuild]; [kUpdate] stays 0.
/// - A stable security patch bumps [kUpdate]; [kBuild] stays that of the
///   edition's first stable.
/// - Once an edition ships stable, previews move to the next edition, and the
///   previous stable edition gets no more patches.
library;

/// Which line a build belongs to. The update checker compares edition, then
/// channel (preview < stable within an edition), then update, then build.
///
/// Declaration order is that channel order: keep preview first.
enum ReleaseChannel { preview, stable }

/// Half-year edition line (YYH#). e.g. '26H2' = second half of 2026.
const String kEdition = '27H1';

/// Update/patch number within the edition. 0 = base edition (no update chip);
/// 1+ renders as "Update N" next to the edition. Always 0 on a preview.
const int kUpdate = 0;

/// Release channel of this build.
const ReleaseChannel kChannel = ReleaseChannel.preview;

/// Build stamp (YYYYMMDD.n).
const String kBuild = '20261105.56';

/// One-line, non-localized version for logs and diagnostics.
///
/// Deliberately not translated: it is read by whoever is reading a log file,
/// and it has to match what Settings shows so the two can be compared.
String versionLine() => kUpdate > 0
    ? '$kEdition Update $kUpdate build $kBuild'
    : '$kEdition build $kBuild';
