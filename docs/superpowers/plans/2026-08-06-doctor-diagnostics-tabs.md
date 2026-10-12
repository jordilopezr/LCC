# Doctor + Diagnostics Workspace Tabs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the Connectivity Doctor and Diagnostics panel from modal dialogs into persistent workspace tabs (alongside SSH terminal and SFTP), so reports survive tab switches and reopening focuses the existing tab.

**Architecture:** Extract each dialog's inner content into a reusable View widget parameterized by `(projectId, zone, instanceName)`; the dialog becomes a thin wrapper (header + close + View) so the ResourceTree right-click menu keeps working, and new `DoctorTab`/`DiagnosticsTab` render the same Views inside the workspace `IndexedStack` (which already keeps each tab's State alive). Two new `SessionType`s with dedup-and-focus `open*` methods; a `_holdsTunnel` predicate replaces the `type != overview` proxy so the tunnel-free Doctor/Diagnostics tabs neither release tunnels nor count as live sessions.

**Tech Stack:** Flutter, Riverpod (Notifier), flutter gen-l10n. Spec: `docs/superpowers/specs/2026-08-06-doctor-diagnostics-tabs-design.md`.

## Global Constraints

- **Dart-only.** No Rust changes, no flutter_rust_bridge regen, no `cargo`. Do NOT run `dart format` (it reflows whole files; make targeted edits only).
- The modal dialogs stay: `showConnectivityDoctor` and `showDiagnosticsPanel` keep their exact signatures and are still used by `main.dart`'s ResourceTree right-click menu — do NOT touch `main.dart`.
- Extracted Views and the dialogs that wrap them must share one implementation (no duplicated Doctor/Diagnostics logic).
- New i18n keys: `workspaceTabDoctor` (EN `"Doctor"`, ES `"Doctor"`) and `workspaceTabDiagnostics` (EN `"Diagnostics"`, ES `"Diagnóstico"`). Regenerate with `flutter gen-l10n` (arb-dir `lib/l10n`, template `app_en.arb`, output class `AppLocalizations`).
- Doctor/Diagnostics tabs hold NO IAP tunnel (pure GCP REST); they behave like `overview` for tunnel ref-counting and the close-workspace guard.
- Commits touching code must NOT carry the `Co-Authored-By: Claude` trailer (that is for documentation commits only).
- Branch: `27H1-Preview` (already checked out).

---

### Task 1: Extract `ConnectivityDoctorView` from the Doctor dialog

Split `connectivity_doctor.dart` so all run/report/State logic lives in a reusable `ConnectivityDoctorView`; `ConnectivityDoctorDialog` becomes a thin wrapper that adds the dialog chrome (rounded header with title/instance + close button). No behavior change — the dialog still auto-runs and looks identical.

**Files:**
- Modify: `lib/src/features/connectivity_doctor.dart`

**Interfaces:**
- Produces (used by Task 3): `class ConnectivityDoctorView extends ConsumerStatefulWidget { final String projectId; final String zone; final String instanceName; const ConnectivityDoctorView({super.key, required this.projectId, required this.zone, required this.instanceName}); }`
- Unchanged: `Future<void> showConnectivityDoctor(BuildContext, {required String projectId, required String zone, required String instanceName})`.

- [ ] **Step 1: Rename the State class and its widget to the View**

In `lib/src/features/connectivity_doctor.dart`, rename the existing `class ConnectivityDoctorDialog extends ConsumerStatefulWidget` to `class ConnectivityDoctorView extends ConsumerStatefulWidget` (keep its three fields `projectId`/`zone`/`instanceName` and constructor), and rename `_ConnectivityDoctorDialogState` to `_ConnectivityDoctorViewState` (and its `createState`). Leave ALL State members verbatim (`_report`, `_isRunning`, `_error`, `initState`→`_runDoctor`, `_runDoctor`, `_exportReport`, `_executeFix`, `_buildBody`, `_buildCategorySection`, `_categoryIcon`, `_categoryDisplayName`). The top-level helper classes `_SummaryChip` and `_DoctorCheckTile` stay unchanged.

- [ ] **Step 2: Strip the dialog chrome out of the View's `build`**

In `_ConnectivityDoctorViewState.build`, replace the returned `Dialog(child: ConstrainedBox(constraints: ..., child: Column(children: [ <header>, <action bar>, Divider, Expanded(body), <footer> ])))` so the View returns only the inner content — delete the `Dialog`, the `ConstrainedBox`, and the entire header `Container` (the one with `Icons.medical_services_outlined`, the title, the instance name, and the `IconButton(Icons.close → Navigator.pop)`). The View's `build` now returns:

```dart
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Column(
      children: [
        // Action bar (Run Again / Export / summary chips) — unchanged content
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(children: [ /* ...existing action bar children verbatim... */ ]),
        ),
        const Divider(height: 1),
        Expanded(child: _buildBody(theme, l10n)),
        if (_report != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
            ),
            child: Row(children: [ /* ...existing footer children verbatim... */ ]),
          ),
      ],
    );
  }
```

Keep the action-bar and footer *children* exactly as they are today; only the outer `Dialog`/`ConstrainedBox`/header and the footer's bottom `borderRadius` (drop it — no longer a dialog corner) change.

- [ ] **Step 3: Add the thin `ConnectivityDoctorDialog` wrapper**

Add a new stateless dialog that wraps the View with the chrome that was removed in Step 2, immediately above `showConnectivityDoctor`:

```dart
/// Modal wrapper around [ConnectivityDoctorView] for the ResourceTree
/// right-click menu. The workspace uses [ConnectivityDoctorView] directly.
class ConnectivityDoctorDialog extends StatelessWidget {
  final String projectId;
  final String zone;
  final String instanceName;

  const ConnectivityDoctorDialog({
    super.key,
    required this.projectId,
    required this.zone,
    required this.instanceName,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 700),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: Row(
                children: [
                  Icon(Icons.medical_services_outlined,
                      size: 28, color: theme.colorScheme.onPrimaryContainer),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l10n.doctorTitle,
                            style: theme.textTheme.titleLarge?.copyWith(
                                color: theme.colorScheme.onPrimaryContainer)),
                        Text(instanceName,
                            style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onPrimaryContainer
                                    .withAlpha(178))),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ConnectivityDoctorView(
                projectId: projectId,
                zone: zone,
                instanceName: instanceName,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

`showConnectivityDoctor` already builds `ConnectivityDoctorDialog(projectId: ..., zone: ..., instanceName: ...)` — leave it unchanged; it now resolves to this wrapper.

- [ ] **Step 4: Verify analyze is clean**

Run: `flutter analyze lib/src/features/connectivity_doctor.dart`
Expected: "No issues found!" (No bridge-mock harness exists for this auto-running widget, so verification is static; the dialog's runtime behavior is unchanged because the moved State code is verbatim.)

- [ ] **Step 5: Commit**

```bash
cd /home/jlopezre/GitHub/LCC
git add lib/src/features/connectivity_doctor.dart
git commit -m "refactor(doctor): extract ConnectivityDoctorView; dialog wraps it"
```

---

### Task 2: Extract `DiagnosticsView` from the Diagnostics panel

Split `diagnostics_panel.dart` the same way: the `TabController` + TabBar/TabBarView move into `DiagnosticsView`; `DiagnosticsPanel` becomes a thin wrapper adding the header + close.

**Files:**
- Modify: `lib/src/features/diagnostics_panel.dart`

**Interfaces:**
- Consumes: existing `class DiagnosticsParams { final String projectId, zone, instanceName; const DiagnosticsParams({...}); }`, and the sub-tab widgets `SerialConsoleTab`, `VmDiagnosticsTab`, `AuditLogsTab` (each `{required DiagnosticsParams params}`).
- Produces (used by Task 3): `class DiagnosticsView extends ConsumerStatefulWidget { final DiagnosticsParams params; const DiagnosticsView({super.key, required this.params}); }`
- Unchanged: `Future<void> showDiagnosticsPanel(BuildContext, {required String projectId, required String zone, required String instanceName})`.

- [ ] **Step 1: Rename the State class and its widget to the View**

Rename `class DiagnosticsPanel extends ConsumerStatefulWidget` to `class DiagnosticsView extends ConsumerStatefulWidget` (keep the `final DiagnosticsParams params;` field + constructor), and rename `_DiagnosticsPanelState` to `_DiagnosticsViewState` (keep `with SingleTickerProviderStateMixin`, the `_tabController` field, `initState`, and `dispose` verbatim).

- [ ] **Step 2: Strip the dialog chrome out of the View's `build`**

In `_DiagnosticsViewState.build`, delete the `Dialog`, the `SizedBox(width: 900, height: 700, ...)`, and the header `Container` (the one with `Icons.build_circle_outlined`, `l10n.diagTitle`, `l10n.diagSubtitle(...)`, and the `IconButton(Icons.close → Navigator.of(context).pop())`). The View returns only the tab bar + content:

```dart
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      children: [
        TabBar(
          controller: _tabController,
          tabs: [
            Tab(icon: const Icon(Icons.terminal), text: l10n.diagTabSerialConsole),
            Tab(icon: const Icon(Icons.info_outline), text: l10n.diagTabDiagnostics),
            Tab(icon: const Icon(Icons.history), text: l10n.diagTabAuditLogs),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              SerialConsoleTab(params: widget.params),
              VmDiagnosticsTab(params: widget.params),
              AuditLogsTab(params: widget.params),
            ],
          ),
        ),
      ],
    );
  }
```

- [ ] **Step 3: Add the thin `DiagnosticsPanel` wrapper**

Add a new stateless dialog above `showDiagnosticsPanel`:

```dart
/// Modal wrapper around [DiagnosticsView] for the ResourceTree right-click
/// menu. The workspace uses [DiagnosticsView] directly.
class DiagnosticsPanel extends StatelessWidget {
  final DiagnosticsParams params;

  const DiagnosticsPanel({super.key, required this.params});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Dialog(
      child: SizedBox(
        width: 900,
        height: 700,
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(12),
                  topRight: Radius.circular(12),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.build_circle_outlined, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l10n.diagTitle,
                            style: Theme.of(context).textTheme.titleLarge),
                        Text(
                          l10n.diagSubtitle(
                              params.instanceName, params.zone),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Expanded(child: DiagnosticsView(params: params)),
          ],
        ),
      ),
    );
  }
}
```

`showDiagnosticsPanel` already builds `DiagnosticsPanel(params: DiagnosticsParams(...))` — leave it unchanged.

- [ ] **Step 4: Verify analyze is clean**

Run: `flutter analyze lib/src/features/diagnostics_panel.dart`
Expected: "No issues found!"

- [ ] **Step 5: Commit**

```bash
cd /home/jlopezre/GitHub/LCC
git add lib/src/features/diagnostics_panel.dart
git commit -m "refactor(diagnostics): extract DiagnosticsView; dialog wraps it"
```

---

### Task 3: Add the two workspace session types end-to-end

Extend `SessionType` with `doctor`/`diagnostics`, add dedup `open*` methods and the `_holdsTunnel` predicate, create the two tab widgets, wire the three `workspace_panel.dart` switches, add the i18n keys, and cover the notifier logic with tests. The enum extension and the switch updates land together so the package always compiles.

**Files:**
- Modify: `lib/src/features/workspace/workspace_session.dart`
- Modify: `lib/src/features/workspace/workspace_provider.dart`
- Modify: `lib/src/features/workspace/workspace_panel.dart`
- Create: `lib/src/features/workspace/doctor_tab.dart`
- Create: `lib/src/features/workspace/diagnostics_tab.dart`
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_es.arb`
- Test: `test/workspace_provider_test.dart`

**Interfaces:**
- Consumes: `ConnectivityDoctorView` (Task 1), `DiagnosticsView` + `DiagnosticsParams` (Task 2); existing `WorkspaceSession`, `ProjectAwareInstance` (fields `projectId`, `zone`, `name`, `uniqueKey`), `WorkspaceNotifier._find`, `_add`, `_newId`, `focus`.
- Produces (used by Task 4): `String openDoctor(ProjectAwareInstance vm)`, `String openDiagnostics(ProjectAwareInstance vm)`.

- [ ] **Step 1: Extend the `SessionType` enum**

In `lib/src/features/workspace/workspace_session.dart`:

```dart
enum SessionType { overview, ssh, sftp, doctor, diagnostics }
```

- [ ] **Step 2: Add the i18n keys and regenerate**

In `lib/l10n/app_en.arb`, after the `"workspaceTabSftp": "SFTP",` line add:

```json
  "workspaceTabDoctor": "Doctor",
  "workspaceTabDiagnostics": "Diagnostics",
```

In `lib/l10n/app_es.arb`, after the `"workspaceTabSftp": "SFTP",` line add:

```json
  "workspaceTabDoctor": "Doctor",
  "workspaceTabDiagnostics": "Diagnóstico",
```

(Watch JSON comma syntax — if `workspaceTabSftp` is the last entry in an object, add a comma after it.) Then regenerate:

Run: `flutter gen-l10n`
Expected: regenerates `lib/l10n/gen/app_localizations.dart` (and locale files) with `String get workspaceTabDoctor` and `String get workspaceTabDiagnostics`. Do not hand-edit generated files.

- [ ] **Step 3: Create `DoctorTab`**

Create `lib/src/features/workspace/doctor_tab.dart`:

```dart
import 'package:flutter/material.dart';
import '../connectivity_doctor.dart';
import 'workspace_session.dart';

/// Workspace tab that hosts the Connectivity Doctor for a VM. Holds no tunnel;
/// its report persists across tab switches via the panel's IndexedStack.
class DoctorTab extends StatelessWidget {
  final WorkspaceSession session;
  const DoctorTab({super.key, required this.session});

  @override
  Widget build(BuildContext context) => ConnectivityDoctorView(
        projectId: session.target.projectId,
        zone: session.target.zone,
        instanceName: session.target.name,
      );
}
```

- [ ] **Step 4: Create `DiagnosticsTab`**

Create `lib/src/features/workspace/diagnostics_tab.dart`:

```dart
import 'package:flutter/material.dart';
import '../diagnostics_panel.dart';
import 'workspace_session.dart';

/// Workspace tab that hosts the Diagnostics panel for a VM. Holds no tunnel;
/// its sub-tab state persists across tab switches via the panel's IndexedStack.
class DiagnosticsTab extends StatelessWidget {
  final WorkspaceSession session;
  const DiagnosticsTab({super.key, required this.session});

  @override
  Widget build(BuildContext context) => DiagnosticsView(
        params: DiagnosticsParams(
          projectId: session.target.projectId,
          zone: session.target.zone,
          instanceName: session.target.name,
        ),
      );
}
```

- [ ] **Step 5: Add `openDoctor`/`openDiagnostics` to the notifier**

In `lib/src/features/workspace/workspace_provider.dart`, add after `openSftp` (they dedup like `openOverview`/`openSftp`, and pass no `holdsTunnel`):

```dart
  String openDoctor(ProjectAwareInstance vm) {
    final existing = _find(
        (s) => s.type == SessionType.doctor && s.vmKey == vm.uniqueKey);
    if (existing != null) {
      focus(existing.id);
      return existing.id;
    }
    return _add(WorkspaceSession(
        id: _newId(), type: SessionType.doctor, target: vm));
  }

  String openDiagnostics(ProjectAwareInstance vm) {
    final existing = _find(
        (s) => s.type == SessionType.diagnostics && s.vmKey == vm.uniqueKey);
    if (existing != null) {
      focus(existing.id);
      return existing.id;
    }
    return _add(WorkspaceSession(
        id: _newId(), type: SessionType.diagnostics, target: vm));
  }
```

- [ ] **Step 6: Wire the three `workspace_panel.dart` switches**

In `lib/src/features/workspace/workspace_panel.dart`, add the imports near the other tab imports:

```dart
import 'doctor_tab.dart';
import 'diagnostics_tab.dart';
```

Add the `_content` cases (in `WorkspacePanel._content`, inside `switch (s.type)`):

```dart
      case SessionType.doctor:
        return DoctorTab(session: s);
      case SessionType.diagnostics:
        return DiagnosticsTab(session: s);
```

Add the `_PinnedZone._icon` cases (inside its `switch (t)`):

```dart
        SessionType.doctor => Icons.medical_services_outlined,
        SessionType.diagnostics => Icons.build_circle_outlined,
```

Add the `_tabLabel` cases (inside its `switch (s.type)`):

```dart
    SessionType.doctor => l10n.workspaceTabDoctor,
    SessionType.diagnostics => l10n.workspaceTabDiagnostics,
```

- [ ] **Step 7: Write the notifier tests**

In `test/workspace_provider_test.dart`, add these tests inside `main()` (they reuse the file's existing `_FakeConnections fake`, `container`, `wn()`, `ws()`, and `_vm(name)` helpers):

```dart
  test('openDoctor and openDiagnostics dedup per VM and focus existing', () {
    final a = _vm('vm1');
    final d1 = wn().openDoctor(a);
    final d2 = wn().openDoctor(a); // same VM → focus, no new tab
    expect(d1, d2);
    expect(ws().sessions.where((s) => s.type == SessionType.doctor).length, 1);

    final g1 = wn().openDiagnostics(a);
    final g2 = wn().openDiagnostics(a);
    expect(g1, g2);
    expect(
        ws().sessions.where((s) => s.type == SessionType.diagnostics).length, 1);
    expect(ws().activeId, g1); // focus followed the re-open
  });

  test('doctor/diagnostics tabs are not live sessions', () {
    final a = _vm('vm1');
    wn().openOverview(a);
    wn().openDoctor(a);
    wn().openDiagnostics(a);
    expect(wn().hasLiveSessions, isFalse);
  });

  test('closing a doctor/diagnostics tab releases no tunnel', () {
    final a = _vm('vm1');
    final d = wn().openDoctor(a);
    final g = wn().openDiagnostics(a);
    wn().close(d);
    wn().close(g);
    expect(fake.disconnects, isEmpty);
  });
```

- [ ] **Step 8: Run the new tests — expect the last two to FAIL (RED)**

Run: `flutter test test/workspace_provider_test.dart`
Expected: `openDoctor and openDiagnostics dedup...` PASSES; `doctor/diagnostics tabs are not live sessions` and `closing a doctor/diagnostics tab releases no tunnel` FAIL — because `hasLiveSessions` and `close()` still use the `type != SessionType.overview` proxy, so a `doctor` session counts as live and its close attempts a `disconnect`.

- [ ] **Step 9: Introduce `_holdsTunnel` and swap it into `close`/`hasLiveSessions`**

In `lib/src/features/workspace/workspace_provider.dart`:

Add the predicate (near the top of the notifier, e.g. after `_find`):

```dart
  /// Whether a session type owns an IAP tunnel (ref-counted on open/close).
  /// Overview/Doctor/Diagnostics are pure REST views and hold none.
  bool _holdsTunnel(SessionType t) =>
      t == SessionType.ssh || t == SessionType.sftp;
```

In `close`, change the tunnel-release guard from:

```dart
    if (session.type != SessionType.overview) {
```

to:

```dart
    if (_holdsTunnel(session.type)) {
```

In `hasLiveSessions`, change:

```dart
  bool get hasLiveSessions =>
      state.sessions.any((s) => s.type != SessionType.overview);
```

to:

```dart
  bool get hasLiveSessions =>
      state.sessions.any((s) => _holdsTunnel(s.type));
```

- [ ] **Step 10: Run the tests — all GREEN, plus analyze**

Run: `flutter test test/workspace_provider_test.dart`
Expected: all tests pass (including the two that failed in Step 8).

Run: `flutter analyze`
Expected: "No issues found!" — in particular the three `switch`es in `workspace_panel.dart` are exhaustive over the extended enum (a missing case would be a compile error here), which is the compiler-level guarantee that the panel handles the new types.

- [ ] **Step 11: Commit**

```bash
cd /home/jlopezre/GitHub/LCC
git add lib/src/features/workspace/workspace_session.dart \
        lib/src/features/workspace/workspace_provider.dart \
        lib/src/features/workspace/workspace_panel.dart \
        lib/src/features/workspace/doctor_tab.dart \
        lib/src/features/workspace/diagnostics_tab.dart \
        lib/l10n/app_en.arb lib/l10n/app_es.arb lib/l10n/gen/ \
        test/workspace_provider_test.dart
git commit -m "feat(workspace): Doctor and Diagnostics session types + tabs"
```

---

### Task 4: Re-wire the Overview launch points to open tabs

Change the three in-workspace call sites in `overview_tab.dart` from opening dialogs to opening (deduped) workspace tabs. `main.dart`'s right-click menu is intentionally left on dialogs.

**Files:**
- Modify: `lib/src/features/workspace/overview_tab.dart`

**Interfaces:**
- Consumes: `openDoctor`/`openDiagnostics` (Task 3); `ref.read(workspaceProvider.notifier)` (already imported and used for `openSsh`/`openSftp`); `widget.target` (a `ProjectAwareInstance`) and the local `target` in the action-button scope (also a `ProjectAwareInstance` — it is already passed to `openSsh(target)`/`openSftp(target)`).

- [ ] **Step 1: Diagnostics button → `openDiagnostics`**

In `lib/src/features/workspace/overview_tab.dart`, in the Diagnostics `_ActionButton` `onPressed` (around line 638), replace:

```dart
                        showDiagnosticsPanel(
                          context,
                          projectId: selectedProject,
                          zone: target.zone,
                          instanceName: target.name,
                        );
```

with:

```dart
                        ref
                            .read(workspaceProvider.notifier)
                            .openDiagnostics(target);
```

- [ ] **Step 2: Doctor button → `openDoctor`**

In the Connectivity Doctor `_ActionButton` `onPressed` (around line 655), replace:

```dart
                        showConnectivityDoctor(
                          context,
                          projectId: selectedProject,
                          zone: target.zone,
                          instanceName: target.name,
                        );
```

with:

```dart
                        ref.read(workspaceProvider.notifier).openDoctor(target);
```

- [ ] **Step 3: Custom Tunnel "Run Doctor" → `openDoctor`**

In `_showCustomTunnelError` (the "Run Doctor" action, around line 1256), keep the `Navigator.pop(dialogContext);` and replace the following `showConnectivityDoctor(context, projectId: projectId, zone: zone, instanceName: instanceName);` with:

```dart
              Navigator.pop(dialogContext);
              ref.read(workspaceProvider.notifier).openDoctor(widget.target);
```

(The Custom Tunnel dialog is always for the current Overview VM, so `widget.target.name == instanceName`.)

- [ ] **Step 4: Remove now-unused imports if analyze flags them**

Run: `flutter analyze lib/src/features/workspace/overview_tab.dart`
Expected: "No issues found!". If it reports unused imports for `../connectivity_doctor.dart` and/or `../diagnostics_panel.dart` (because `showConnectivityDoctor`/`showDiagnosticsPanel` are no longer referenced here), delete those two import lines and re-run until clean. Do NOT remove any import still used for another symbol.

- [ ] **Step 5: Run the full suite**

Run: `flutter test`
Expected: all tests pass (the notifier tests from Task 3 plus the existing suite).

- [ ] **Step 6: Commit**

```bash
cd /home/jlopezre/GitHub/LCC
git add lib/src/features/workspace/overview_tab.dart
git commit -m "feat(workspace): open Doctor/Diagnostics as tabs from Overview"
```

---

### Task 5: Full gate + manual QA checklist

Verify the whole change compiles, tests pass, and the release bundle builds; capture the manual checks that automated tests cannot (bridge-driven UI, persistence, ES labels).

**Files:**
- Create: `docs/superpowers/plans/2026-08-06-doctor-diagnostics-tabs-manual-qa.md`

- [ ] **Step 1: Analyze + full test suite**

Run: `flutter analyze`
Expected: "No issues found!"

Run: `flutter test`
Expected: all tests pass, output pristine.

- [ ] **Step 2: Release build**

Run: `flutter build linux --release`
Expected: `✓ Built build/linux/x64/release/bundle/lightweight_cloud_connector`.

- [ ] **Step 3: Write the manual QA checklist**

Create `docs/superpowers/plans/2026-08-06-doctor-diagnostics-tabs-manual-qa.md` with this content:

```markdown
# Manual QA — Doctor + Diagnostics as workspace tabs

Run on a real desktop with a reachable GCP VM.

- [ ] Overview → Diagnostics button opens a **Diagnostics** tab (not a dialog); the tab strip shows `<vm> · Diagnostics`.
- [ ] Overview → Connectivity Doctor button opens a **Doctor** tab; it auto-runs and shows the report.
- [ ] Switch to another tab and back → the Doctor report is still there (no re-run). Same for the Diagnostics sub-tabs.
- [ ] Press "Run Again" in the Doctor tab → it re-runs in place.
- [ ] Click the Doctor button again for the same VM → focuses the existing Doctor tab (no duplicate). Same for Diagnostics.
- [ ] Open only a Doctor and/or Diagnostics tab (no SSH/SFTP), then close the workspace / trigger the close-with-sessions guard → **no** "live sessions" warning (they hold no tunnel).
- [ ] Close a Doctor/Diagnostics tab → no tunnel/disconnect side effects on the VM's SSH/SFTP tabs.
- [ ] Custom Tunnel failure dialog → "Run Doctor" closes the dialog and opens a Doctor tab.
- [ ] ResourceTree right-click menu → Diagnostics / Doctor still open **modal dialogs** (unchanged).
- [ ] Spanish locale: tab labels read `Doctor` and `Diagnóstico`.
- [ ] Pin and group a Doctor/Diagnostics tab (right-click the tab) → works like other tabs.
```

- [ ] **Step 4: Commit**

```bash
cd /home/jlopezre/GitHub/LCC
git add docs/superpowers/plans/2026-08-06-doctor-diagnostics-tabs-manual-qa.md
git commit -m "docs(qa): manual QA checklist for Doctor/Diagnostics tabs"
```

---

## Self-Review

**1. Spec coverage:**
- Extract `ConnectivityDoctorView`, dialog wraps it → Task 1. ✓
- Extract `DiagnosticsView`, dialog wraps it → Task 2. ✓
- `showConnectivityDoctor`/`showDiagnosticsPanel` unchanged signatures, still used by main.dart → Tasks 1-2 (wrappers), main.dart untouched (Global Constraints + Task 4 leaves it alone). ✓
- `SessionType.doctor/diagnostics` → Task 3 Step 1. ✓
- `DoctorTab`/`DiagnosticsTab` reading `session.target` → Task 3 Steps 3-4. ✓
- `openDoctor`/`openDiagnostics` dedup, no tunnel → Task 3 Step 5 + tests Step 7. ✓
- `_holdsTunnel` swapped into `close`/`hasLiveSessions` → Task 3 Step 9 (TDD RED at Step 8). ✓
- Panel switches `_content`/`_icon`/`_tabLabel` → Task 3 Step 6. ✓
- Re-wire the 3 Overview call sites → Task 4. ✓
- i18n keys + gen-l10n → Task 3 Step 2. ✓
- Notifier tests + (compiler-guaranteed) panel exhaustiveness → Task 3 Steps 7-10. (No widget smoke: the auto-running, bridge-calling Views cannot be reliably pumped without a bridge mock; exhaustive switches are a compile-time guarantee and analyze covers it.) ✓
- Verification: analyze + full test + release build → Task 5. ✓
- Dart-only, no Rust/bridge → no task runs cargo or codegen beyond `flutter gen-l10n`. ✓

**2. Placeholder scan:** No TBD/TODO; every code step carries the actual code or the exact structural edit with the surrounding anchors. The two large extractions (Tasks 1-2) name the exact members to move verbatim and give the full new wrapper + the View's new `build` shell. ✓

**3. Type consistency:** `ConnectivityDoctorView({projectId, zone, instanceName})` (Task 1) is consumed exactly by `DoctorTab` (Task 3 Step 3). `DiagnosticsView({params: DiagnosticsParams})` (Task 2) is consumed by `DiagnosticsTab` (Task 3 Step 4). `openDoctor`/`openDiagnostics` signatures (Task 3 Step 5) match their calls (Task 4). `_holdsTunnel(SessionType)` (Step 9) matches its uses in `close`/`hasLiveSessions`. `ProjectAwareInstance` fields `projectId`/`zone`/`name`/`uniqueKey` match existing usage in `sftp_tab.dart` and the notifier. ✓
