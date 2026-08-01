# GCP Session-Expiry Detection + In-App Re-login — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the gcloud/ADC session expires (project/instance listing fails with a reauth error), the app detects it and shows a non-modal banner with a "Re-authenticate" button that reuses the existing `gcloud auth login` flow and refreshes on success.

**Architecture:** A one-line Rust bridge wrapper (`reauthenticate()`) over the existing `crate::gcloud::execute_login()`; a fix to the Dart error classifier so the reauth error is recognized as `unauthenticated`; a new `GcpSessionBanner` widget that watches `projectsProvider`/`instancesProvider` for that error; and mounting the banner at the top of the dashboard body. Semi-proactive via the providers' existing 5-minute TTL.

**Tech Stack:** Flutter (Riverpod 3.x), Rust via flutter_rust_bridge 2.11.1, gen-l10n (EN/ES).

## Global Constraints

- **flutter_rust_bridge 2.11.1.** Regenerate the bridge after `native/src/api.rs` changes with: `/home/jlopezre/.cargo/bin/flutter_rust_bridge_codegen generate --rust-input "crate::api" --rust-root native --dart-output lib/src/bridge/api.dart`. Regen may touch other bridge files — `git diff --stat lib/src/bridge/` after regen and confirm only the intended `reauthenticate` binding was added; if unrelated bindings changed, review before committing.
- **After any `api.rs` change rebuild BOTH** `cargo build` **and** `cargo build --release` in `native/` — the app loads `native/target/release/libnative.so`.
- **Reuse `crate::gcloud::execute_login()`** — do NOT add new gcloud/auth logic.
- **i18n EN/ES parity**, append-only. Keys with no placeholders need no `@key` metadata block.
- **Banner renders `SizedBox.shrink()`** when there is no auth error (zero visual footprint).
- **No `Co-Authored-By` trailer on code commits** (docs commits only).

## File Structure

- **Modify** `native/src/api.rs` — add `pub async fn reauthenticate()`.
- **Regenerate** `lib/src/bridge/api.dart/…` (adds the `reauthenticate` binding).
- **Modify** `lib/src/features/gcloud_provider.dart` — rename `_classifyGcpError` → public `classifyGcpError`, recognize the reauth error, update the 2 internal call sites.
- **Create** `test/gcp_error_classifier_test.dart`.
- **Modify** `lib/l10n/app_en.arb`, `lib/l10n/app_es.arb` (+ regen `lib/l10n/gen/`).
- **Create** `lib/src/features/gcp_session_banner.dart`.
- **Create** `test/gcp_session_banner_test.dart`.
- **Modify** `lib/main.dart` — mount `GcpSessionBanner` at the top of the dashboard body.

---

### Task 1: Rust `reauthenticate()` bridge wrapper

**Files:**
- Modify: `native/src/api.rs`
- Regenerate: `lib/src/bridge/api.dart/…`

**Interfaces:**
- Produces: Dart-callable `Future<void> reauthenticate()` that runs `gcloud auth login` (opens the browser, resolves when done; throws on failure/cancel).

- [ ] **Step 1: Add the wrapper in `native/src/api.rs`**

Add (near the other public API functions, e.g. right after `execute_doctor_fix`):

```rust
/// Re-run `gcloud auth login` (opens the browser) to refresh an expired
/// session. Surfaced by the in-app "Re-authenticate" banner. Reuses the same
/// login path the Doctor uses (`execute_login`); adds no new gcloud logic.
pub async fn reauthenticate() -> anyhow::Result<()> {
    crate::gcloud::execute_login()
}
```

- [ ] **Step 2: Compile the native crate**

Run: `cd native && cargo build`
Expected: builds without errors.

- [ ] **Step 3: Regenerate the bridge**

Run: `/home/jlopezre/.cargo/bin/flutter_rust_bridge_codegen generate --rust-input "crate::api" --rust-root native --dart-output lib/src/bridge/api.dart`
Then: `git diff --stat lib/src/bridge/`
Expected: the `reauthenticate` binding appears (e.g. in `lib/src/bridge/api.dart/api.dart`); changes are additive. If unrelated bindings changed, review before proceeding.

Verify the binding exists: `grep -rn "reauthenticate" lib/src/bridge/api.dart/` → shows the generated `Future<void> reauthenticate(...)`.

- [ ] **Step 4: Rebuild release so the app loads the new symbol**

Run: `cd native && cargo build --release`
Expected: builds without errors.

- [ ] **Step 5: Commit**

```bash
git add native/src/api.rs lib/src/bridge/
git commit -m "feat(auth): reauthenticate() bridge fn wrapping gcloud execute_login"
```

(No `Co-Authored-By` — code commit.)

---

### Task 2: Recognize the reauth error in the classifier

**Files:**
- Modify: `lib/src/features/gcloud_provider.dart`
- Test: `test/gcp_error_classifier_test.dart`

**Interfaces:**
- Consumes: nothing new.
- Produces: public `GcpErrorType classifyGcpError(dynamic e)` that returns `GcpErrorType.unauthenticated` for the session-expiry / reauth error strings.

- [ ] **Step 1: Write the failing test**

Create `test/gcp_error_classifier_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/src/features/gcloud_provider.dart';

void main() {
  group('classifyGcpError', () {
    test('session-expired reauth message -> unauthenticated', () {
      final e = Exception(
          'Authentication failed: your Google Cloud session has expired or '
          'requires reauthentication. Run: gcloud auth login');
      expect(classifyGcpError(e), GcpErrorType.unauthenticated);
    });

    test('invalid_rapt -> unauthenticated', () {
      expect(classifyGcpError(Exception('reauth failed: invalid_rapt')),
          GcpErrorType.unauthenticated);
    });

    test('No active GCP account -> unauthenticated', () {
      expect(classifyGcpError(Exception('No active GCP account. Please run ...')),
          GcpErrorType.unauthenticated);
    });

    test('UNAUTHENTICATED still classified -> unauthenticated', () {
      expect(classifyGcpError(Exception('UNAUTHENTICATED')),
          GcpErrorType.unauthenticated);
    });

    test('PERMISSION_DENIED -> permissionDenied', () {
      expect(classifyGcpError(Exception('PERMISSION_DENIED')),
          GcpErrorType.permissionDenied);
    });

    test('unrelated message -> unknown', () {
      expect(classifyGcpError(Exception('disk full')), GcpErrorType.unknown);
    });
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `flutter test test/gcp_error_classifier_test.dart`
Expected: FAIL — `classifyGcpError` is undefined (currently private `_classifyGcpError`).

- [ ] **Step 3: Make the classifier public and recognize reauth errors**

In `lib/src/features/gcloud_provider.dart`:

1. Rename the function `GcpErrorType _classifyGcpError(dynamic e)` → `GcpErrorType classifyGcpError(dynamic e)`.
2. Update the two call sites (`errorType: _classifyGcpError(e),` at lines ~131 and ~187) → `errorType: classifyGcpError(e),`.
3. Add the reauth recognition **before** the final `return GcpErrorType.unknown;`:

```dart
  if (msg.contains('requires reauthentication') ||
      msg.contains('session has expired') ||
      msg.contains('invalid_rapt') ||
      msg.contains('No active GCP account')) {
    return GcpErrorType.unauthenticated;
  }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `flutter test test/gcp_error_classifier_test.dart`
Expected: PASS (all 6 cases).

- [ ] **Step 5: Commit**

```bash
git add lib/src/features/gcloud_provider.dart test/gcp_error_classifier_test.dart
git commit -m "fix(auth): classify session-expiry/reauth errors as unauthenticated"
```

(No `Co-Authored-By` — code commit.)

---

### Task 3: i18n keys + `GcpSessionBanner` widget

**Files:**
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_es.arb`
- Regenerate: `lib/l10n/gen/`
- Create: `lib/src/features/gcp_session_banner.dart`
- Test: `test/gcp_session_banner_test.dart`

**Interfaces:**
- Consumes: `classifyGcpError`, `GcpErrorType`, `projectsProvider`, `instancesProvider` (Task 2 / existing); `reauthenticate()` (Task 1).
- Produces: `GcpSessionBanner` widget (const-constructible).

- [ ] **Step 1: Add the 5 keys to both arb files**

In `lib/l10n/app_en.arb`, add (these have no placeholders, so no `@key` blocks needed):

```json
  "sessionExpiredBanner": "Your Google Cloud session has expired.",
  "sessionExpiredReauth": "Re-authenticate",
  "sessionExpiredReauthenticating": "Authenticating…",
  "sessionExpiredReauthOk": "Re-authenticated. Refreshing…",
  "sessionExpiredReauthFailed": "Re-authentication failed or was cancelled.",
```

In `lib/l10n/app_es.arb`, add the parallel keys:

```json
  "sessionExpiredBanner": "Tu sesión de Google Cloud ha expirado.",
  "sessionExpiredReauth": "Reautenticar",
  "sessionExpiredReauthenticating": "Autenticando…",
  "sessionExpiredReauthOk": "Reautenticado. Actualizando…",
  "sessionExpiredReauthFailed": "La reautenticación falló o se canceló.",
```

- [ ] **Step 2: Regenerate localizations**

Run: `flutter gen-l10n`
Verify: `grep -rn "sessionExpiredReauth\b" lib/l10n/gen/app_localizations.dart` → the getter exists.

- [ ] **Step 3: Create the banner widget**

Create `lib/src/features/gcp_session_banner.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import '../bridge/api.dart/api.dart';
import 'gcloud_provider.dart';

/// Non-modal banner shown at the top of the dashboard when the GCP session has
/// expired (project/instance listing failed with an auth/reauth error). Offers
/// a one-tap re-login that reuses `gcloud auth login`. Renders nothing when
/// there is no auth error.
class GcpSessionBanner extends ConsumerStatefulWidget {
  const GcpSessionBanner({super.key});

  @override
  ConsumerState<GcpSessionBanner> createState() => _GcpSessionBannerState();
}

class _GcpSessionBannerState extends ConsumerState<GcpSessionBanner> {
  bool _busy = false;

  bool _isAuthError(AsyncValue<dynamic> v) =>
      v.hasError && classifyGcpError(v.error) == GcpErrorType.unauthenticated;

  Future<void> _reauth() async {
    setState(() => _busy = true);
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await reauthenticate();
      ref.invalidate(projectsProvider);
      ref.invalidate(instancesProvider);
      messenger.showSnackBar(
          SnackBar(content: Text(l10n.sessionExpiredReauthOk)));
    } catch (_) {
      messenger.showSnackBar(
          SnackBar(content: Text(l10n.sessionExpiredReauthFailed)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final expired = _isAuthError(ref.watch(projectsProvider)) ||
        _isAuthError(ref.watch(instancesProvider));
    if (!expired) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                l10n.sessionExpiredBanner,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: _busy ? null : _reauth,
              child: Text(_busy
                  ? l10n.sessionExpiredReauthenticating
                  : l10n.sessionExpiredReauth),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Write the widget visibility test**

Create `test/gcp_session_banner_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import 'package:linux_cloud_connector/src/features/gcloud_provider.dart';
import 'package:linux_cloud_connector/src/features/gcp_session_banner.dart';

Widget _wrap(List<Override> overrides) => ProviderScope(
      overrides: overrides,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: GcpSessionBanner()),
      ),
    );

void main() {
  testWidgets('shows banner on auth error', (tester) async {
    await tester.pumpWidget(_wrap([
      projectsProvider.overrideWith((ref) => throw Exception(
          'Authentication failed: your Google Cloud session has expired or '
          'requires reauthentication.')),
      instancesProvider.overrideWith((ref) async => <GcpInstance>[]),
    ]));
    await tester.pump();
    expect(find.byType(FilledButton), findsOneWidget);
  });

  testWidgets('hidden when projects load fine', (tester) async {
    await tester.pumpWidget(_wrap([
      projectsProvider.overrideWith((ref) async => <GcpProject>[]),
      instancesProvider.overrideWith((ref) async => <GcpInstance>[]),
    ]));
    await tester.pump();
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(SizedBox), findsWidgets); // SizedBox.shrink()
  });
}
```

> Note: the "Re-authenticate" button invokes the top-level bridge `reauthenticate()`, which cannot be mocked in a widget test; the button→login→refresh flow is covered by the manual QA in Task 5. This test asserts visibility only.

- [ ] **Step 5: Run tests + analyze**

Run: `flutter test test/gcp_session_banner_test.dart`
Expected: PASS (2 cases).
Run: `flutter analyze lib/src/features/gcp_session_banner.dart`
Expected: no errors (info/deprecation warnings pre-existing elsewhere are fine).

> Both tests override `projectsProvider` **and** `instancesProvider` so neither provider's real body (which calls the bridge) runs in the test. If either `overrideWith` signature differs from what's shown (Riverpod 3.x API drift), adapt the override form but keep both providers stubbed so visibility is driven only by the stubbed states.

- [ ] **Step 6: Commit**

```bash
git add lib/l10n/app_en.arb lib/l10n/app_es.arb lib/l10n/gen/ lib/src/features/gcp_session_banner.dart test/gcp_session_banner_test.dart
git commit -m "feat(auth): GcpSessionBanner with re-login (i18n EN/ES)"
```

(No `Co-Authored-By` — code commit.)

---

### Task 4: Mount the banner at the top of the dashboard

**Files:**
- Modify: `lib/main.dart`

**Interfaces:**
- Consumes: `GcpSessionBanner` (Task 3).

- [ ] **Step 1: Import the banner**

In `lib/main.dart`, add with the other `src/features/*` imports:

```dart
import 'src/features/gcp_session_banner.dart';
```

- [ ] **Step 2: Wrap the dashboard body**

In `DashboardScreen.build` (around line 315), the `Scaffold`'s `body:` is `statusAsync.when( … )`. Wrap that whole expression so the banner sits above it:

Change:
```dart
      body: statusAsync.when(
        data: (status) {
```
to:
```dart
      body: Column(
        children: [
          const GcpSessionBanner(),
          Expanded(
            child: statusAsync.when(
        data: (status) {
```
and add the matching close for the `Expanded`/`Column` at the end of the `statusAsync.when( … )` expression (after its final `)` that was the value of `body:`, before the trailing comma):
```dart
            ), // statusAsync.when
          ),   // Expanded
        ],
      ),       // Column (body)
```

(Net effect: `body: Column(children: [const GcpSessionBanner(), Expanded(child: statusAsync.when(...))])`.)

- [ ] **Step 3: Analyze**

Run: `flutter analyze lib/main.dart`
Expected: no new errors (the `body:` expression is balanced; `GcpSessionBanner` resolves).

- [ ] **Step 4: Commit**

```bash
git add lib/main.dart
git commit -m "feat(auth): mount GcpSessionBanner atop the dashboard body"
```

(No `Co-Authored-By` — code commit.)

---

### Task 5: Full gate + manual QA checklist

**Files:** none (verification only).

- [ ] **Step 1: Static + unit gate**

Run:
```bash
cd native && cargo build && cargo build --release && cd ..
flutter gen-l10n
flutter analyze lib/src/features/gcp_session_banner.dart lib/src/features/gcloud_provider.dart lib/main.dart
flutter test test/gcp_error_classifier_test.dart test/gcp_session_banner_test.dart
```
Expected: native builds (debug + release); gen-l10n clean; analyze reports no NEW errors on the touched files; both test files pass.

- [ ] **Step 2: EN/ES parity check**

Run:
```bash
for k in sessionExpiredBanner sessionExpiredReauth sessionExpiredReauthenticating sessionExpiredReauthOk sessionExpiredReauthFailed; do
  grep -q "\"$k\"" lib/l10n/app_en.arb && grep -q "\"$k\"" lib/l10n/app_es.arb && echo "OK $k" || echo "MISSING $k";
done
```
Expected: `OK` for all five keys.

- [ ] **Step 3: Build the app**

Run: `flutter build linux --debug`
Expected: builds successfully.

- [ ] **Step 4: Manual QA (maintainer, real desktop)**

1. Launch the app while authenticated; confirm projects/instances list and **no banner**.
2. In a terminal run `gcloud auth revoke` (or wait for the session to expire).
3. Within ≤5 min (the providers' TTL), the **banner appears**: "Your Google Cloud session has expired." + [Re-authenticate]. (Or trigger sooner by switching account / manual refresh.)
4. Click **Re-authenticate** → the browser opens for `gcloud auth login`; the button shows "Authenticating…".
5. Complete the browser login → the banner disappears and projects/instances re-list; a "Re-authenticated. Refreshing…" snackbar shows.
6. Repeat and **cancel** the browser login → the banner stays; a "Re-authentication failed or was cancelled." snackbar shows; no crash.
7. Switch app language to Spanish; confirm the banner/button/snackbars are translated.
