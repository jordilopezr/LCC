# Account Dialog Error Reconciliation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `account_management_dialog.dart` render errors via the unified `localizedError` (single source of truth), and delete the `_gcpErrorMessage` stopgap plus the dead code it leaves behind.

**Architecture:** Replace the dialog's one error-render call with `localizedError`, delete `_gcpErrorMessage`, remove the now write-only `AccountState.errorType` field (and its two `classifyRustError` set sites), and delete the 6 now-dead `commonGcpError*` i18n keys. All in one task so the app never has a dangling reference.

**Tech Stack:** Flutter, flutter gen-l10n. Spec: `docs/superpowers/specs/2026-08-06-account-dialog-error-reconciliation-design.md`.

## Global Constraints

- **Dart-only.** No Rust, no bridge regen, no `cargo`. Do NOT run `dart format`.
- `localizedError` is already the app-wide error renderer (`lib/src/features/app_error.dart`) and is already imported by `account_management_dialog.dart`; reuse it, don't reimplement.
- Re-classifying `accountState.error` via `localizedError` is equivalent to the removed `errorType` (which was `classifyRustError(e)` on the same string) — no behavior regression in classification.
- Analyzer bar: repo baseline ~85 pre-existing issues (0 errors); introduce no NEW issues, and leave no orphaned import/field/unused-key after the removals.
- Commits touching code must NOT carry the `Co-Authored-By: Claude` trailer (docs commits only). Branch: `27H1-Preview`.

---

### Task 1: Reconcile the dialog onto `localizedError` and remove the dead code

All edits land together (the dialog, the provider field, and the i18n keys reference each other, so the app must compile at the task boundary).

**Files:**
- Modify: `lib/src/features/account_management_dialog.dart`
- Modify: `lib/src/features/gcloud_provider.dart`
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_es.arb`

**Interfaces:**
- Consumes: existing `localizedError(AppLocalizations, dynamic, {bool standalone})` from `app_error.dart`; existing `AccountState.error` (`String?`).
- Produces: no new API — removes `_gcpErrorMessage`, `AccountState.errorType`, and the `commonGcpError*` keys.

- [ ] **Step 1: Point the dialog's error render at `localizedError`**

In `lib/src/features/account_management_dialog.dart`, in the error `Text(...)` (the line reading `_gcpErrorMessage(l10n, accountState.errorType) ?? accountState.error!,`), replace it with:

```dart
                          localizedError(l10n, accountState.error!),
```

(`localizedError` never returns null, so the `?? accountState.error!` fallback is dropped. This line is inside `if (accountState.error != null)`, so `accountState.error!` is non-null.)

- [ ] **Step 2: Delete the `_gcpErrorMessage` stopgap**

In the same file, delete the entire `_gcpErrorMessage` function — its doc comment (`/// Maps a semantic [AppErrorCode] to a localized message...`) through the closing brace of the `switch`/function (the block that currently spans from `String? _gcpErrorMessage(AppLocalizations l10n, AppErrorCode? type) {` to its final `}`). Keep the `import 'app_error.dart';` at the top (it now supplies `localizedError`).

- [ ] **Step 3: Remove the write-only `AccountState.errorType` field**

In `lib/src/features/gcloud_provider.dart`, in the `AccountState` class:
- Delete the field declaration `final AppErrorCode? errorType;`.
- Delete the constructor parameter `this.errorType,`.
- In `copyWith`, delete the parameter `AppErrorCode? errorType,` and the assignment line `errorType: errorType,`.

Then, at the two sites that set it (the two `.copyWith(...)`/`AccountState(...)` calls that include `errorType: classifyRustError(e),`), delete the `errorType: classifyRustError(e),` line in each.

- [ ] **Step 4: Delete the 6 dead `commonGcpError*` i18n keys**

In `lib/l10n/app_en.arb`, delete these six lines:
```json
  "commonGcpErrorPermissionDenied": "Access denied. Check your GCP permissions.",
  "commonGcpErrorNotFound": "Resource not found.",
  "commonGcpErrorUnauthenticated": "Authentication required. Please re-login.",
  "commonGcpErrorQuotaExceeded": "GCP quota exceeded.",
  "commonGcpErrorNetwork": "Network error. Check your connection.",
  "commonGcpErrorUnknown": "An error occurred. Please check your configuration.",
```
In `lib/l10n/app_es.arb`, delete the corresponding six `commonGcpError*` lines (same keys, Spanish values). Ensure the surrounding JSON stays valid (the entry before the first deleted key keeps its trailing comma; no trailing comma is left dangling before a `}`).

- [ ] **Step 5: Regenerate localizations**

Run: `flutter gen-l10n`
Expected: succeeds; the generated `commonGcpError*` getters disappear from `lib/l10n/gen/`.

Run: `grep -rn "commonGcpError" lib/ | grep -v "\.arb"`
Expected: no matches (the keys are gone from the generated Dart and no code references them).

- [ ] **Step 6: Remove the now-unused `app_error` import from `gcloud_provider` if analyze flags it**

Run: `flutter analyze lib/src/features/gcloud_provider.dart lib/src/features/account_management_dialog.dart 2>&1 | tail -20`
Expected: no NEW issues. If it reports an unused `import '.../app_error.dart';` in `gcloud_provider.dart` (because `AppErrorCode`/`classifyRustError` are no longer referenced there after Step 3), delete that import line and re-run until clean. Do NOT remove the import if it's still used (e.g. `classifyRustError` elsewhere in the file) — analyze is the arbiter. (The `account_management_dialog.dart` import of `app_error.dart` stays — it uses `localizedError`.)

- [ ] **Step 7: Full analyze + test**

Run: `flutter analyze 2>&1 | tail -8`
Expected: 0 errors; no new issue in the touched files over the ~85 pre-existing baseline; no orphaned import/field/key.

Run: `flutter test 2>&1 | tail -12`
Expected: the existing suite stays green (the `app_error` tests still pass; nothing depended on the removed `_gcpErrorMessage`/`errorType`/`commonGcpError*`).

- [ ] **Step 8: Commit**

```bash
cd /home/jlopezre/GitHub/LCC
git add lib/src/features/account_management_dialog.dart \
        lib/src/features/gcloud_provider.dart \
        lib/l10n/app_en.arb lib/l10n/app_es.arb lib/l10n/gen/
git commit -m "refactor(errors): Account dialog uses localizedError; drop the _gcpErrorMessage stopgap"
```

---

### Task 2: Manual QA checklist

**Files:**
- Create: `docs/superpowers/plans/2026-08-06-account-dialog-error-reconciliation-manual-qa.md`

- [ ] **Step 1: Confirm the gate**

Run: `flutter analyze 2>&1 | tail -6` — Expected: 0 errors; no issue introduced in the touched files by Task 1.
Run: `flutter test 2>&1 | tail -6` — Expected: all pass.

- [ ] **Step 2: Write the manual QA checklist**

Create `docs/superpowers/plans/2026-08-06-account-dialog-error-reconciliation-manual-qa.md`:

```markdown
# Manual QA — Account dialog error reconciliation

Open the Account Management dialog and force error states.

- [ ] Trigger a permission/auth error (e.g. an unauthenticated or permission-denied GCP action) → the dialog's red error box shows the unified `appError*` message (e.g. the same permission-denied text used elsewhere in the app), not a raw Rust string.
- [ ] Trigger an unknown/unclassified error → the box shows the generic wrapper with the raw detail (`appErrorGeneric`), not a blank or a stale "An error occurred. Please check your configuration."
- [ ] Switch to Spanish and repeat one case → the message is the Spanish `appError*` text.
- [ ] Normal (no error) flow: the red error box does not appear.
```

- [ ] **Step 3: Commit**

```bash
cd /home/jlopezre/GitHub/LCC
git add docs/superpowers/plans/2026-08-06-account-dialog-error-reconciliation-manual-qa.md
git commit -m "docs(qa): manual QA checklist for Account dialog error reconciliation"
```

---

## Self-Review

**1. Spec coverage:**
- Dialog uses `localizedError(l10n, accountState.error!)` → Task 1 Step 1. ✓
- Delete `_gcpErrorMessage`, keep the app_error import → Task 1 Step 2. ✓
- Remove `AccountState.errorType` (field + ctor + copyWith + 2 set sites) → Task 1 Step 3. ✓
- Conditional removal of the now-unused `app_error` import in gcloud_provider → Task 1 Step 6. ✓
- Delete 6 `commonGcpError*` keys (en/es) + gen-l10n → Task 1 Steps 4-5. ✓
- Verification analyze + test + manual QA → Task 1 Steps 6-7 + Task 2. ✓
- Dart-only, no Rust/bridge → no task runs cargo/codegen beyond gen-l10n. ✓

**2. Placeholder scan:** No TBD/TODO; the replacement line, the exact keys to delete, and the exact tokens to remove (`final AppErrorCode? errorType;`, `this.errorType,`, `errorType: errorType,`, `errorType: classifyRustError(e),`) are all named. The one conditional ("remove the import if analyze flags it") is a precise, analyzer-gated instruction, not a vague placeholder. ✓

**3. Type consistency:** `localizedError(AppLocalizations, dynamic, {bool standalone})` matches its definition in `app_error.dart` and the call `localizedError(l10n, accountState.error!)` (l10n is `AppLocalizations`, `accountState.error!` is `String`). `AccountState.error` (`String?`) is unchanged. No new symbols introduced. ✓
