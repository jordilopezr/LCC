/// Single source of truth for the public-facing version shown in the UI.
///
/// These are the *marketing* identifiers (edition line, update number, build
/// stamp) displayed in the About/Settings panels. They are intentionally
/// decoupled from the internal pubspec semver (`version:` in pubspec.yaml),
/// which is never shown to users. Bump these here — and only here — per
/// release; every display reads from this file, so the values cannot drift
/// out of sync across screens.
library;

/// Half-year edition line (YYH#). e.g. '26H2' = second half of 2026.
const String kEdition = '26H2';

/// Update/patch number within the edition. 0 = base edition (no update chip);
/// 1+ renders as "Update N" next to the edition.
const int kUpdate = 1;

/// Build stamp (YYYYMMDD.n).
const String kBuild = '20260731.1';
