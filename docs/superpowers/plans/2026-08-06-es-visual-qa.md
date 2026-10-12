# ES Visual QA — Overflow Test Extension Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the Spanish overflow test to cover the Overview tab at a realistic narrow panel width, and fix any Spanish layout overflow it reports.

**Architecture:** `test/es_overflow_test.dart` already pumps 10 dialogs in `Locale('es')` at 2 sizes and fails on RenderFlex overflow. Add a `720x800` narrow size and the `OverviewTab` (with a constructed fake `ProjectAwareInstance`) to the harness, then fix each overflow it reports with a minimal layout change (Wrap/Flexible/ellipsis).

**Tech Stack:** Flutter widget tests (`flutter_test`), Riverpod. Spec: `docs/superpowers/specs/2026-08-06-es-visual-qa-design.md`.

## Global Constraints

- **Dart-only.** No Rust, no bridge regen, no `cargo`. Do NOT run `dart format`.
- The test IS the QA: green (extended) = no Spanish overflow on the covered surfaces (10 dialogs + OverviewTab) at 3 sizes (1280x800, 1024x640, 720x800).
- Fixes are **findings-driven** and **minimal layout only** (Wrap a Row, `Flexible`/`Expanded` + `TextOverflow.ellipsis` on a Text, make a Column scrollable) — no redesign, no behavior change. Follow the repo precedent (SettingsDialog `Row`→`Wrap`).
- There may be **zero** overflows (then the deliverable is just the coverage extension — a regression guard).
- Analyzer bar: repo baseline ~85 pre-existing issues (0 errors); introduce no new issues. Commits touching code must NOT carry the `Co-Authored-By: Claude` trailer (docs commits only). Branch: `27H1-Preview`.

---

### Task 1: Extend the harness (narrow size + OverviewTab) and make it green

The extension and any resulting fixes land together — committing the extension while it's red would be a failing-test commit. Deliverable: the extended `es_overflow_test` is green.

**Files:**
- Modify: `test/es_overflow_test.dart`
- Modify: (findings-driven) the UI file(s) whose widgets overflow in Spanish — e.g. `lib/src/features/workspace/overview_tab.dart` or others the test names.

**Interfaces:**
- Consumes: the existing `_pumpInSpanish`/`_expectNoOverflow` harness; `ProjectAwareInstance` (`lib/src/features/gcloud_provider.dart`) + `GcpInstance` (`lib/src/bridge/api.dart/gcloud.dart`) per `test/workspace_provider_test.dart`; `OverviewTab({required ProjectAwareInstance target})`.

- [ ] **Step 1: Add the narrow size**

In `test/es_overflow_test.dart`, add a third entry to `_sizes`:

```dart
const _sizes = <String, Size>{
  'desktop 1280x800': Size(1280, 800),
  'small 1024x640': Size(1024, 640),
  'narrow 720x800': Size(720, 800),
};
```

- [ ] **Step 2: Add the OverviewTab surface + fake VM**

In `test/es_overflow_test.dart`, add the imports (near the others):

```dart
import 'package:linux_cloud_connector/src/features/workspace/overview_tab.dart';
import 'package:linux_cloud_connector/src/features/gcloud_provider.dart';
import 'package:linux_cloud_connector/src/bridge/api.dart/gcloud.dart';
```

Add a fake-VM helper (above `_dialogs`), mirroring `test/workspace_provider_test.dart`'s `_vm` with a long, Spanish-flavored name to stress width:

```dart
ProjectAwareInstance _fakeVm() => ProjectAwareInstance(
      projectId: _project,
      instance: GcpInstance(
        name: 'instancia-de-produccion-backup-01',
        status: 'RUNNING',
        zone: _zone,
        machineType: 'e2-standard-4',
        cpuCount: 4,
        memoryMb: 16384,
        diskGb: 100,
        labels: const [],
        osLoginEnabled: false,
        isWindows: false,
      ),
    );
```

Add the surface to the `_dialogs` map:

```dart
  'OverviewTab': () => OverviewTab(target: _fakeVm()),
```

- [ ] **Step 3: Run the extended test and verify OverviewTab actually renders**

Run: `flutter test test/es_overflow_test.dart 2>&1 | tail -40`

Two things to confirm:
1. **OverviewTab renders its content headless** (not a hollow pass). If unsure, temporarily add an assertion in the OverviewTab test path, or run with `-r expanded`, and confirm the tab's action area lays out. If `OverviewTab` shows only a placeholder/loading/error state (its providers gate the action buttons), seed the minimal provider in `_pumpInSpanish`'s `ProviderScope` via an `overrides:` entry so the buttons render — otherwise the overflow coverage is hollow. (If a bridge-backed provider throws synchronously during build and cannot be seeded meaningfully, document `OverviewTab` in the existing `_needsLiveApp` skip set with a one-line reason instead of shipping a hollow test — but prefer making it render.)
2. **Which surfaces (if any) report `overflowed in Spanish`** at any of the 3 sizes.

- [ ] **Step 4: Fix each reported overflow (findings-driven)**

For every failure of the form `<Surface> overflowed in Spanish: A RenderFlex overflowed by N pixels …`:
- Read the surface's widget code; the Flutter error names the axis (horizontal/vertical) and the overflowing `RenderFlex`.
- Apply the **minimal** fix:
  - Horizontal `Row` overflow → change the `Row` to a `Wrap`, or wrap the long `Text`/child in `Flexible`/`Expanded` and add `overflow: TextOverflow.ellipsis` (+ `maxLines: 1`/`2`) to the `Text`.
  - Vertical `Column` overflow → make the container scrollable (`SingleChildScrollView`) or the overflowing child `Flexible`.
  - Long label in a chip/button → `overflow: TextOverflow.ellipsis` + `maxLines`.
- Do NOT redesign the layout or change behavior; keep the fix as small as the SettingsDialog `Row`→`Wrap` precedent.

- [ ] **Step 5: Re-run until green**

Run: `flutter test test/es_overflow_test.dart 2>&1 | tail -20`
Expected: all cases pass at all 3 sizes (no `overflowed in Spanish`). Repeat Step 4 for any remaining overflow.

- [ ] **Step 6: Full suite + analyze**

Run: `flutter test 2>&1 | tail -12`
Expected: the whole suite stays green.

Run: `flutter analyze 2>&1 | tail -8`
Expected: 0 errors; no new issue in the touched files.

- [ ] **Step 7: Commit**

```bash
cd /home/jlopezre/GitHub/LCC
git add test/es_overflow_test.dart lib/
git commit -m "test(i18n): cover OverviewTab + narrow width in the ES overflow suite"
```
(If Step 4 made UI fixes, they are staged by `git add lib/` and belong in this same commit — the commit message still fits, since the fixes exist to make the new coverage pass. If there were zero fixes, only the test file is staged.)

---

### Task 2: Manual QA checklist for the deferred surfaces

The extended automated test covers 10 dialogs + OverviewTab; the surfaces it cannot reach headlessly still need a human eye in Spanish.

**Files:**
- Create: `docs/superpowers/plans/2026-08-06-es-visual-qa-manual-qa.md`

- [ ] **Step 1: Confirm the gate**

Run: `flutter test test/es_overflow_test.dart 2>&1 | tail -6` — Expected: all pass (incl. OverviewTab at 720).
Run: `flutter analyze 2>&1 | tail -6` — Expected: 0 errors, no new issues.

- [ ] **Step 2: Write the manual QA checklist**

Create `docs/superpowers/plans/2026-08-06-es-visual-qa-manual-qa.md`:

```markdown
# Manual QA — ES visual (deferred surfaces)

The automated `es_overflow_test` now covers 10 dialogs + the Overview tab in
Spanish at 1280/1024/720 widths. These surfaces can't be pumped headlessly
(providers/bridge or inline dialogs) — check them by eye in Spanish, ideally
at a narrow window:

- [ ] Workspace tab strip: tab labels ("<vm> · Resumen", "· Diagnóstico", "· Reenvío SSH"/SFTP/SSH) don't overflow or clip the strip; the overflow arrows/all-tabs menu appear when needed.
- [ ] Custom Tunnel dialog: the mode selector, the local-port field, the port presets/chips, and the dedup warning snackbar all fit in Spanish.
- [ ] Full dashboard: the ResourceTree (left) + the WorkspacePanel (right) header/labels/buttons in Spanish at a narrow window.
- [ ] Windows Credentials / SSHFS Mount dialogs (skipped in the automated suite): fields/labels/buttons fit in Spanish.
- [ ] Desktop notifications in Spanish (from SP1) aren't truncated by the OS notification width.
```

- [ ] **Step 3: Commit**

```bash
cd /home/jlopezre/GitHub/LCC
git add docs/superpowers/plans/2026-08-06-es-visual-qa-manual-qa.md
git commit -m "docs(qa): manual QA checklist for ES visual (deferred surfaces)"
```

---

## Self-Review

**1. Spec coverage:**
- Add `narrow 720x800` size → Task 1 Step 1. ✓
- Add `OverviewTab(target: _fakeVm())` + imports + fake VM → Task 1 Step 2. ✓
- Verify OverviewTab renders (avoid hollow coverage); seed/skip if needed → Task 1 Step 3. ✓
- Findings-driven minimal fixes (Wrap/Flexible/ellipsis) for each reported overflow → Task 1 Step 4-5. ✓
- May be zero fixes → Task 1 Step 7 note. ✓
- Verification: es_overflow_test + full suite + analyze → Task 1 Steps 5-6 + Task 2. ✓
- Deferred surfaces (tab strip, Custom Tunnel, dashboard, live-only dialogs) → Task 2 manual QA. ✓
- Dart-only → no cargo/bridge. ✓

**2. Placeholder scan:** No TBD/TODO. Task 1's concrete part (sizes, imports, `_fakeVm`, the surface entry) is complete code; the fix step is genuinely findings-driven (the overflows aren't known until the extended test runs) and gives the exact fix patterns + the SettingsDialog precedent, not a vague "handle overflow". ✓

**3. Type consistency:** `_fakeVm()` returns `ProjectAwareInstance` built from `GcpInstance(name, status, zone, machineType, cpuCount, memoryMb, diskGb, labels, osLoginEnabled, isWindows)` — matches `test/workspace_provider_test.dart`'s `_vm`. `OverviewTab({required ProjectAwareInstance target})` matches its constructor (`overview_tab.dart:34`). `_sizes`/`_dialogs`/`_pumpInSpanish` names match the existing harness. ✓
