# Tab Strip Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the workspace tab strip into browser-style tab management — overflow navigation (scroll arrows + all-tabs menu + auto-scroll to active), pinned tabs, and MS Edge-style named/colored groups, with zone-constrained drag reorder.

**Architecture:** `WorkspaceState.sessions` remains the single canonical visual order. A pure `_canonicalOrder()` function (pinned first, group members contiguous) is applied after every mutation, so ordering invariants are enforced in one place and are directly unit-testable. `WorkspacePanel`'s `_TabStrip` is rewritten into small single-responsibility widgets (`_PinnedZone`, `_ScrollableTabs`, `_TabGroup`, `_Tab`, `_AllTabsMenu`). The `IndexedStack` content model and the per-VM tunnel ref-count are untouched.

**Tech Stack:** Flutter, Riverpod 3.x Notifier, gen-l10n (EN/ES parity), flutter_test.

## Global Constraints

- Branch `27H1`. All new/changed Dart lives under `lib/src/features/workspace/`, plus `lib/l10n/*.arb` and `test/`.
- Pure Dart — no Rust changes, no bridge regen, no `cargo build`.
- **Do NOT change branches** during execution (`git checkout`/`switch` are forbidden); commit on `27H1` only.
- Preserve the `IndexedStack` keep-mounted invariant (hidden tabs must not be disposed) — never switch to `TabBarView`.
- Preserve the tunnel ref-count: pin/group are pure UI; all closes (including bulk) go through the existing `close(id)`.
- i18n parity is enforced: append new keys to the END of BOTH `lib/l10n/app_en.arb` (template) and `lib/l10n/app_es.arb`, keeping valid JSON (fix the previous last entry's trailing comma). Neutral register. Ellipsis is `…`, never `...`. `@key` placeholder metadata blocks appear ONLY in `app_en.arb`. Run `flutter gen-l10n` after editing.
- `flutter analyze` must report 0 errors before every commit (78 pre-existing infos/warnings are acceptable and unchanged). `flutter test` must stay green.
- Verify constant: run `flutter test` for the whole suite at the end of each task that adds tests.

---

## File Structure

- `lib/src/features/workspace/workspace_session.dart` — MODIFY: add `pinned` + `groupId` fields and `copyWith` to `WorkspaceSession` (Task 3).
- `lib/src/features/workspace/workspace_group.dart` — CREATE: `GroupColor` enum + `WorkspaceGroup` model (Task 5).
- `lib/src/features/workspace/workspace_provider.dart` — MODIFY: `groups` in `WorkspaceState`; `_canonicalOrder`, pin/group/bulk-close methods on `WorkspaceNotifier` (Tasks 3, 5).
- `lib/src/features/workspace/workspace_panel.dart` — MODIFY/REWRITE `_TabStrip` into `_PinnedZone`, `_ScrollableTabs`, `_TabGroup`, `_Tab`, `_AllTabsMenu`, and the two context menus (Tasks 1, 2, 4, 6, 7).
- `lib/src/features/workspace/group_color_theme.dart` — CREATE: maps `GroupColor` → theme-aware `Color`s (Task 6).
- `lib/l10n/app_en.arb`, `lib/l10n/app_es.arb` — MODIFY: new keys (Tasks 1, 2, 4, 6).
- `test/workspace_provider_test.dart` — MODIFY: add pin/group/bulk-close/ordering unit tests (Tasks 3, 5).
- `test/workspace_panel_test.dart` — MODIFY: add overflow/auto-scroll/menu widget tests (Tasks 1, 2).

---

## Task 1: Scrollable strip with overflow arrows + auto-scroll to active

**Files:**
- Modify: `lib/src/features/workspace/workspace_panel.dart` (`_TabStrip`, `workspace_panel.dart:52-88`)
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_es.arb`
- Test: `test/workspace_panel_test.dart`

**Interfaces:**
- Consumes: existing `workspaceProvider`, `WorkspaceNotifier.focus/close`, `WorkspaceState.sessions/activeId`.
- Produces: `_ScrollableTabs` widget (a `StatefulWidget` owning a `ScrollController`) that renders the sessions row, shows `‹ ›` arrow buttons only when the content overflows, and calls `Scrollable.ensureVisible` on the active tab when it changes. `_Tab` is unchanged in this task.

- [ ] **Step 1: Add i18n keys for the arrow tooltips**

Append to `lib/l10n/app_en.arb` (before the closing `}`, adding a comma to the current last entry):
```json
"workspaceScrollTabsLeft": "Scroll tabs left",
"workspaceScrollTabsRight": "Scroll tabs right"
```
Append to `lib/l10n/app_es.arb`:
```json
"workspaceScrollTabsLeft": "Desplazar pestañas a la izquierda",
"workspaceScrollTabsRight": "Desplazar pestañas a la derecha"
```
Run: `flutter gen-l10n`
Expected: completes with no error.

- [ ] **Step 2: Write the failing widget test**

Add to `test/workspace_panel_test.dart` (keep the existing `_Probe` test). Add these imports at the top if missing:
```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:linux_cloud_connector/src/bridge/api.dart/gcloud.dart';
import 'package:linux_cloud_connector/src/features/gcloud_provider.dart';
import 'package:linux_cloud_connector/src/features/workspace/workspace_provider.dart';
import 'package:linux_cloud_connector/src/features/workspace/workspace_panel.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
```
Add this helper and test:
```dart
ProjectAwareInstance _vm(String name) => ProjectAwareInstance(
      projectId: 'p',
      instance: GcpInstance(
        name: name, status: 'RUNNING', zone: 'z', machineType: 'm',
        cpuCount: 1, memoryMb: 1, diskGb: 1, labels: const [],
        osLoginEnabled: false, isWindows: false,
      ),
    );

Widget _host(ProviderContainer c) => UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: SizedBox(width: 300, height: 200, child: WorkspacePanel())),
      ),
    );

void main2() {} // placeholder to avoid clobbering existing main(); see Step 3

testWidgets('overflow arrows appear only when tabs exceed width', (tester) async {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  final wn = c.read(workspaceProvider.notifier);
  // One tab: no overflow, no arrows.
  wn.openOverview(_vm('vm1'));
  await tester.pumpWidget(_host(c));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('scroll-left')), findsNothing);
  // Many tabs in a 300px panel: overflow, arrows visible.
  for (var i = 2; i <= 12; i++) {
    wn.openSsh(_vm('vm$i'));
  }
  await tester.pumpWidget(_host(c));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('scroll-left')), findsOneWidget);
  expect(find.byKey(const ValueKey('scroll-right')), findsOneWidget);
});
```
Note: the existing test file already has a `void main()`. Merge these `testWidgets(...)` calls INTO the existing `main()` body rather than adding a second `main()`; delete the `main2` placeholder. Put the `_vm`/`_host` helpers at top-level (outside `main`).

- [ ] **Step 3: Run the test to verify it fails**

Run: `flutter test test/workspace_panel_test.dart`
Expected: FAIL — `_ScrollableTabs`/keys `scroll-left`/`scroll-right` don't exist yet.

- [ ] **Step 4: Rewrite `_TabStrip` to use `_ScrollableTabs`**

In `lib/src/features/workspace/workspace_panel.dart`, replace the whole `_TabStrip` class (lines 52-88) with:
```dart
class _TabStrip extends StatelessWidget {
  final List<WorkspaceSession> sessions;
  final String? activeId;
  final WorkspaceNotifier notifier;
  const _TabStrip(
      {required this.sessions, required this.activeId, required this.notifier});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: _ScrollableTabs(
          sessions: sessions, activeId: activeId, notifier: notifier),
    );
  }
}

class _ScrollableTabs extends StatefulWidget {
  final List<WorkspaceSession> sessions;
  final String? activeId;
  final WorkspaceNotifier notifier;
  const _ScrollableTabs(
      {required this.sessions, required this.activeId, required this.notifier});

  @override
  State<_ScrollableTabs> createState() => _ScrollableTabsState();
}

class _ScrollableTabsState extends State<_ScrollableTabs> {
  final ScrollController _controller = ScrollController();
  final Map<String, GlobalKey> _tabKeys = {};
  bool _overflow = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_recomputeOverflow);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _recomputeOverflow();
      _ensureActiveVisible();
    });
  }

  @override
  void didUpdateWidget(covariant _ScrollableTabs old) {
    super.didUpdateWidget(old);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _recomputeOverflow();
      if (old.activeId != widget.activeId) _ensureActiveVisible();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _recomputeOverflow() {
    if (!_controller.hasClients) return;
    final can = _controller.position.maxScrollExtent > 0;
    if (can != _overflow) setState(() => _overflow = can);
  }

  void _ensureActiveVisible() {
    final id = widget.activeId;
    if (id == null) return;
    final key = _tabKeys[id];
    final ctx = key?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 200), alignment: 0.5);
    }
  }

  void _step(double delta) {
    if (!_controller.hasClients) return;
    final target = (_controller.offset + delta)
        .clamp(0.0, _controller.position.maxScrollExtent);
    _controller.animateTo(target,
        duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  }

  GlobalKey _keyFor(String id) => _tabKeys.putIfAbsent(id, () => GlobalKey());

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Row(children: [
      if (_overflow)
        IconButton(
          key: const ValueKey('scroll-left'),
          icon: const Icon(Icons.chevron_left, size: 18),
          tooltip: l10n.workspaceScrollTabsLeft,
          visualDensity: VisualDensity.compact,
          onPressed: () => _step(-160),
        ),
      Expanded(
        child: ListView(
          controller: _controller,
          scrollDirection: Axis.horizontal,
          children: [
            for (final s in widget.sessions)
              KeyedSubtree(
                key: _keyFor(s.id),
                child: _Tab(
                  label: _tabLabel(context, s),
                  active: s.id == widget.activeId,
                  onTap: () => widget.notifier.focus(s.id),
                  onClose: () => widget.notifier.close(s.id),
                  closeTooltip: l10n.workspaceCloseTab,
                ),
              ),
          ],
        ),
      ),
      if (_overflow)
        IconButton(
          key: const ValueKey('scroll-right'),
          icon: const Icon(Icons.chevron_right, size: 18),
          tooltip: l10n.workspaceScrollTabsRight,
          visualDensity: VisualDensity.compact,
          onPressed: () => _step(160),
        ),
    ]);
  }
}

String _tabLabel(BuildContext context, WorkspaceSession s) {
  final l10n = AppLocalizations.of(context);
  final kind = switch (s.type) {
    SessionType.overview => l10n.workspaceTabOverview,
    SessionType.ssh => l10n.workspaceTabSsh,
    SessionType.sftp => l10n.workspaceTabSftp,
  };
  return '${s.target.name} · $kind';
}
```
Leave the existing `_Tab` class (lines 90-133) unchanged.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `flutter analyze lib/src/features/workspace/workspace_panel.dart && flutter test test/workspace_panel_test.dart`
Expected: analyze 0 errors; both widget tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/src/features/workspace/workspace_panel.dart lib/l10n test/workspace_panel_test.dart
git commit -m "feat(workspace): scrollable tab strip with overflow arrows + auto-scroll to active"
```

---

## Task 2: "All tabs" overflow menu

**Files:**
- Modify: `lib/src/features/workspace/workspace_panel.dart` (`_ScrollableTabsState.build`)
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_es.arb`
- Test: `test/workspace_panel_test.dart`

**Interfaces:**
- Consumes: `WorkspaceState.sessions`, `WorkspaceNotifier.focus`, `_tabLabel` (Task 1).
- Produces: a `⌄` `PopupMenuButton` (`_AllTabsMenu`) trailing the strip, listing every tab; selecting one calls `focus(id)`.

- [ ] **Step 1: Add the i18n key**

`app_en.arb`: `"workspaceAllTabs": "All tabs"`
`app_es.arb`: `"workspaceAllTabs": "Todas las pestañas"`
Run: `flutter gen-l10n`

- [ ] **Step 2: Write the failing widget test**

Add to `test/workspace_panel_test.dart` `main()`:
```dart
testWidgets('all-tabs menu lists every tab and focuses on select', (tester) async {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  final wn = c.read(workspaceProvider.notifier);
  wn.openOverview(_vm('alpha'));
  final beta = wn.openSsh(_vm('beta'));
  await tester.pumpWidget(_host(c));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('all-tabs-menu')));
  await tester.pumpAndSettle();
  expect(find.text('beta · SSH'), findsWidgets);
  await tester.tap(find.text('beta · SSH').last);
  await tester.pumpAndSettle();
  expect(c.read(workspaceProvider).activeId, beta);
});
```

- [ ] **Step 3: Run to verify it fails**

Run: `flutter test test/workspace_panel_test.dart`
Expected: FAIL — no `all-tabs-menu` key.

- [ ] **Step 4: Add the menu to the strip**

In `_ScrollableTabsState.build`, add this widget as the LAST child of the outer `Row` (after the right arrow):
```dart
      PopupMenuButton<String>(
        key: const ValueKey('all-tabs-menu'),
        icon: const Icon(Icons.keyboard_arrow_down, size: 18),
        tooltip: l10n.workspaceAllTabs,
        onSelected: widget.notifier.focus,
        itemBuilder: (context) => [
          for (final s in widget.sessions)
            PopupMenuItem<String>(
              value: s.id,
              child: Text(_tabLabel(context, s)),
            ),
        ],
      ),
```

- [ ] **Step 5: Run tests**

Run: `flutter analyze lib/src/features/workspace/workspace_panel.dart && flutter test test/workspace_panel_test.dart`
Expected: analyze 0 errors; all widget tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/src/features/workspace/workspace_panel.dart lib/l10n test/workspace_panel_test.dart
git commit -m "feat(workspace): all-tabs overflow menu"
```

---

## Task 3: Pin data model + notifier + `_canonicalOrder`

**Files:**
- Modify: `lib/src/features/workspace/workspace_session.dart`
- Modify: `lib/src/features/workspace/workspace_provider.dart`
- Test: `test/workspace_provider_test.dart`

**Interfaces:**
- Produces:
  - `WorkspaceSession` gains `final bool pinned;` (default `false`) and `final String? groupId;` (default `null`), plus `WorkspaceSession copyWith({bool? pinned, String? groupId, bool clearGroup})`.
  - `WorkspaceNotifier`:
    - `List<WorkspaceSession> _canonicalOrder(List<WorkspaceSession> input)` — pinned first (relative order preserved), then unpinned with same-`groupId` sessions clustered contiguously at the group's first appearance.
    - `void togglePin(String id)` — flips `pinned`; pinning clears `groupId`; re-canonicalizes.
    - `void closeOthers(String id)` — closes every non-pinned session except `id`.
    - `void closeToRight(String id)` — closes every non-pinned session after `id` in visual order.

- [ ] **Step 1: Write failing unit tests**

Add to `test/workspace_provider_test.dart` `main()`:
```dart
test('pinned sessions sort before unpinned, preserving relative order', () {
  final a = _vm('a');
  final s1 = wn().openSsh(a);
  final s2 = wn().openSsh(a);
  final s3 = wn().openSsh(a);
  wn().togglePin(s3); // pin the last
  final ids = ws().sessions.map((s) => s.id).toList();
  expect(ids.first, s3);            // pinned floated to front
  expect(ids.sublist(1), [s1, s2]); // others keep order
  expect(ws().sessions.firstWhere((s) => s.id == s3).pinned, true);
});

test('unpin returns a session to the unpinned zone', () {
  final a = _vm('a');
  final s1 = wn().openSsh(a);
  final s2 = wn().openSsh(a);
  wn().togglePin(s1);
  wn().togglePin(s1);
  expect(ws().sessions.firstWhere((s) => s.id == s1).pinned, false);
  expect(ws().sessions.map((s) => s.id), [s1, s2]);
});

test('closeOthers keeps the target and any pinned; closeToRight spares pinned', () {
  final a = _vm('a');
  final s1 = wn().openSsh(a);
  final s2 = wn().openSsh(a);
  final s3 = wn().openSsh(a);
  wn().togglePin(s1);
  wn().closeOthers(s2); // keep s2 + pinned s1, close s3
  expect(ws().sessions.map((s) => s.id).toSet(), {s1, s2});
});
```

- [ ] **Step 2: Run to verify failure**

Run: `flutter test test/workspace_provider_test.dart`
Expected: FAIL — `togglePin`/`closeOthers`/`pinned` undefined.

- [ ] **Step 3: Extend `WorkspaceSession`**

Replace `lib/src/features/workspace/workspace_session.dart` body with:
```dart
import '../gcloud_provider.dart';

enum SessionType { overview, ssh, sftp }

class WorkspaceSession {
  final String id;
  final SessionType type;
  final ProjectAwareInstance target;
  final bool pinned;
  final String? groupId;

  const WorkspaceSession({
    required this.id,
    required this.type,
    required this.target,
    this.pinned = false,
    this.groupId,
  });

  String get vmKey => target.uniqueKey;

  WorkspaceSession copyWith({bool? pinned, String? groupId, bool clearGroup = false}) =>
      WorkspaceSession(
        id: id,
        type: type,
        target: target,
        pinned: pinned ?? this.pinned,
        groupId: clearGroup ? null : (groupId ?? this.groupId),
      );
}
```

- [ ] **Step 4: Add `_canonicalOrder`, `togglePin`, `closeOthers`, `closeToRight`**

In `lib/src/features/workspace/workspace_provider.dart`, add these methods to `WorkspaceNotifier` (before `hasLiveSessions`):
```dart
  /// Canonical visual order: pinned first (relative order preserved), then
  /// unpinned with same-group sessions clustered at the group's first
  /// appearance. Idempotent; preserves valid intra-zone reorders.
  List<WorkspaceSession> _canonicalOrder(List<WorkspaceSession> input) {
    final pinned = input.where((s) => s.pinned).toList();
    final unpinned = input.where((s) => !s.pinned).toList();
    final result = <WorkspaceSession>[...pinned];
    final emitted = <String>{};
    for (final s in unpinned) {
      if (s.groupId == null) {
        result.add(s);
        continue;
      }
      if (emitted.add(s.groupId!)) {
        result.addAll(unpinned.where((u) => u.groupId == s.groupId));
      }
    }
    return result;
  }

  void togglePin(String id) {
    final list = [
      for (final s in state.sessions)
        if (s.id == id)
          s.copyWith(pinned: !s.pinned, clearGroup: !s.pinned)
        else
          s,
    ];
    state = state.copyWith(sessions: _canonicalOrder(list));
  }

  void closeOthers(String id) {
    final victims = state.sessions
        .where((s) => s.id != id && !s.pinned)
        .map((s) => s.id)
        .toList();
    for (final v in victims) {
      close(v);
    }
  }

  void closeToRight(String id) {
    final idx = state.sessions.indexWhere((s) => s.id == id);
    if (idx < 0) return;
    final victims = state.sessions
        .sublist(idx + 1)
        .where((s) => !s.pinned)
        .map((s) => s.id)
        .toList();
    for (final v in victims) {
      close(v);
    }
  }
```
Note: `togglePin`'s `clearGroup: !s.pinned` clears the group only when transitioning INTO pinned (old `pinned` was false).

- [ ] **Step 5: Run the tests**

Run: `flutter analyze lib/src/features/workspace && flutter test test/workspace_provider_test.dart`
Expected: analyze 0 errors; all provider tests pass (the 6 original + 3 new).

- [ ] **Step 6: Commit**

```bash
git add lib/src/features/workspace/workspace_session.dart lib/src/features/workspace/workspace_provider.dart test/workspace_provider_test.dart
git commit -m "feat(workspace): pin model + canonical tab ordering + bulk-close methods"
```

---

## Task 4: Pinned zone rendering + tab context menu (pin/close)

**Files:**
- Modify: `lib/src/features/workspace/workspace_panel.dart`
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_es.arb`
- Test: `test/workspace_panel_test.dart`

**Interfaces:**
- Consumes: `togglePin`, `close`, `closeOthers`, `closeToRight`, `focus` (Task 3); `WorkspaceSession.pinned`.
- Produces: `_PinnedZone` (icon-only pinned tabs, leading the strip) and a right-click context menu on tabs with Pin/Unpin, Close, Close others, Close to the right. The scrollable region renders only NON-pinned sessions.

- [ ] **Step 1: Add i18n keys**

`app_en.arb`:
```json
"workspacePinTab": "Pin tab",
"workspaceUnpinTab": "Unpin tab",
"workspaceCloseOthers": "Close others",
"workspaceCloseToRight": "Close tabs to the right"
```
`app_es.arb`:
```json
"workspacePinTab": "Anclar pestaña",
"workspaceUnpinTab": "Desanclar pestaña",
"workspaceCloseOthers": "Cerrar las demás",
"workspaceCloseToRight": "Cerrar las pestañas de la derecha"
```
Run: `flutter gen-l10n`

- [ ] **Step 2: Write the failing widget test**

Add to `test/workspace_panel_test.dart` `main()`:
```dart
testWidgets('pinned tab renders in the pinned zone, out of the scroll list', (tester) async {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  final wn = c.read(workspaceProvider.notifier);
  final s = wn.openSsh(_vm('gamma'));
  wn.togglePin(s);
  await tester.pumpWidget(_host(c));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('pinned-zone')), findsOneWidget);
  expect(find.byKey(ValueKey('pinned-tab-$s')), findsOneWidget);
});
```

- [ ] **Step 3: Run to verify failure**

Run: `flutter test test/workspace_panel_test.dart`
Expected: FAIL — `pinned-zone` doesn't exist.

- [ ] **Step 4: Add `_PinnedZone`, wrap the strip, add the context menu**

In `workspace_panel.dart`, change `_TabStrip.build` to place the pinned zone before the scrollable region:
```dart
class _TabStrip extends StatelessWidget {
  final List<WorkspaceSession> sessions;
  final String? activeId;
  final WorkspaceNotifier notifier;
  const _TabStrip(
      {required this.sessions, required this.activeId, required this.notifier});

  @override
  Widget build(BuildContext context) {
    final pinned = sessions.where((s) => s.pinned).toList();
    final rest = sessions.where((s) => !s.pinned).toList();
    return SizedBox(
      height: 40,
      child: Row(children: [
        if (pinned.isNotEmpty)
          _PinnedZone(sessions: pinned, activeId: activeId, notifier: notifier),
        Expanded(
          child: _ScrollableTabs(
              sessions: rest, activeId: activeId, notifier: notifier),
        ),
      ]),
    );
  }
}
```
Add the `_PinnedZone` widget and a shared context-menu helper:
```dart
class _PinnedZone extends StatelessWidget {
  final List<WorkspaceSession> sessions;
  final String? activeId;
  final WorkspaceNotifier notifier;
  const _PinnedZone(
      {required this.sessions, required this.activeId, required this.notifier});

  IconData _icon(SessionType t) => switch (t) {
        SessionType.overview => Icons.dashboard_outlined,
        SessionType.ssh => Icons.terminal,
        SessionType.sftp => Icons.folder_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('pinned-zone'),
      decoration: BoxDecoration(
        border: Border(
            right: BorderSide(color: scheme.outlineVariant, width: 2)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final s in sessions)
          _TabContextMenu(
            session: s,
            notifier: notifier,
            child: InkWell(
              key: ValueKey('pinned-tab-${s.id}'),
              onTap: () => notifier.focus(s.id),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      width: 2,
                      color: s.id == activeId ? scheme.primary : Colors.transparent,
                    ),
                  ),
                ),
                child: Icon(_icon(s.type), size: 16),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Wraps a tab with a right-click (secondary-tap) context menu.
class _TabContextMenu extends StatelessWidget {
  final WorkspaceSession session;
  final WorkspaceNotifier notifier;
  final Widget child;
  const _TabContextMenu(
      {required this.session, required this.notifier, required this.child});

  Future<void> _show(BuildContext context, Offset pos) async {
    final l10n = AppLocalizations.of(context);
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final value = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          pos.dx, pos.dy, overlay.size.width - pos.dx, overlay.size.height - pos.dy),
      items: [
        PopupMenuItem(
            value: 'pin',
            child: Text(session.pinned ? l10n.workspaceUnpinTab : l10n.workspacePinTab)),
        const PopupMenuDivider(),
        PopupMenuItem(value: 'close', child: Text(l10n.workspaceCloseTab)),
        PopupMenuItem(value: 'others', child: Text(l10n.workspaceCloseOthers)),
        PopupMenuItem(value: 'right', child: Text(l10n.workspaceCloseToRight)),
      ],
    );
    switch (value) {
      case 'pin':
        notifier.togglePin(session.id);
      case 'close':
        notifier.close(session.id);
      case 'others':
        notifier.closeOthers(session.id);
      case 'right':
        notifier.closeToRight(session.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onSecondaryTapUp: (d) => _show(context, d.globalPosition),
      child: child,
    );
  }
}
```
Then wrap each `_Tab` in `_ScrollableTabsState.build` with `_TabContextMenu` (so non-pinned tabs also get the menu). Change the `_Tab(...)` child inside the `KeyedSubtree` to:
```dart
                child: _TabContextMenu(
                  session: s,
                  notifier: widget.notifier,
                  child: _Tab(
                    label: _tabLabel(context, s),
                    active: s.id == widget.activeId,
                    onTap: () => widget.notifier.focus(s.id),
                    onClose: () => widget.notifier.close(s.id),
                    closeTooltip: l10n.workspaceCloseTab,
                  ),
                ),
```

- [ ] **Step 5: Run tests**

Run: `flutter analyze lib/src/features/workspace/workspace_panel.dart && flutter test test/workspace_panel_test.dart`
Expected: analyze 0 errors; all widget tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/src/features/workspace/workspace_panel.dart lib/l10n test/workspace_panel_test.dart
git commit -m "feat(workspace): pinned zone + tab context menu (pin/close/close-others/close-right)"
```

---

## Task 5: Group data model + notifier group methods

**Files:**
- Create: `lib/src/features/workspace/workspace_group.dart`
- Modify: `lib/src/features/workspace/workspace_provider.dart`
- Test: `test/workspace_provider_test.dart`

**Interfaces:**
- Produces:
  - `enum GroupColor { blue, purple, green, amber, red, grey }`.
  - `class WorkspaceGroup { final String id; final String name; final GroupColor color; WorkspaceGroup copyWith({String? name, GroupColor? color}); }`.
  - `WorkspaceState` gains `final List<WorkspaceGroup> groups;` (default `const []`), threaded through `copyWith`.
  - `WorkspaceNotifier`: `String newGroupFromSession(String id)`, `void groupByVm(String vmKey)`, `void addToGroup(String sessionId, String groupId)`, `void removeFromGroup(String sessionId)`, `void renameGroup(String groupId, String name)`, `void recolorGroup(String groupId, GroupColor color)`, `void ungroup(String groupId)`, `void closeGroup(String groupId)`. Empty groups are pruned automatically.

- [ ] **Step 1: Write failing unit tests**

Add to `test/workspace_provider_test.dart` (add `import 'package:linux_cloud_connector/src/features/workspace/workspace_group.dart';` at top):
```dart
test('newGroupFromSession clusters and names after the VM; members stay contiguous', () {
  final a = _vm('web');
  final s1 = wn().openSsh(a);
  final s2 = wn().openSsh(_vm('other'));
  final s3 = wn().openSsh(a);
  final g = wn().newGroupFromSession(s1);
  wn().addToGroup(s3, g);
  final ids = ws().sessions.map((s) => s.id).toList();
  // s1 and s3 are contiguous (the group block); s2 is loose.
  expect((ids.indexOf(s3) - ids.indexOf(s1)).abs(), 1);
  expect(ws().groups.single.name, 'web');
});

test('groupByVm groups all unpinned sessions of a VM', () {
  final a = _vm('db');
  wn().openSsh(a);
  wn().openSftp(a);
  wn().openSsh(_vm('unrelated'));
  wn().groupByVm(a.uniqueKey);
  final grp = ws().groups.single;
  final inGroup = ws().sessions.where((s) => s.groupId == grp.id).toList();
  expect(inGroup.length, 2);
  expect(inGroup.every((s) => s.vmKey == a.uniqueKey), true);
});

test('ungroup drops the group and clears membership', () {
  final a = _vm('web');
  final s1 = wn().openSsh(a);
  final g = wn().newGroupFromSession(s1);
  wn().ungroup(g);
  expect(ws().groups, isEmpty);
  expect(ws().sessions.single.groupId, isNull);
});

test('closeGroup closes members and still releases the tunnel', () {
  final a = _vm('web');
  final s1 = wn().openSsh(a);
  wn().openSsh(a);
  final g = wn().newGroupFromSession(s1);
  wn().addToGroup(ws().sessions.firstWhere((s) => s.id != s1).id, g);
  wn().closeGroup(g);
  expect(ws().sessions, isEmpty);
  expect(ws().groups, isEmpty);
  expect(fake.disconnects, [('web', 22)]);
});

test('emptying a group by close prunes it', () {
  final a = _vm('web');
  final s1 = wn().openSsh(a);
  final g = wn().newGroupFromSession(s1);
  wn().close(s1);
  expect(ws().groups, isEmpty);
});
```

- [ ] **Step 2: Run to verify failure**

Run: `flutter test test/workspace_provider_test.dart`
Expected: FAIL — group types/methods undefined.

- [ ] **Step 3: Create the group model**

Create `lib/src/features/workspace/workspace_group.dart`:
```dart
enum GroupColor { blue, purple, green, amber, red, grey }

class WorkspaceGroup {
  final String id;
  final String name;
  final GroupColor color;
  const WorkspaceGroup({required this.id, required this.name, required this.color});

  WorkspaceGroup copyWith({String? name, GroupColor? color}) =>
      WorkspaceGroup(
        id: id,
        name: name ?? this.name,
        color: color ?? this.color,
      );
}
```

- [ ] **Step 4: Thread `groups` through `WorkspaceState`**

In `workspace_provider.dart`, add the import `import 'workspace_group.dart';`. Replace the `WorkspaceState` class with:
```dart
class WorkspaceState {
  final List<WorkspaceSession> sessions;
  final String? activeId;
  final List<WorkspaceGroup> groups;
  const WorkspaceState(
      {this.sessions = const [], this.activeId, this.groups = const []});

  WorkspaceState copyWith(
          {List<WorkspaceSession>? sessions,
          String? activeId,
          List<WorkspaceGroup>? groups}) =>
      WorkspaceState(
        sessions: sessions ?? this.sessions,
        activeId: activeId ?? this.activeId,
        groups: groups ?? this.groups,
      );

  WorkspaceSession? get activeSession {
    for (final s in sessions) {
      if (s.id == activeId) return s;
    }
    return null;
  }
}
```

- [ ] **Step 5: Add group methods + group pruning**

In `WorkspaceNotifier`, add a group id counter next to `_counter`:
```dart
  int _groupCounter = 0;
  String _newGroupId() => 'group-${_groupCounter++}';
```
Add this helper and the group methods (place after `closeToRight`):
```dart
  GroupColor _nextColor() {
    final used = state.groups.map((g) => g.color).toSet();
    for (final c in GroupColor.values) {
      if (!used.contains(c)) return c;
    }
    return GroupColor.values[state.groups.length % GroupColor.values.length];
  }

  /// Drops groups that no longer have any member session.
  List<WorkspaceGroup> _prunedGroups(List<WorkspaceSession> sessions,
      List<WorkspaceGroup> groups) {
    final live = sessions.map((s) => s.groupId).whereType<String>().toSet();
    return groups.where((g) => live.contains(g.id)).toList();
  }

  String newGroupFromSession(String id) {
    final session = _find((s) => s.id == id);
    if (session == null) return '';
    final group = WorkspaceGroup(
        id: _newGroupId(), name: session.target.name, color: _nextColor());
    final list = [
      for (final s in state.sessions)
        if (s.id == id) s.copyWith(pinned: false, groupId: group.id) else s,
    ];
    state = state.copyWith(
      sessions: _canonicalOrder(list),
      groups: [...state.groups, group],
    );
    return group.id;
  }

  void groupByVm(String vmKey) {
    final members =
        state.sessions.where((s) => !s.pinned && s.vmKey == vmKey).toList();
    if (members.isEmpty) return;
    final group = WorkspaceGroup(
        id: _newGroupId(), name: members.first.target.name, color: _nextColor());
    final memberIds = members.map((s) => s.id).toSet();
    final list = [
      for (final s in state.sessions)
        if (memberIds.contains(s.id)) s.copyWith(groupId: group.id) else s,
    ];
    state = state.copyWith(
      sessions: _canonicalOrder(list),
      groups: [...state.groups, group],
    );
  }

  void addToGroup(String sessionId, String groupId) {
    final list = [
      for (final s in state.sessions)
        if (s.id == sessionId) s.copyWith(pinned: false, groupId: groupId) else s,
    ];
    state = state.copyWith(sessions: _canonicalOrder(list));
  }

  void removeFromGroup(String sessionId) {
    final list = [
      for (final s in state.sessions)
        if (s.id == sessionId) s.copyWith(clearGroup: true) else s,
    ];
    state = state.copyWith(
      sessions: _canonicalOrder(list),
      groups: _prunedGroups(list, state.groups),
    );
  }

  void renameGroup(String groupId, String name) {
    state = state.copyWith(
      groups: [
        for (final g in state.groups)
          if (g.id == groupId) g.copyWith(name: name) else g,
      ],
    );
  }

  void recolorGroup(String groupId, GroupColor color) {
    state = state.copyWith(
      groups: [
        for (final g in state.groups)
          if (g.id == groupId) g.copyWith(color: color) else g,
      ],
    );
  }

  void ungroup(String groupId) {
    final list = [
      for (final s in state.sessions)
        if (s.groupId == groupId) s.copyWith(clearGroup: true) else s,
    ];
    state = state.copyWith(
      sessions: _canonicalOrder(list),
      groups: state.groups.where((g) => g.id != groupId).toList(),
    );
  }

  void closeGroup(String groupId) {
    final victims = state.sessions
        .where((s) => s.groupId == groupId)
        .map((s) => s.id)
        .toList();
    for (final v in victims) {
      close(v);
    }
  }
```

- [ ] **Step 6: Prune groups inside `close`**

In `close(String id)`, after computing `remaining` and before building the final `state`, prune empty groups. Change the final assignment from
```dart
    state = WorkspaceState(sessions: remaining, activeId: nextActive);
```
to
```dart
    state = WorkspaceState(
      sessions: remaining,
      activeId: nextActive,
      groups: _prunedGroups(remaining, state.groups),
    );
```

- [ ] **Step 7: Run the tests**

Run: `flutter analyze lib/src/features/workspace && flutter test test/workspace_provider_test.dart`
Expected: analyze 0 errors; all provider tests pass (original 6 + Task 3's 3 + these 5).

- [ ] **Step 8: Commit**

```bash
git add lib/src/features/workspace/workspace_group.dart lib/src/features/workspace/workspace_provider.dart test/workspace_provider_test.dart
git commit -m "feat(workspace): tab group model + notifier group operations"
```

---

## Task 6: Group rendering + group/tab context-menu group actions

**Files:**
- Create: `lib/src/features/workspace/group_color_theme.dart`
- Modify: `lib/src/features/workspace/workspace_panel.dart`
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_es.arb`
- Test: `test/workspace_panel_test.dart`

**Interfaces:**
- Consumes: all Task 5 group methods; `WorkspaceState.groups`; `WorkspaceSession.groupId`.
- Produces: `groupColor(GroupColor, ColorScheme) → Color`; `_TabGroup` (colored segment: header chip + member tabs); group actions added to the tab context menu (New group from this tab, Add to group ▸, Group all tabs of this VM); a group-header context menu (Rename…, recolor, Ungroup, Close group).

- [ ] **Step 1: Add i18n keys**

`app_en.arb`:
```json
"workspaceNewGroup": "New group from this tab",
"workspaceAddToGroup": "Add to group",
"workspaceGroupByVm": "Group all tabs of this VM",
"workspaceRenameGroup": "Rename group…",
"workspaceUngroup": "Ungroup",
"workspaceCloseGroup": "Close group",
"workspaceRenameGroupTitle": "Rename group"
```
`app_es.arb`:
```json
"workspaceNewGroup": "Nuevo grupo desde esta pestaña",
"workspaceAddToGroup": "Añadir a grupo",
"workspaceGroupByVm": "Agrupar todas las pestañas de esta VM",
"workspaceRenameGroup": "Renombrar grupo…",
"workspaceUngroup": "Desagrupar",
"workspaceCloseGroup": "Cerrar grupo",
"workspaceRenameGroupTitle": "Renombrar grupo"
```
Run: `flutter gen-l10n`

- [ ] **Step 2: Create the color mapping**

Create `lib/src/features/workspace/group_color_theme.dart`:
```dart
import 'package:flutter/material.dart';
import 'workspace_group.dart';

/// Theme-aware color for a group. Used for the header chip (full color) and,
/// at low opacity, the segment background.
Color groupColor(GroupColor c, ColorScheme scheme) {
  final dark = scheme.brightness == Brightness.dark;
  switch (c) {
    case GroupColor.blue:
      return dark ? const Color(0xFF4C8DFF) : const Color(0xFF2F6FB0);
    case GroupColor.purple:
      return dark ? const Color(0xFFB877D6) : const Color(0xFFA34BA3);
    case GroupColor.green:
      return dark ? const Color(0xFF4FB06A) : const Color(0xFF3B8D52);
    case GroupColor.amber:
      return dark ? const Color(0xFFE0A23B) : const Color(0xFFB37F1E);
    case GroupColor.red:
      return dark ? const Color(0xFFE06A70) : const Color(0xFFC0444B);
    case GroupColor.grey:
      return dark ? const Color(0xFF9AA0A6) : const Color(0xFF6A737D);
  }
}
```

- [ ] **Step 3: Write the failing widget test**

Add to `test/workspace_panel_test.dart` `main()`:
```dart
testWidgets('a group renders a header chip with its name', (tester) async {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  final wn = c.read(workspaceProvider.notifier);
  final s = wn.openSsh(_vm('web'));
  wn.newGroupFromSession(s);
  await tester.pumpWidget(_host(c));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('group-header')), findsOneWidget);
  expect(find.text('web'), findsWidgets);
});
```

- [ ] **Step 4: Run to verify failure**

Run: `flutter test test/workspace_panel_test.dart`
Expected: FAIL — no `group-header`.

- [ ] **Step 5: Render groups in the scrollable region**

In `workspace_panel.dart` add imports:
```dart
import 'workspace_group.dart';
import 'group_color_theme.dart';
```
Change `_ScrollableTabsState` to consume the groups. It currently receives only `sessions`; add a `groups` field to the widget and thread it from `_TabStrip`. Update `_ScrollableTabs`'s constructor and `_TabStrip.build` call to pass `groups: ` from a new `_TabStrip.groups` field, and `WorkspacePanel.build` to pass `ws.groups` into `_TabStrip`.

`WorkspacePanel.build` — change the `_TabStrip(...)` call to:
```dart
      _TabStrip(
          sessions: ws.sessions,
          groups: ws.groups,
          activeId: ws.activeId,
          notifier: notifier),
```
`_TabStrip` — add `final List<WorkspaceGroup> groups;` (required) and pass it to `_ScrollableTabs`.
`_ScrollableTabs` + state — add `final List<WorkspaceGroup> groups;` (required).

In `_ScrollableTabsState.build`, replace the `ListView(... children: [ for (final s in widget.sessions) ... ])` body with a builder that walks the non-pinned sessions and renders group blocks. Replace the inner `for` loop that builds tab children with:
```dart
          children: _buildRow(context, l10n),
```
and add this method to `_ScrollableTabsState`:
```dart
  List<Widget> _buildRow(BuildContext context, AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final widgets = <Widget>[];
    final emitted = <String>{};
    for (final s in widget.sessions) {
      if (s.groupId != null) {
        if (!emitted.add(s.groupId!)) continue; // group already emitted
        final group = widget.groups.firstWhere((g) => g.id == s.groupId,
            orElse: () => WorkspaceGroup(
                id: s.groupId!, name: '', color: GroupColor.grey));
        final members =
            widget.sessions.where((m) => m.groupId == s.groupId).toList();
        widgets.add(_TabGroup(
          group: group,
          members: members,
          activeId: widget.activeId,
          notifier: widget.notifier,
          tabKey: _keyFor,
          color: groupColor(group.color, scheme),
        ));
      } else {
        widgets.add(KeyedSubtree(
          key: _keyFor(s.id),
          child: _TabContextMenu(
            session: s,
            notifier: widget.notifier,
            groups: widget.groups,
            child: _Tab(
              label: _tabLabel(context, s),
              active: s.id == widget.activeId,
              onTap: () => widget.notifier.focus(s.id),
              onClose: () => widget.notifier.close(s.id),
              closeTooltip: l10n.workspaceCloseTab,
            ),
          ),
        ));
      }
    }
    return widgets;
  }
```
Add the `_TabGroup` widget:
```dart
class _TabGroup extends StatelessWidget {
  final WorkspaceGroup group;
  final List<WorkspaceSession> members;
  final String? activeId;
  final WorkspaceNotifier notifier;
  final GlobalKey Function(String id) tabKey;
  final Color color;
  const _TabGroup(
      {required this.group,
      required this.members,
      required this.activeId,
      required this.notifier,
      required this.tabKey,
      required this.color});

  Future<void> _headerMenu(BuildContext context, Offset pos) async {
    final l10n = AppLocalizations.of(context);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final value = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          pos.dx, pos.dy, overlay.size.width - pos.dx, overlay.size.height - pos.dy),
      items: [
        PopupMenuItem(value: 'rename', child: Text(l10n.workspaceRenameGroup)),
        for (final c in GroupColor.values)
          PopupMenuItem(
            value: 'color:${c.name}',
            child: Row(children: [
              Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                      color: groupColor(c, Theme.of(context).colorScheme),
                      shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Text(c.name),
            ]),
          ),
        const PopupMenuDivider(),
        PopupMenuItem(value: 'ungroup', child: Text(l10n.workspaceUngroup)),
        PopupMenuItem(value: 'close', child: Text(l10n.workspaceCloseGroup)),
      ],
    );
    if (value == null) return;
    if (value == 'rename') {
      if (!context.mounted) return;
      final name = await _promptName(context, group.name);
      if (name != null && name.isNotEmpty) notifier.renameGroup(group.id, name);
    } else if (value.startsWith('color:')) {
      final c = GroupColor.values.firstWhere((g) => g.name == value.substring(6));
      notifier.recolorGroup(group.id, c);
    } else if (value == 'ungroup') {
      notifier.ungroup(group.id);
    } else if (value == 'close') {
      notifier.closeGroup(group.id);
    }
  }

  Future<String?> _promptName(BuildContext context, String initial) {
    final l10n = AppLocalizations.of(context);
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.workspaceRenameGroupTitle),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: Text(l10n.commonCancel)),
          TextButton(
              onPressed: () => Navigator.pop(context, ctrl.text),
              child: Text(l10n.commonOk)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5, horizontal: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        GestureDetector(
          onSecondaryTapUp: (d) => _headerMenu(context, d.globalPosition),
          onTap: () => _headerMenu(
              context,
              (context.findRenderObject() as RenderBox)
                  .localToGlobal(const Offset(0, 30))),
          child: Container(
            key: const ValueKey('group-header'),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            height: 26,
            decoration: BoxDecoration(
                color: color, borderRadius: BorderRadius.circular(6)),
            alignment: Alignment.center,
            child: Text(group.name,
                style: TextStyle(
                    color: scheme.onPrimary, fontWeight: FontWeight.w600, fontSize: 12)),
          ),
        ),
        for (final s in members)
          KeyedSubtree(
            key: tabKey(s.id),
            child: _TabContextMenu(
              session: s,
              notifier: notifier,
              groups: const [], // members already grouped; add-to-group still available via full list below
              child: _Tab(
                label: _tabLabel(context, s),
                active: s.id == activeId,
                onTap: () => notifier.focus(s.id),
                onClose: () => notifier.close(s.id),
                closeTooltip: AppLocalizations.of(context).workspaceCloseTab,
              ),
            ),
          ),
      ]),
    );
  }
}
```
Note: `commonCancel` ("Cancel"/"Cancelar") and `commonOk` ("OK") are confirmed existing keys in both arb files — use them as-is. (Flutter 3.41.1 is in use, so `Color.withValues(alpha:)` above is available.)

- [ ] **Step 6: Add the group actions to `_TabContextMenu`**

Extend `_TabContextMenu` to carry `groups` and offer group actions. Replace the `_TabContextMenu` class from Task 4 with:
```dart
class _TabContextMenu extends StatelessWidget {
  final WorkspaceSession session;
  final WorkspaceNotifier notifier;
  final List<WorkspaceGroup> groups;
  final Widget child;
  const _TabContextMenu(
      {required this.session,
      required this.notifier,
      required this.groups,
      required this.child});

  Future<void> _show(BuildContext context, Offset pos) async {
    final l10n = AppLocalizations.of(context);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final value = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          pos.dx, pos.dy, overlay.size.width - pos.dx, overlay.size.height - pos.dy),
      items: [
        PopupMenuItem(
            value: 'pin',
            child: Text(session.pinned ? l10n.workspaceUnpinTab : l10n.workspacePinTab)),
        const PopupMenuDivider(),
        PopupMenuItem(value: 'newgroup', child: Text(l10n.workspaceNewGroup)),
        for (final g in groups)
          PopupMenuItem(
              value: 'addto:${g.id}',
              child: Text('${l10n.workspaceAddToGroup}: ${g.name}')),
        PopupMenuItem(value: 'groupvm', child: Text(l10n.workspaceGroupByVm)),
        const PopupMenuDivider(),
        PopupMenuItem(value: 'close', child: Text(l10n.workspaceCloseTab)),
        PopupMenuItem(value: 'others', child: Text(l10n.workspaceCloseOthers)),
        PopupMenuItem(value: 'right', child: Text(l10n.workspaceCloseToRight)),
      ],
    );
    if (value == null) return;
    if (value == 'pin') {
      notifier.togglePin(session.id);
    } else if (value == 'newgroup') {
      notifier.newGroupFromSession(session.id);
    } else if (value.startsWith('addto:')) {
      notifier.addToGroup(session.id, value.substring(6));
    } else if (value == 'groupvm') {
      notifier.groupByVm(session.vmKey);
    } else if (value == 'close') {
      notifier.close(session.id);
    } else if (value == 'others') {
      notifier.closeOthers(session.id);
    } else if (value == 'right') {
      notifier.closeToRight(session.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onSecondaryTapUp: (d) => _show(context, d.globalPosition),
      child: child,
    );
  }
}
```
Update the two other `_TabContextMenu(...)` call sites (the loose-tab one in `_buildRow`, and the pinned-zone one in `_PinnedZone`) to pass `groups:` — loose tab passes `widget.groups`; the pinned-zone call passes the groups list too (thread a `groups` field into `_PinnedZone` from `_TabStrip.build`, i.e. add `final List<WorkspaceGroup> groups;` to `_PinnedZone` and pass `groups: groups`). In the `_TabGroup` member call above, pass `groups: const []` is acceptable only if you prefer members not show "add to another group"; to allow moving between groups, pass the real groups list instead — pass `groups` into `_TabGroup` and forward it. Choose the real-list option: add `final List<WorkspaceGroup> groups;` to `_TabGroup`, forward from `_buildRow` (`groups: widget.groups`), and use it in the member `_TabContextMenu`.

- [ ] **Step 7: Run tests**

Run: `flutter analyze lib/src/features/workspace && flutter test`
Expected: analyze 0 errors; full suite green including the new group widget test.

- [ ] **Step 8: Commit**

```bash
git add lib/src/features/workspace/group_color_theme.dart lib/src/features/workspace/workspace_panel.dart lib/l10n test/workspace_panel_test.dart
git commit -m "feat(workspace): render tab groups + group/tab context-menu group actions"
```

---

## Task 7: Zone-constrained drag reorder

**Files:**
- Modify: `lib/src/features/workspace/workspace_provider.dart` (extend `reorder` to a session-id API)
- Modify: `lib/src/features/workspace/workspace_panel.dart` (make loose tabs and group members draggable)
- Test: `test/workspace_provider_test.dart`

**Interfaces:**
- Consumes: `_canonicalOrder` (Task 3), `WorkspaceState.sessions`.
- Produces: `void reorderSession(String movedId, String targetId)` on `WorkspaceNotifier` — moves `movedId` to just before `targetId` in the sessions list, then re-canonicalizes (so a cross-zone drop is normalized back into a valid order rather than corrupting invariants).

- [ ] **Step 1: Write failing unit test**

Add to `test/workspace_provider_test.dart` `main()`:
```dart
test('reorderSession moves a loose tab and stays canonical', () {
  final a = _vm('a');
  final s1 = wn().openSsh(a);
  final s2 = wn().openSsh(a);
  final s3 = wn().openSsh(a);
  wn().reorderSession(s3, s1); // move s3 before s1
  expect(ws().sessions.map((s) => s.id), [s3, s1, s2]);
});

test('reorderSession keeps pinned ahead of unpinned', () {
  final a = _vm('a');
  final s1 = wn().openSsh(a);
  final s2 = wn().openSsh(a);
  wn().togglePin(s1); // s1 pinned, order [s1, s2]
  wn().reorderSession(s2, s1); // try to move s2 before pinned s1
  // canonical order forces pinned first regardless.
  expect(ws().sessions.map((s) => s.id), [s1, s2]);
});
```

- [ ] **Step 2: Run to verify failure**

Run: `flutter test test/workspace_provider_test.dart`
Expected: FAIL — `reorderSession` undefined.

- [ ] **Step 3: Add `reorderSession`**

In `WorkspaceNotifier`, add (keep the old `reorder(int,int)` for the existing test, or delete it if unused — it is not referenced elsewhere, so remove it and its test if present):
```dart
  void reorderSession(String movedId, String targetId) {
    if (movedId == targetId) return;
    final list = [...state.sessions];
    final from = list.indexWhere((s) => s.id == movedId);
    if (from < 0) return;
    final moved = list.removeAt(from);
    final to = list.indexWhere((s) => s.id == targetId);
    list.insert(to < 0 ? list.length : to, moved);
    state = state.copyWith(sessions: _canonicalOrder(list));
  }
```
If the old `reorder(int oldIndex, int newIndex)` method and any test referencing it remain, leave them; they don't conflict.

- [ ] **Step 4: Make tabs draggable (loose + group members)**

Wrap each `_Tab` (in `_buildRow`'s loose branch and in `_TabGroup`'s member loop) with drag affordances. Define a small reusable wrapper and use it in both places:
```dart
class _DraggableTab extends StatelessWidget {
  final String sessionId;
  final WorkspaceNotifier notifier;
  final Widget child;
  const _DraggableTab(
      {required this.sessionId, required this.notifier, required this.child});

  @override
  Widget build(BuildContext context) {
    return DragTarget<String>(
      onWillAcceptWithDetails: (d) => d.data != sessionId,
      onAcceptWithDetails: (d) => notifier.reorderSession(d.data, sessionId),
      builder: (context, candidate, rejected) {
        return Draggable<String>(
          data: sessionId,
          feedback: Material(
              color: Colors.transparent,
              child: Opacity(opacity: 0.8, child: child)),
          childWhenDragging: Opacity(opacity: 0.4, child: child),
          child: Container(
            decoration: candidate.isNotEmpty
                ? BoxDecoration(
                    border: Border(
                        left: BorderSide(
                            color: Theme.of(context).colorScheme.primary,
                            width: 2)))
                : null,
            child: child,
          ),
        );
      },
    );
  }
}
```
In `_buildRow` (loose branch), wrap the `_TabContextMenu(...)` in `_DraggableTab(sessionId: s.id, notifier: widget.notifier, child: _TabContextMenu(...))`. In `_TabGroup`'s member loop, wrap the member `_TabContextMenu(...)` the same way with `sessionId: s.id, notifier: notifier`. Pinned tabs are NOT wrapped (pin order is by menu only in v1).

Because `reorderSession` re-canonicalizes, a drop of a loose tab onto a group member (cross-zone) is normalized (the moved tab stays loose and lands adjacent to the group block, never inside it) — no corruption.

- [ ] **Step 5: Run tests**

Run: `flutter analyze lib/src/features/workspace && flutter test`
Expected: analyze 0 errors; full suite green.

- [ ] **Step 6: Commit**

```bash
git add lib/src/features/workspace/workspace_provider.dart lib/src/features/workspace/workspace_panel.dart test/workspace_provider_test.dart
git commit -m "feat(workspace): zone-constrained drag reorder for tabs"
```

---

## Task 8: Full gate + manual QA checklist

**Files:**
- Create: `docs/superpowers/plans/2026-07-23-tab-strip-management-manual-qa.md`

- [ ] **Step 1: Full gate**

```bash
flutter gen-l10n && flutter analyze && flutter test && flutter build linux --debug
python3 -c "import json;a=json.load(open('lib/l10n/app_en.arb'));b=json.load(open('lib/l10n/app_es.arb'));ka={k for k in a if not k.startswith('@')};kb={k for k in b if not k.startswith('@')};print(sorted(ka^kb) or 'PARITY OK')"
```
Expected: 0 analyze errors, all tests pass, build succeeds, `PARITY OK`.

- [ ] **Step 2: Write the manual QA checklist**

Create `docs/superpowers/plans/2026-07-23-tab-strip-management-manual-qa.md`:
```markdown
# Manual QA — tab strip management (27H1)

- [ ] Open more tabs than fit: `‹ ›` arrows appear; clicking them scrolls; opening a new tab auto-scrolls it into view (no lost tabs).
- [ ] `⌄` all-tabs menu lists every tab (pinned, grouped, loose) and jumps to the selected one.
- [ ] Right-click a tab → Pin: it moves to the icon-only pinned zone on the left and stays visible when the strip scrolls. Unpin returns it.
- [ ] Right-click a tab → New group from this tab: a colored, named segment appears (named after the VM). Right-click the header → Rename, recolor (6 swatches), Ungroup, Close group all work.
- [ ] Right-click a tab → Group all tabs of this VM: all that VM's non-pinned tabs cluster into one group.
- [ ] Add to group ▸ moves a tab into an existing group; the group's tabs stay contiguous.
- [ ] Drag to reorder: loose tabs reorder among loose; group members reorder within the group; pinned order is menu-only. A cross-zone drop never corrupts the layout.
- [ ] Close others / Close tabs to the right never close pinned tabs.
- [ ] Closing the last tab of a grouped VM still tears down its tunnel (log: "Stopping tunnel"); the emptied group disappears.
- [ ] Spanish: menus, group header, and the rename dialog are translated and not clipped.
- [ ] Existing invariant holds: switching tabs never kills a live SSH session (IndexedStack).
```

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/plans/2026-07-23-tab-strip-management-manual-qa.md
git commit -m "docs(workspace): manual QA checklist for tab strip management"
```

---

## Self-Review (done at write time)

- **Spec coverage:** §1 data model → Tasks 3, 5; §2 notifier methods → Tasks 3, 5, 7; §3 rendering (pinned/scroll/groups/all-tabs) → Tasks 1, 2, 4, 6; §4 interactions (menus, drag) → Tasks 4, 6, 7; §5 i18n → spread across Tasks 1/2/4/6; §6 verification (unit + widget + manual) → Tasks 3/5/7 (unit), 1/2/4/6 (widget), 8 (manual); §7 sequencing → Phase 1 = Tasks 1-2, Phase 2 = Tasks 3-4, Phase 3 = Tasks 5-7. Out-of-scope items (collapse-to-chip, drag-to-change-membership, middle-click, restore, visual redesign) are not implemented. No gaps.
- **Placeholder scan:** every code step carries complete code; the one judgment call (existing cancel/OK l10n key names in Task 6) is flagged with a concrete verification instruction rather than left vague.
- **Type consistency:** `WorkspaceSession.copyWith({bool? pinned, String? groupId, bool clearGroup})`, `GroupColor`, `WorkspaceGroup.copyWith({String? name, GroupColor? color})`, `_canonicalOrder(List<WorkspaceSession>)`, and the notifier method names (`togglePin`, `newGroupFromSession`, `groupByVm`, `addToGroup`, `removeFromGroup`, `renameGroup`, `recolorGroup`, `ungroup`, `closeGroup`, `closeOthers`, `closeToRight`, `reorderSession`) are used identically across Tasks 3-7. `groupColor(GroupColor, ColorScheme)` matches between Task 6's definition and its uses.
