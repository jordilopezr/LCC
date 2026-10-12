# Overview Actions by Category — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Regroup the 17 flat action buttons in the Overview tab into 3 labeled sub-sections (Access · Power · Tools) without changing any button's behavior.

**Architecture:** Approach A (labeled sub-sections). In `lib/src/features/workspace/overview_tab.dart`, replace the single `Wrap` of action buttons with a `Column` of three `(header + Wrap)` sections, moving each `_ActionButton` verbatim into its group. A small top-level `_actionSectionHeader` helper renders each secondary header. Three new i18n keys (EN+ES) name the groups.

**Tech Stack:** Flutter (Dart), Riverpod, `flutter gen-l10n` (arb-dir `lib/l10n`, output `lib/l10n/gen`). Spec: `docs/superpowers/specs/2026-08-12-overview-actions-categories-design.md`.

## Global Constraints

- **Dart-only.** No Rust, no bridge regen, no `cargo`. Do NOT run `dart format`.
- **Enfoque A only:** 3 labeled sub-sections (a `Column` of `header + Wrap` per group). No collapsible tiles, no sub-tabs. Restructure **in place** — do NOT extract `OverviewTab` into new files.
- **Move each `_ActionButton` verbatim:** no change to any button's icon, colors, `onPressed`, snackbars, history calls, or enable/disable logic. Only their grouping/position changes. The `if (!Platform.isWindows)` guard on Mount SSHFS stays.
- **3 categories, section order Access → Power → Tools.** Relative order of buttons within each group is preserved.
- **Membership (exact):** Access = RDP, VNC, SSH, SFTP, Custom Tunnel, Database, Mount SSHFS, Windows Credentials, Connect/Disconnect toggle. Power = Start, Stop, Reset, Suspend, Resume. Tools = Diagnostics, Doctor, Snapshots.
- **3 i18n keys, EN+ES, parity enforced, prefix `dashboard*`:** `dashboardActionsGroupAccess` (EN `Access & connections` / ES `Acceso y conexiones`), `dashboardActionsGroupPower` (EN `Power & state` / ES `Energía y estado`), `dashboardActionsGroupTools` (EN `Tools` / ES `Herramientas`). Run `flutter gen-l10n` and commit `lib/l10n/gen`.
- **Analyzer baseline ~85 issues (0 errors); introduce no new issues.** Branch `27H1-Preview`.
- **Commit trailer:** these are **code** commits — they MUST NOT carry a `Co-Authored-By: Claude` trailer (that trailer is for docs commits only).
- **es_overflow_test guard:** `test/es_overflow_test.dart` already pumps `OverviewTab` in Spanish at 1280/1024/720 and fails on overflow — it must stay green after the restructure.

---

### Task 1: Add the 3 group-header i18n keys (EN + ES) + regen

Adds the localized strings the section headers will use. Must land first so Task 2's code (and its test, which references the generated getters) compiles.

**Files:**
- Modify: `lib/l10n/app_en.arb`
- Modify: `lib/l10n/app_es.arb`
- Regenerate (commit output): `lib/l10n/gen/` (via `flutter gen-l10n`)

**Interfaces:**
- Produces: generated getters `AppLocalizations.dashboardActionsGroupAccess`, `.dashboardActionsGroupPower`, `.dashboardActionsGroupTools` (all `String`), consumed by Task 2.

- [ ] **Step 1: Add the 3 keys to the English template**

In `lib/l10n/app_en.arb`, immediately after the existing `"dashboardActionsTitle": "Actions",` line, add (match the file's 2-space indent and trailing-comma style; these are plain strings with no placeholders, so no `@`-metadata is required):

```json
  "dashboardActionsGroupAccess": "Access & connections",
  "dashboardActionsGroupPower": "Power & state",
  "dashboardActionsGroupTools": "Tools",
```

- [ ] **Step 2: Add the same 3 keys to the Spanish file**

In `lib/l10n/app_es.arb`, after its `"dashboardActionsTitle"` entry, add the Spanish values (neutral/impersonal register):

```json
  "dashboardActionsGroupAccess": "Acceso y conexiones",
  "dashboardActionsGroupPower": "Energía y estado",
  "dashboardActionsGroupTools": "Herramientas",
```

- [ ] **Step 3: Regenerate the localizations**

Run: `flutter gen-l10n`
Expected: completes without error (no missing-translation warning for the 3 new keys, since both files have them).

- [ ] **Step 4: Verify the getters exist and nothing broke**

Run: `grep -c 'dashboardActionsGroup' lib/l10n/gen/app_localizations.dart`
Expected: `3` or more (the abstract getters were generated).

Run: `flutter analyze 2>&1 | tail -5`
Expected: 0 errors; issue count not higher than the ~85 baseline.

- [ ] **Step 5: Commit** (code commit — NO `Co-Authored-By` trailer)

```bash
cd /home/jlopezre/GitHub/LCC
git add lib/l10n/app_en.arb lib/l10n/app_es.arb lib/l10n/gen
git commit -m "i18n: add Overview action-group header keys (EN+ES)"
```

---

### Task 2: Regroup the Overview action buttons into 3 labeled sections + widget test

Replaces the single flat `Wrap` with a `Column` of three `header + Wrap` sections. TDD: the widget test asserting the 3 headers fails first (they don't render yet), then passes after the restructure.

**Files:**
- Modify: `lib/src/features/workspace/overview_tab.dart` (the actions block, currently the `Wrap` at lines ~346-1021; add a top-level `_actionSectionHeader` helper)
- Create: `test/overview_actions_categories_test.dart`

**Interfaces:**
- Consumes: `AppLocalizations.dashboardActionsGroupAccess/Power/Tools` (Task 1); the existing `_ActionButton` widget and `l10n.*` button labels already in the file; `ProjectAwareInstance` (`lib/src/features/gcloud_provider.dart`) + `GcpInstance` (`lib/src/bridge/api.dart/gcloud.dart`).

- [ ] **Step 1: Write the widget test**

Create `test/overview_actions_categories_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import 'package:linux_cloud_connector/src/features/workspace/overview_tab.dart';
import 'package:linux_cloud_connector/src/features/gcloud_provider.dart';
import 'package:linux_cloud_connector/src/bridge/api.dart/gcloud.dart';

ProjectAwareInstance _fakeVm() => ProjectAwareInstance(
      projectId: 'my-project-id',
      instance: GcpInstance(
        name: 'instancia-de-produccion-backup-01',
        status: 'RUNNING',
        zone: 'us-central1-a',
        machineType: 'e2-standard-4',
        cpuCount: 4,
        memoryMb: 16384,
        diskGb: 100,
        labels: const [],
        osLoginEnabled: false,
        isWindows: false,
      ),
    );

Future<void> _pumpOverview(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: OverviewTab(target: _fakeVm())),
      ),
    ),
  );
  // Providers that reach the Rust bridge throw here (the native lib is not
  // linked into `flutter test`); the frame still lays out. Drain those
  // non-fatal exceptions so they don't fail this test — headers/buttons use
  // the passed-in `target` + l10n and render regardless.
  await tester.pump(const Duration(milliseconds: 100));
  for (var e = tester.takeException(); e != null; e = tester.takeException()) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Overview actions render under 3 category headers',
      (tester) async {
    final en = await AppLocalizations.delegate.load(const Locale('en'));
    await _pumpOverview(tester);

    // The 3 category headers are present.
    expect(find.text(en.dashboardActionsGroupAccess), findsOneWidget);
    expect(find.text(en.dashboardActionsGroupPower), findsOneWidget);
    expect(find.text(en.dashboardActionsGroupTools), findsOneWidget);

    // A representative button from each group still renders.
    expect(find.text(en.dashboardConnectSshButton), findsWidgets); // Access
    expect(find.text(en.dashboardStartInstanceButton), findsWidgets); // Power
    expect(find.text(en.dashboardMenuDoctor), findsWidgets); // Tools
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/overview_actions_categories_test.dart 2>&1 | tail -20`
Expected: FAIL — `find.text('Access & connections')` etc. find nothing (the headers don't exist yet). The button-label expectations may already pass; the header expectations are what fail.

- [ ] **Step 3: Add the section-header helper**

In `lib/src/features/workspace/overview_tab.dart`, add this top-level private function (place it near the `_ActionButton` widget definition in the same file):

```dart
/// Secondary header above a group of action buttons in the Overview tab.
/// Deliberately quieter than the "Actions" title so it groups without competing.
Widget _actionSectionHeader(BuildContext context, String label) {
  final theme = Theme.of(context);
  return Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(
      label,
      style: theme.textTheme.titleSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}
```

- [ ] **Step 4: Replace the flat `Wrap` with a `Column` of 3 sections**

In the `build` method, the actions area is currently one `Wrap(spacing: 16.0, runSpacing: 16.0, children: [ ...17 _ActionButton... ])` (starts ~line 346, ends ~line 1021, just before the `if (isConnecting) ... LinearProgressIndicator`). Replace that single `Wrap` with the `Column` below, **moving each existing `_ActionButton(...)` block verbatim** into the group and slot given by this map (you may drop the now-redundant inline grouping comments like `// VM Lifecycle Management buttons` / `// Database connection button (Sprint 4) — Pro only`, but change no button code):

| Group (in order) | Buttons, in this order (current approx. line range) |
|---|---|
| **Access** | RDP (350-384) · VNC (385-421) · SSH (422-444) · SFTP (445-467) · Custom Tunnel (468-534) · Database (536-551) · Mount SSHFS incl. its `if (!Platform.isWindows)` (553-622) · Windows Credentials (624-640) · Connect/Disconnect toggle (683-720) |
| **Power** | Start (722-768) · Stop (769-837) · Reset (838-908) · Suspend (910-971) · Resume (973-1019) |
| **Tools** | Diagnostics (642-654) · Doctor (656-666) · Snapshots (667-682) |

Skeleton (keep `l10n` in scope — it is already defined in `build`):

```dart
Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    _actionSectionHeader(context, l10n.dashboardActionsGroupAccess),
    Wrap(
      spacing: 16.0,
      runSpacing: 16.0,
      children: [
        // RDP, VNC, SSH, SFTP, Custom Tunnel, Database,
        // (if !Platform.isWindows) Mount SSHFS, Windows Credentials,
        // Connect/Disconnect toggle  — each _ActionButton moved verbatim
      ],
    ),
    const SizedBox(height: 20),
    _actionSectionHeader(context, l10n.dashboardActionsGroupPower),
    Wrap(
      spacing: 16.0,
      runSpacing: 16.0,
      children: [
        // Start, Stop, Reset, Suspend, Resume — verbatim
      ],
    ),
    const SizedBox(height: 20),
    _actionSectionHeader(context, l10n.dashboardActionsGroupTools),
    Wrap(
      spacing: 16.0,
      runSpacing: 16.0,
      children: [
        // Diagnostics, Doctor, Snapshots — verbatim
      ],
    ),
  ],
)
```

Leave the `if (isConnecting) ... LinearProgressIndicator` that follows the actions area unchanged (it now follows the new `Column`).

- [ ] **Step 5: Run the widget test to verify it passes**

Run: `flutter test test/overview_actions_categories_test.dart 2>&1 | tail -20`
Expected: PASS — all 3 headers found, all 3 representative buttons found.

- [ ] **Step 6: Confirm the ES overflow guard is still green**

Run: `flutter test test/es_overflow_test.dart 2>&1 | tail -6`
Expected: all pass (incl. `OverviewTab` at 1280/1024/720) — the new headers introduce no Spanish overflow. If any `OverviewTab overflowed in Spanish` appears, apply the minimal fix (the header is a single `Text`; wrap it or the offending `Wrap` per the SettingsDialog precedent) and re-run.

- [ ] **Step 7: Full suite + analyze**

Run: `flutter test 2>&1 | tail -12`
Expected: whole suite green.

Run: `flutter analyze 2>&1 | tail -8`
Expected: 0 errors; no new issue in `overview_tab.dart` or the new test.

- [ ] **Step 8: Commit** (code commit — NO `Co-Authored-By` trailer)

```bash
cd /home/jlopezre/GitHub/LCC
git add lib/src/features/workspace/overview_tab.dart test/overview_actions_categories_test.dart
git commit -m "feat(ui): group Overview action buttons into Access/Power/Tools sections"
```

---

## Self-Review

**1. Spec coverage:**
- Enfoque A, 3 labeled sub-sections (Column of header + Wrap) → Task 2 Steps 3-4. ✓
- 3 categories, order Access → Power → Tools, relative order preserved → Task 2 Step 4 map + skeleton. ✓
- Exact membership incl. SSHFS `!Windows` guard and Connect/Disconnect in Access → Task 2 Step 4 map. ✓
- Buttons moved verbatim (no behavior/style change) → Global Constraints + Step 4 wording. ✓
- `_actionSectionHeader` helper (titleSmall + onSurfaceVariant, secondary) → Task 2 Step 3. ✓
- 3 i18n keys EN+ES + regen `lib/l10n/gen` → Task 1. ✓
- No file extraction, no collapsible/tabs → Global Constraints. ✓
- Widget test (3 headers + representative button per group) → Task 2 Steps 1-5. ✓
- es_overflow_test stays green → Task 2 Step 6. ✓
- Suite + analyzer verification → Task 2 Steps 7. ✓
- Dart-only, no Rust/bridge → Global Constraints. ✓

**2. Placeholder scan:** No TBD/TODO. The i18n JSON, the helper, the test, and the `Column` skeleton are concrete. Step 4's per-button code is not pasted (it's ~675 lines of existing code) but the plan is explicit that each `_ActionButton` moves **verbatim** and gives the exact group/slot/line-range for every button — this is a move operation, not new code, so repeating the bodies would risk transcription drift. ✓

**3. Type consistency:** Key names `dashboardActionsGroupAccess/Power/Tools` match between Task 1 (arb + produced getters) and Task 2 (test + skeleton). Helper name `_actionSectionHeader(BuildContext, String)` matches between Step 3 (definition) and Step 4 (call sites). Test references real getters (`dashboardConnectSshButton`, `dashboardStartInstanceButton`, `dashboardMenuDoctor`) already used in `overview_tab.dart`. `_fakeVm()` mirrors `test/es_overflow_test.dart` / `test/workspace_provider_test.dart`. ✓
