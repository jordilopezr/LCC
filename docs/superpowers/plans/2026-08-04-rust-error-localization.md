# Rust Error Localization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Localize the errors that reach the user from the Rust layer by classifying any error into a curated `AppErrorCode` and rendering a translated message, with a generic fallback that keeps the raw detail.

**Architecture:** A single new Dart file `lib/src/features/app_error.dart` holds the taxonomy (`AppErrorCode`), the classifier (`classifyRustError`), and the display helper (`localizedError`). The helper routes typed `TunnelFailure` errors to the existing `tunnelErrorMessage`, and everything else through the classifier. The pre-existing `classifyGcpError`/`GcpErrorType` are absorbed into this taxonomy. UI call sites stop interpolating the raw `e.toString()` and interpolate `localizedError(...)` instead. Dart-only — no Rust or bridge changes.

**Tech Stack:** Flutter, Dart, flutter gen-l10n (ARB files).

## Global Constraints

- **Dart-only.** No changes to `native/**` or `lib/src/bridge/**`; no `flutter_rust_bridge_codegen` regen.
- **Branch `27H1-Preview`.** Do not push.
- **l10n EN/ES parity:** every new key exists in BOTH `lib/l10n/app_en.arb` and `lib/l10n/app_es.arb`; placeholder metadata (`@key`) goes in the EN template only; run `flutter gen-l10n` after ARB edits (no drift).
- **Known error codes render clean localized text** (no raw English); only `AppErrorCode.unknown` may append the raw detail.
- **Behavior-preserving migration:** removing `GcpErrorType` must not change when the `GcpSessionBanner` appears (`notAuthenticated` still triggers it).
- **These are code commits → NO `Co-Authored-By` trailer.**
- Verify Dart changes with `flutter analyze` (0 errors) and `flutter test`.

## File Structure

- **Create** `lib/src/features/app_error.dart` — `AppErrorCode` enum, `classifyRustError(dynamic) → AppErrorCode`, `localizedError(AppLocalizations, dynamic, {bool standalone}) → String`.
- **Create** `test/app_error_test.dart` — classifier table + `localizedError` behavior.
- **Modify** `lib/src/features/gcloud_provider.dart` — remove `GcpErrorType` + `classifyGcpError`; `AccountState.errorType` becomes `AppErrorCode?`; call sites use `classifyRustError`.
- **Modify** `lib/src/features/gcp_session_banner.dart` — banner trigger uses `classifyRustError(...) == AppErrorCode.notAuthenticated`.
- **Modify** `test/gcp_error_classifier_test.dart` — retarget to `classifyRustError`/`AppErrorCode` (or fold into `app_error_test.dart`).
- **Modify** `lib/l10n/app_en.arb`, `lib/l10n/app_es.arb` — add `appError*` keys.
- **Modify** user-facing call sites (Task 3) — interpolate `localizedError` instead of the raw error.

---

### Task 1: `AppErrorCode` + `classifyRustError` (absorb `classifyGcpError`)

**Files:**
- Create: `lib/src/features/app_error.dart`
- Create: `test/app_error_test.dart`
- Modify: `lib/src/features/gcloud_provider.dart` (remove `GcpErrorType`/`classifyGcpError`; `errorType` field + call sites)
- Modify: `lib/src/features/gcp_session_banner.dart`
- Modify: `test/gcp_error_classifier_test.dart`

**Interfaces:**
- Produces: `enum AppErrorCode { notAuthenticated, permissionDenied, notFound, network, quotaExceeded, gcloudNotInstalled, alreadyExists, invalidInput, cancelled, unknown }` and `AppErrorCode classifyRustError(dynamic e)`.

- [ ] **Step 1: Write the failing classifier test**

Create `test/app_error_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/src/features/app_error.dart';

void main() {
  group('classifyRustError', () {
    final cases = <String, AppErrorCode>{
      'PERMISSION_DENIED: caller lacks permission': AppErrorCode.permissionDenied,
      'Request failed: 403': AppErrorCode.permissionDenied,
      'NOT_FOUND: instance x': AppErrorCode.notFound,
      'HTTP 404': AppErrorCode.notFound,
      'UNAUTHENTICATED': AppErrorCode.notAuthenticated,
      'reauth required: invalid_grant': AppErrorCode.notAuthenticated,
      'Your session has expired': AppErrorCode.notAuthenticated,
      'No active GCP account': AppErrorCode.notAuthenticated,
      'The gcloud CLI is not installed': AppErrorCode.gcloudNotInstalled,
      'gcloud: no such file or directory': AppErrorCode.gcloudNotInstalled,
      'gcloud: command not found': AppErrorCode.gcloudNotInstalled,
      // A wrapped gcloud CLI "resource not found" must be notFound, NOT
      // gcloudNotInstalled (the "gcloud error:" wrapper + "was not found").
      "gcloud error: ERROR: (gcloud.compute.instances.describe) the resource 'x' was not found":
          AppErrorCode.notFound,
      'RESOURCE_EXHAUSTED: quota exceeded': AppErrorCode.quotaExceeded,
      'ALREADY_EXISTS: snapshot name taken': AppErrorCode.alreadyExists,
      'INVALID_ARGUMENT: bad zone': AppErrorCode.invalidInput,
      'connection refused': AppErrorCode.network,
      'UNAVAILABLE: backend': AppErrorCode.network,
      'operation was CANCELLED': AppErrorCode.cancelled,
      'transfer canceled by user': AppErrorCode.cancelled,
      'some totally unmapped failure': AppErrorCode.unknown,
      // Negative cases: a port containing "403"/"404" must NOT be read as a
      // status code (word-boundary matching).
      'failed to bind 127.0.0.1:8403': AppErrorCode.unknown,
      'connection refused 10.0.0.1:8404': AppErrorCode.network,
    };
    cases.forEach((msg, expected) {
      test('"$msg" -> $expected', () {
        expect(classifyRustError(Exception(msg)), expected);
      });
    });
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `flutter test test/app_error_test.dart`
Expected: FAIL — `app_error.dart` / `classifyRustError` not defined.

- [ ] **Step 3: Create `lib/src/features/app_error.dart` with the enum + classifier**

```dart
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import '../bridge/api.dart/api.dart' show TunnelFailure;
import 'tunnel_manager_dialog.dart' show tunnelErrorMessage;

/// Curated taxonomy of errors surfaced to the user from the Rust layer.
enum AppErrorCode {
  notAuthenticated,
  permissionDenied,
  notFound,
  network,
  quotaExceeded,
  gcloudNotInstalled,
  alreadyExists,
  invalidInput,
  cancelled,
  unknown,
}

/// Classify any thrown error into an [AppErrorCode]. Matches stable identifiers
/// (GCP API status codes are constants Google does not translate) and our own
/// anyhow messages. Ordered most-specific-first; falls back to [unknown].
AppErrorCode classifyRustError(dynamic e) {
  final msg = e.toString();
  final lower = msg.toLowerCase();

  // gcloud BINARY missing — strict phrases only. NOT a bare "not found":
  // gcloud CLI errors are wrapped as "gcloud error: <stderr>", and a resource
  // "was not found" would otherwise be misread as "gcloud not installed".
  if (lower.contains('gcloud') &&
      (lower.contains('not installed') ||
          lower.contains('command not found') ||
          lower.contains('no such file'))) {
    return AppErrorCode.gcloudNotInstalled;
  }
  // Numeric HTTP codes are matched with word boundaries so a port or byte
  // count (e.g. "127.0.0.1:8403") cannot be mistaken for a status code.
  if (msg.contains('PERMISSION_DENIED') || RegExp(r'\b403\b').hasMatch(msg)) {
    return AppErrorCode.permissionDenied;
  }
  if (msg.contains('NOT_FOUND') ||
      RegExp(r'\b404\b').hasMatch(msg) ||
      lower.contains('not found')) {
    return AppErrorCode.notFound;
  }
  if (msg.contains('ALREADY_EXISTS') || lower.contains('already exists')) {
    return AppErrorCode.alreadyExists;
  }
  if (msg.contains('INVALID_ARGUMENT')) {
    return AppErrorCode.invalidInput;
  }
  if (msg.contains('UNAUTHENTICATED') || RegExp(r'\b401\b').hasMatch(msg)) {
    return AppErrorCode.notAuthenticated;
  }
  if (msg.contains('RESOURCE_EXHAUSTED') || lower.contains('quota')) {
    return AppErrorCode.quotaExceeded;
  }
  if (msg.contains('CANCELLED') ||
      lower.contains('cancelled') ||
      lower.contains('canceled')) {
    return AppErrorCode.cancelled;
  }
  if (msg.contains('UNAVAILABLE') ||
      lower.contains('network') ||
      lower.contains('timeout') ||
      lower.contains('timed out') ||
      lower.contains('connect')) {
    return AppErrorCode.network;
  }
  // gcloud/ADC re-auth phrasing.
  if (lower.contains('requires reauthentication') ||
      lower.contains('session has expired') ||
      msg.contains('invalid_rapt') ||
      msg.contains('invalid_grant') ||
      msg.contains('No active GCP account')) {
    return AppErrorCode.notAuthenticated;
  }
  return AppErrorCode.unknown;
}
```

- [ ] **Step 4: Run the classifier test to verify it passes**

Run: `flutter test test/app_error_test.dart`
Expected: PASS (all cases). If a case fails, adjust the ordering/needles in `classifyRustError` (not the expected values) until green.

- [ ] **Step 5: Remove `GcpErrorType` + `classifyGcpError` and migrate call sites**

In `lib/src/features/gcloud_provider.dart`:
- Delete the `enum GcpErrorType { ... }` block and the entire `GcpErrorType classifyGcpError(dynamic e) { ... }` function.
- Add `import 'app_error.dart';` near the other feature imports.
- Change `AccountState.errorType` field type, the constructor param, and the `copyWith` param from `GcpErrorType?` to `AppErrorCode?`.
- Replace every `classifyGcpError(` with `classifyRustError(` (find them: `grep -n 'classifyGcpError' lib/src/features/gcloud_provider.dart` — the `errorType: classifyGcpError(e)` sites).

In `lib/src/features/gcp_session_banner.dart` (around line 22), change:
```dart
v.hasError && classifyGcpError(v.error) == GcpErrorType.unauthenticated;
```
to:
```dart
v.hasError && classifyRustError(v.error) == AppErrorCode.notAuthenticated;
```
and update its import from `gcloud_provider.dart` (for the classifier) to `app_error.dart` if needed (keep whatever else it imports from `gcloud_provider.dart`).

Run `grep -rn 'GcpErrorType\|classifyGcpError' lib/` and confirm ZERO remaining references in `lib/` (bridge/gen excluded — they never referenced it).

- [ ] **Step 6: Retarget the existing classifier test**

`test/gcp_error_classifier_test.dart` tests `classifyGcpError`/`GcpErrorType`. Update each reference to `classifyRustError`/`AppErrorCode` and the renamed value `unauthenticated` → `notAuthenticated` (import `package:linux_cloud_connector/src/features/app_error.dart`). Keep its assertions (they still document real cases). Alternatively delete this file if every case it covers is already in `app_error_test.dart` — but do not lose coverage.

- [ ] **Step 7: Verify the migration compiles and tests pass**

Run:
```bash
flutter analyze lib/src/features/app_error.dart lib/src/features/gcloud_provider.dart lib/src/features/gcp_session_banner.dart 2>&1 | tail -5
flutter test test/app_error_test.dart test/gcp_error_classifier_test.dart test/gcp_session_banner_test.dart 2>&1 | tail -4
```
Expected: analyze 0 errors; all listed tests pass (the banner test proves the trigger still fires on an auth error).

- [ ] **Step 8: Commit**

```bash
git add lib/src/features/app_error.dart test/app_error_test.dart lib/src/features/gcloud_provider.dart lib/src/features/gcp_session_banner.dart test/gcp_error_classifier_test.dart
git commit -m "feat(i18n): AppErrorCode + classifyRustError, absorbing classifyGcpError"
```

---

### Task 2: `localizedError` helper + `appError*` l10n keys

**Files:**
- Modify: `lib/src/features/app_error.dart` (add `localizedError`)
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_es.arb`
- Modify: `test/app_error_test.dart` (add `localizedError` group)

**Interfaces:**
- Consumes: `AppErrorCode`, `classifyRustError` (Task 1); `tunnelErrorMessage(AppLocalizations, String)` and `TunnelFailure { String code; String? detail }` (existing).
- Produces: `String localizedError(AppLocalizations l10n, dynamic e, {bool standalone = true})`.

- [ ] **Step 1: Add the `appError*` keys to `lib/l10n/app_en.arb`**

Insert after `"dashboardFilterSuspended": "Suspended",` (or any stable spot):

```json
  "appErrorNotAuthenticated": "Your session expired. Sign in again.",
  "appErrorPermissionDenied": "You don't have permission for this operation.",
  "appErrorNotFound": "The requested resource was not found.",
  "appErrorNetwork": "Network error. Check your connection and try again.",
  "appErrorQuotaExceeded": "Quota exceeded. Try again later or request more quota.",
  "appErrorGcloudNotInstalled": "The gcloud CLI is not installed or was not found.",
  "appErrorAlreadyExists": "That resource already exists.",
  "appErrorInvalidInput": "Invalid input.",
  "appErrorCancelled": "Operation cancelled.",
  "appErrorGeneric": "Operation failed: {detail}",
  "@appErrorGeneric": {
    "placeholders": {
      "detail": {"type": "String"}
    }
  },
```

- [ ] **Step 2: Add the same keys to `lib/l10n/app_es.arb` (values only, no `@` metadata)**

```json
  "appErrorNotAuthenticated": "Tu sesión expiró. Inicia sesión de nuevo.",
  "appErrorPermissionDenied": "No tienes permiso para esta operación.",
  "appErrorNotFound": "No se encontró el recurso solicitado.",
  "appErrorNetwork": "Error de red. Revisa tu conexión e inténtalo de nuevo.",
  "appErrorQuotaExceeded": "Cuota excedida. Inténtalo más tarde o solicita más cuota.",
  "appErrorGcloudNotInstalled": "gcloud CLI no está instalado o no se encontró.",
  "appErrorAlreadyExists": "Ese recurso ya existe.",
  "appErrorInvalidInput": "Entrada inválida.",
  "appErrorCancelled": "Operación cancelada.",
  "appErrorGeneric": "La operación falló: {detail}",
```

- [ ] **Step 3: Regenerate localizations**

Run: `flutter gen-l10n`
Expected: no errors; `l10n/gen/app_localizations.dart` now has getters `appErrorNotAuthenticated` … and `String appErrorGeneric(String detail)`.

- [ ] **Step 4: Write the failing `localizedError` test**

Append to `test/app_error_test.dart` (add imports for `AppLocalizations`, `flutter/widgets.dart`, `TunnelFailure`):

```dart
  group('localizedError', () {
    late AppLocalizations en;
    setUpAll(() async {
      en = await AppLocalizations.delegate.load(const Locale('en'));
    });

    test('TunnelFailure routes to tunnelError* mapping', () {
      final msg = localizedError(en, const TunnelFailure(code: 'permission_denied'));
      expect(msg, en.tunnelErrorPermissionDenied);
    });

    test('known code -> clean localized message', () {
      expect(localizedError(en, Exception('PERMISSION_DENIED')),
          en.appErrorPermissionDenied);
    });

    test('unknown standalone -> generic wrapper with detail', () {
      final msg = localizedError(en, Exception('weird boom'));
      expect(msg, contains('weird boom'));
      expect(msg, en.appErrorGeneric('Exception: weird boom'));
    });

    test('unknown non-standalone -> raw detail only', () {
      final msg = localizedError(en, Exception('weird boom'), standalone: false);
      expect(msg, 'Exception: weird boom');
    });
  });
```

Add these imports at the top of the test file:
```dart
import 'package:flutter/widgets.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import 'package:linux_cloud_connector/src/bridge/api.dart/api.dart' show TunnelFailure;
```

- [ ] **Step 5: Run it to verify it fails**

Run: `flutter test test/app_error_test.dart`
Expected: FAIL — `localizedError` not defined.

- [ ] **Step 6: Implement `localizedError` in `app_error.dart`**

Append to `lib/src/features/app_error.dart`:

```dart
/// Render any error as a localized, user-facing message.
///
/// - `TunnelFailure` (typed) → the existing `tunnelError*` mapping.
/// - A known [AppErrorCode] → a clean localized message.
/// - `unknown` → when [standalone], a localized generic wrapper around the raw
///   detail; otherwise just the raw detail (for call sites that already supply
///   their own localized "what failed" prefix).
String localizedError(AppLocalizations l10n, dynamic e,
    {bool standalone = true}) {
  if (e is TunnelFailure) {
    return tunnelErrorMessage(l10n, e.code);
  }
  switch (classifyRustError(e)) {
    case AppErrorCode.notAuthenticated:
      return l10n.appErrorNotAuthenticated;
    case AppErrorCode.permissionDenied:
      return l10n.appErrorPermissionDenied;
    case AppErrorCode.notFound:
      return l10n.appErrorNotFound;
    case AppErrorCode.network:
      return l10n.appErrorNetwork;
    case AppErrorCode.quotaExceeded:
      return l10n.appErrorQuotaExceeded;
    case AppErrorCode.gcloudNotInstalled:
      return l10n.appErrorGcloudNotInstalled;
    case AppErrorCode.alreadyExists:
      return l10n.appErrorAlreadyExists;
    case AppErrorCode.invalidInput:
      return l10n.appErrorInvalidInput;
    case AppErrorCode.cancelled:
      return l10n.appErrorCancelled;
    case AppErrorCode.unknown:
      final detail = e.toString();
      return standalone ? l10n.appErrorGeneric(detail) : detail;
  }
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `flutter test test/app_error_test.dart`
Expected: PASS (classifier + localizedError groups).

- [ ] **Step 8: Verify parity + analyze + commit**

Run:
```bash
python3 -c "import json; en=json.load(open('lib/l10n/app_en.arb')); es=json.load(open('lib/l10n/app_es.arb')); ek={k for k in en if not k.startswith('@')}; sk={k for k in es if not k.startswith('@')}; print('missing in ES:', ek-sk, '| missing in EN:', sk-ek)"
flutter analyze lib/src/features/app_error.dart 2>&1 | tail -3
```
Expected: no missing keys either direction; analyze 0 errors. Then:
```bash
git add lib/src/features/app_error.dart lib/l10n/ test/app_error_test.dart
git commit -m "feat(i18n): localizedError helper + appError* keys (EN/ES)"
```

---

### Task 3: Adopt `localizedError` at user-facing call sites

**Files (modify):** `lib/main.dart`, `lib/src/features/snapshot_manager_dialog.dart`, `lib/src/features/diagnostics_panel.dart`, `lib/src/features/connectivity_doctor.dart`, `lib/src/features/database_connection_panel.dart`, `lib/src/features/settings_dialog.dart`, `lib/src/features/tunnel_manager_dialog.dart`, `lib/src/features/sftp_browser.dart`, `lib/src/features/client_lib_test_screen.dart`.

**Interfaces:**
- Consumes: `localizedError(AppLocalizations l10n, dynamic e, {bool standalone})` (Task 2).

**Transformation rule.** These call sites currently interpolate the *raw* error into an already-localized template, e.g. `l10n.snapshotDeleteError(e.toString())` or `l10n.commonErrorPrefix('$e')`. Replace the interpolated raw error with a `localizedError` call that has **no** generic wrapper (the template already provides the context):
- `l10n.someTemplate(e.toString())` → `l10n.someTemplate(localizedError(l10n, e, standalone: false))`
- `l10n.someTemplate('$e')` → `l10n.someTemplate(localizedError(l10n, e, standalone: false))`
- `l10n.someTemplate('$err')` → `l10n.someTemplate(localizedError(l10n, err, standalone: false))`

Add `import 'app_error.dart';` (or the correct relative path, e.g. `'../features/app_error.dart'` / `'src/features/app_error.dart'` in `main.dart`) to each file you touch. Do NOT touch `debugPrint`/`print`/logging — those stay English on purpose. Where the variable is named `err` (async `error:` builders), pass `err`.

- [ ] **Step 1: Enumerate the exact call sites**

Run BOTH greps (the second catches multi-argument templates where the error is
NOT the sole argument, e.g. `l10n.sftpErrorLoadDirectory(dirPath, e.toString())`
— the first grep misses those):
```bash
grep -rnE "l10n\.[a-zA-Z]+\((e|err)\.toString\(\)\)|l10n\.[a-zA-Z]+\('\$(e|err)'\)" lib/ --include=*.dart | grep -v '/gen/'
grep -rnE "l10n\.[a-zA-Z]+\([^)]*,\s*(e|err)\.toString\(\)\)" lib/ --include=*.dart | grep -v '/gen/' | grep -v 'commonUpdateLabel'
```
Known sites from the survey (confirm against the grep, line numbers may drift): `main.dart` (dashboardLoginFailed, commonErrorPrefix, appExportLogsFailed, appLogoutError ×2, appErrorLoadingProjects ×2); `snapshot_manager_dialog.dart` (commonErrorPrefix, snapshotDeleteError, snapshotCreateDiskError, snapshotCreateError); `diagnostics_panel.dart` (diagExportFailed); `connectivity_doctor.dart` (doctorExportFailed, doctorFixFailed); `database_connection_panel.dart` (dbConnectionFailed ×2, dbErrorLoadingClients); `settings_dialog.dart` (settingsErrorDetectingRdp, settingsErrorDetectingVnc, settingsErrorCheckingDeps); `tunnel_manager_dialog.dart` (tunnelCleanupFailed); `client_lib_test_screen.dart` (commonErrorPrefix ×3); `sftp_browser.dart` (its user-facing SnackBars — inspect each `$e`).

- [ ] **Step 2: Apply the transformation to each site**

For each match, apply the rule above. Example (`snapshot_manager_dialog.dart`):
```dart
// before
SnackBar(content: Text(l10n.snapshotDeleteError(e.toString())))
// after
SnackBar(content: Text(l10n.snapshotDeleteError(localizedError(l10n, e, standalone: false))))
```
Add the `app_error.dart` import to each modified file.

- [ ] **Step 3: Confirm no user-facing raw error remains**

Run the Step 1 grep again — expected: no matches (every user-facing template now wraps the error in `localizedError`). `debugPrint`/logging lines are out of scope and will not appear (they don't use `l10n.`).

- [ ] **Step 4: Full gate**

Run:
```bash
flutter gen-l10n
flutter analyze 2>&1 | grep -cE '^\s*error •'   # expect 0
flutter test 2>&1 | tail -3                       # expect All tests passed
flutter build linux --debug 2>&1 | tail -2        # expect Built
```
Expected: 0 analyze errors; full suite green; app builds.

- [ ] **Step 5: Commit**

```bash
git add lib/
git commit -m "feat(i18n): show localized messages for Rust errors at UI call sites"
```

---

## Manual QA (after implementation)

- Switch the app to Spanish. Trigger representative failures and confirm the message is Spanish, not raw English:
  - Expired session (list projects fails) → "Tu sesión expiró…" and the re-login banner appears.
  - Permission denied (operate on a VM without IAM) → "No tienes permiso…".
  - `gcloud` not on PATH → "gcloud CLI no está instalado…".
  - A snapshot delete/create failure → "No se pudo …: <mensaje localizado>".
  - An unmapped error → generic localized wrapper still shows the raw detail (nothing lost).
