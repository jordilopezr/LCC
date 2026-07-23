# Tabbed Workspace + Embedded SSH Terminal Implementation Plan (27H1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the dashboard's right panel into a tabbed workspace whose tabs (Overview, embedded SSH terminal, SFTP) are sessions that survive sidebar selection changes, so multiple SSH sessions to different VMs can be open at once.

**Architecture:** A `WorkspaceNotifier` owns an ordered list of `WorkspaceSession`s plus the active id and a per-VM tunnel reference count. The right panel renders a tab strip over an `IndexedStack` (all sessions stay mounted; only one is visible) so terminals/SFTP connections are never rebuilt. SSH tabs spawn the system `ssh` in a PTY (`flutter_pty`) over the existing IAP tunnel and render with `xterm`.

**Tech Stack:** Flutter/Dart, Riverpod 3.x Notifier, `xterm ^4.0.0`, `flutter_pty ^0.4.2`, `window_manager` (already present), gen-l10n.

**Spec:** `docs/superpowers/specs/2026-07-22-tabbed-workspace-design.md`

## Global Constraints

- Branch `27H1`. `flutter analyze` (0 errors) and `flutter test` (all pass) at every commit; Rust untouched unless a task says otherwise.
- New module lives in `lib/src/features/workspace/` — do NOT add this to `lib/main.dart` (already 4768 lines).
- Session types (verbatim): `overview`, `ssh`, `sftp`. RDP/VNC stay external launches — out of scope.
- Tab content MUST use `IndexedStack` (all children mounted), never `TabBarView` (disposes hidden children → kills sessions).
- Dedup rules: `openOverview`/`openSftp` focus an existing tab for that VM if present; `openSsh` ALWAYS opens a new tab.
- Tunnel ref-count: SSH/SFTP sessions increment a per-VM count (`ProjectAwareInstance.uniqueKey` = `projectId:zone:name`); on close, decrement; at 0 call `disconnect(instanceName, 22)`. Overview never touches the count.
- SSH command (verbatim): `ssh -p <localPort> -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=<appSupport>/known_hosts <user>@localhost`; username from the existing `getUsername()` bridge call; the tunnel is to remote port 22.
- App close with ≥1 live SSH/SFTP session → confirmation dialog; no session restore on reopen. Overview tabs don't count as live.
- i18n: every new key in BOTH `lib/l10n/app_en.arb` and `lib/l10n/app_es.arb` (parity enforced), Spanish neutral register, ellipsis `…`, append-only, run `flutter gen-l10n` and commit `lib/l10n/gen/`.
- Existing types to reuse (do not redefine): `ProjectAwareInstance` (`gcloud_provider.dart:1573`, has `.uniqueKey`, `.name`, `.projectId`, `.zone`), `activeConnectionsProvider` (`gcloud_provider.dart:496`, a `NotifierProvider<ConnectionsNotifier, Map<String,TunnelState>>`) whose notifier has `Future<int?> connect(projectId, zone, instanceName, {int remotePort})` and `Future<void> disconnect(String instanceName, int remotePort)`, and `getUsername()` from `lib/src/bridge/api.dart/api.dart`.

---

### Task 1: Session model + WorkspaceNotifier (pure logic, unit-tested)

**Files:**
- Create: `lib/src/features/workspace/workspace_session.dart`
- Create: `lib/src/features/workspace/workspace_provider.dart`
- Test: `test/workspace_provider_test.dart`

**Interfaces:**
- Produces:
  - `enum SessionType { overview, ssh, sftp }`
  - `class WorkspaceSession { final String id; final SessionType type; final ProjectAwareInstance target; String get vmKey => target.uniqueKey; }` (id is unique; construct via a counter/UUID)
  - `final workspaceProvider = NotifierProvider<WorkspaceNotifier, WorkspaceState>(WorkspaceNotifier.new);`
  - `class WorkspaceState { final List<WorkspaceSession> sessions; final String? activeId; }`
  - `WorkspaceNotifier` methods: `String openOverview(ProjectAwareInstance)`, `String openSsh(ProjectAwareInstance)`, `String openSftp(ProjectAwareInstance)`, `void focus(String id)`, `void close(String id)`, `void reorder(int oldIndex, int newIndex)`, `bool get hasLiveSessions`. Each `open*` returns the session id and sets it active.

- [ ] **Step 1: Write the failing tests**

`test/workspace_provider_test.dart`:
```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/src/features/gcloud_provider.dart';
import 'package:linux_cloud_connector/src/features/workspace/workspace_session.dart';
import 'package:linux_cloud_connector/src/features/workspace/workspace_provider.dart';

// Records disconnect() calls so we can assert the ref-count behavior without
// touching the Rust bridge.
class _FakeConnections extends ConnectionsNotifier {
  final List<(String, int)> disconnects = [];
  @override
  Map<String, TunnelState> build() => {};
  @override
  Future<void> disconnect(String instanceName, int remotePort) async {
    disconnects.add((instanceName, remotePort));
  }
}

ProjectAwareInstance _vm(String name) => ProjectAwareInstance(
      projectId: 'p',
      instance: GcpInstance(
        name: name, status: 'RUNNING', zone: 'z', machineType: 'm',
        cpuCount: 1, memoryMb: 1, diskGb: 1, labels: const [],
        osLoginEnabled: false, isWindows: false,
      ),
    );

void main() {
  late ProviderContainer container;
  late _FakeConnections fake;

  setUp(() {
    fake = _FakeConnections();
    container = ProviderContainer(overrides: [
      activeConnectionsProvider.overrideWith(() => fake),
    ]);
    addTearDown(container.dispose);
  });

  WorkspaceNotifier wn() => container.read(workspaceProvider.notifier);
  WorkspaceState ws() => container.read(workspaceProvider);

  test('openOverview dedups per VM; openSsh always adds', () {
    final a = _vm('vm1');
    wn().openOverview(a);
    wn().openOverview(a); // same VM → focus, no new tab
    expect(ws().sessions.where((s) => s.type == SessionType.overview).length, 1);
    wn().openSsh(a);
    wn().openSsh(a); // second SSH to same VM → new tab
    expect(ws().sessions.where((s) => s.type == SessionType.ssh).length, 2);
  });

  test('active id follows the most recently opened/focused tab', () {
    final a = _vm('vm1');
    final ov = wn().openOverview(a);
    final ssh = wn().openSsh(a);
    expect(ws().activeId, ssh);
    wn().focus(ov);
    expect(ws().activeId, ov);
  });

  test('tunnel closes only when the last SSH/SFTP session for a VM closes', () {
    final a = _vm('vm1');
    final s1 = wn().openSsh(a);
    final s2 = wn().openSsh(a);
    final f1 = wn().openSftp(a);
    wn().close(s1);
    wn().close(f1);
    expect(fake.disconnects, isEmpty); // still one SSH alive
    wn().close(s2);
    expect(fake.disconnects, [('vm1', 22)]); // last one → tunnel closed
  });

  test('overview close never touches the tunnel', () {
    final a = _vm('vm1');
    final ov = wn().openOverview(a);
    wn().close(ov);
    expect(fake.disconnects, isEmpty);
  });

  test('closing the active tab focuses a neighbor', () {
    final a = _vm('vm1');
    final s1 = wn().openSsh(a);
    final s2 = wn().openSsh(a);
    expect(ws().activeId, s2);
    wn().close(s2);
    expect(ws().activeId, s1);
  });

  test('hasLiveSessions ignores overview', () {
    final a = _vm('vm1');
    wn().openOverview(a);
    expect(wn().hasLiveSessions, false);
    wn().openSsh(a);
    expect(wn().hasLiveSessions, true);
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `flutter test test/workspace_provider_test.dart`
Expected: FAIL — files/types not defined.

- [ ] **Step 3: Implement the model**

`lib/src/features/workspace/workspace_session.dart`:
```dart
import '../gcloud_provider.dart';

enum SessionType { overview, ssh, sftp }

class WorkspaceSession {
  final String id;
  final SessionType type;
  final ProjectAwareInstance target;

  const WorkspaceSession({
    required this.id,
    required this.type,
    required this.target,
  });

  String get vmKey => target.uniqueKey;
}
```

- [ ] **Step 4: Implement the notifier**

`lib/src/features/workspace/workspace_provider.dart`:
```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../gcloud_provider.dart';
import 'workspace_session.dart';

class WorkspaceState {
  final List<WorkspaceSession> sessions;
  final String? activeId;
  const WorkspaceState({this.sessions = const [], this.activeId});

  WorkspaceState copyWith({List<WorkspaceSession>? sessions, String? activeId}) =>
      WorkspaceState(
        sessions: sessions ?? this.sessions,
        activeId: activeId ?? this.activeId,
      );
}

final workspaceProvider =
    NotifierProvider<WorkspaceNotifier, WorkspaceState>(WorkspaceNotifier.new);

class WorkspaceNotifier extends Notifier<WorkspaceState> {
  int _counter = 0;
  final Map<String, int> _tunnelRefs = {};

  @override
  WorkspaceState build() => const WorkspaceState();

  String _newId() => 'session-${_counter++}';

  WorkspaceSession? _find(bool Function(WorkspaceSession) test) {
    for (final s in state.sessions) {
      if (test(s)) return s;
    }
    return null;
  }

  String _add(WorkspaceSession session, {bool holdsTunnel = false}) {
    if (holdsTunnel) {
      _tunnelRefs[session.vmKey] = (_tunnelRefs[session.vmKey] ?? 0) + 1;
    }
    state = state.copyWith(
      sessions: [...state.sessions, session],
      activeId: session.id,
    );
    return session.id;
  }

  String openOverview(ProjectAwareInstance vm) {
    final existing = _find(
        (s) => s.type == SessionType.overview && s.vmKey == vm.uniqueKey);
    if (existing != null) {
      focus(existing.id);
      return existing.id;
    }
    return _add(WorkspaceSession(
        id: _newId(), type: SessionType.overview, target: vm));
  }

  String openSsh(ProjectAwareInstance vm) => _add(
        WorkspaceSession(id: _newId(), type: SessionType.ssh, target: vm),
        holdsTunnel: true,
      );

  String openSftp(ProjectAwareInstance vm) {
    final existing =
        _find((s) => s.type == SessionType.sftp && s.vmKey == vm.uniqueKey);
    if (existing != null) {
      focus(existing.id);
      return existing.id;
    }
    return _add(
      WorkspaceSession(id: _newId(), type: SessionType.sftp, target: vm),
      holdsTunnel: true,
    );
  }

  void focus(String id) => state = state.copyWith(activeId: id);

  void close(String id) {
    final idx = state.sessions.indexWhere((s) => s.id == id);
    if (idx < 0) return;
    final session = state.sessions[idx];
    final remaining = [...state.sessions]..removeAt(idx);

    // Ref-count: release the VM's tunnel when its last live session goes away.
    if (session.type != SessionType.overview) {
      final key = session.vmKey;
      final left = (_tunnelRefs[key] ?? 1) - 1;
      if (left <= 0) {
        _tunnelRefs.remove(key);
        ref.read(activeConnectionsProvider.notifier)
            .disconnect(session.target.name, 22)
            .catchError((_) {});
      } else {
        _tunnelRefs[key] = left;
      }
    }

    // Keep a sensible active tab: neighbor of the closed one.
    String? nextActive = state.activeId;
    if (state.activeId == id) {
      if (remaining.isEmpty) {
        nextActive = null;
      } else {
        nextActive = remaining[idx > 0 ? idx - 1 : 0].id;
      }
    }
    state = WorkspaceState(sessions: remaining, activeId: nextActive);
  }

  void reorder(int oldIndex, int newIndex) {
    final list = [...state.sessions];
    if (newIndex > oldIndex) newIndex -= 1;
    final moved = list.removeAt(oldIndex);
    list.insert(newIndex, moved);
    state = state.copyWith(sessions: list);
  }

  bool get hasLiveSessions =>
      state.sessions.any((s) => s.type != SessionType.overview);
}
```

- [ ] **Step 5: Run to verify pass**

Run: `flutter test test/workspace_provider_test.dart`
Expected: PASS — 6 tests. If `GcpInstance`'s constructor differs, adjust the `_vm` helper to the real fields (check `lib/src/bridge/api.dart/*` for `GcpInstance`).

- [ ] **Step 6: Commit**

```bash
git add lib/src/features/workspace test/workspace_provider_test.dart
git commit -m "feat(workspace): session model + notifier with tunnel ref-count"
```

---

### Task 2: Add terminal dependencies + SSH terminal controller

**Files:**
- Modify: `pubspec.yaml`
- Create: `lib/src/features/workspace/ssh_terminal_controller.dart`

**Interfaces:**
- Consumes: `getUsername()` bridge call; `activeConnectionsProvider` notifier's `connect(...)`.
- Produces: `class SshTerminalController` with `final Terminal terminal;`, `TerminalPhase get phase;` (`enum TerminalPhase { connectingTunnel, launching, connected, disconnected, error }`), `String? errorDetail`, `Future<void> start()`, `void reconnect()`, `void dispose()`, and a `Listenable`/`ValueNotifier<TerminalPhase> phaseNotifier` the widget can rebuild on.

- [ ] **Step 1: Add dependencies**

In `pubspec.yaml` under `dependencies:` add:
```yaml
  xterm: ^4.0.0
  flutter_pty: ^0.4.2
```
Run: `flutter pub get`
Expected: resolves; both packages fetched.

- [ ] **Step 2: Implement the controller**

`lib/src/features/workspace/ssh_terminal_controller.dart`:
```dart
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:xterm/xterm.dart';

enum TerminalPhase { connectingTunnel, launching, connected, disconnected, error }

/// Owns the xterm Terminal + the ssh PTY for one SSH tab. Given a function that
/// establishes (or reuses) the IAP tunnel and returns the local port, it spawns
/// `ssh` over that port and streams both directions.
class SshTerminalController {
  final String username;
  final String instanceName;
  final Future<int?> Function() ensureTunnel;

  final Terminal terminal = Terminal(maxLines: 10000);
  final ValueNotifier<TerminalPhase> phaseNotifier =
      ValueNotifier(TerminalPhase.connectingTunnel);
  String? errorDetail;

  Pty? _pty;

  SshTerminalController({
    required this.username,
    required this.instanceName,
    required this.ensureTunnel,
  });

  TerminalPhase get phase => phaseNotifier.value;
  void _setPhase(TerminalPhase v) => phaseNotifier.value = v;

  Future<void> start() async {
    _setPhase(TerminalPhase.connectingTunnel);
    try {
      final port = await ensureTunnel();
      if (port == null) {
        errorDetail = 'Tunnel could not be established';
        _setPhase(TerminalPhase.error);
        return;
      }
      _setPhase(TerminalPhase.launching);

      final support = await getApplicationSupportDirectory();
      final knownHosts = p.join(support.path, 'ssh_known_hosts');

      final pty = Pty.start(
        'ssh',
        arguments: [
          '-p', '$port',
          '-o', 'StrictHostKeyChecking=accept-new',
          '-o', 'UserKnownHostsFile=$knownHosts',
          '$username@localhost',
        ],
        columns: terminal.viewWidth,
        rows: terminal.viewHeight,
      );
      _pty = pty;

      pty.output
          .cast<List<int>>()
          .transform(const Utf8Decoder())
          .listen(terminal.write);
      terminal.onOutput = (data) => pty.write(const Utf8Encoder().convert(data));
      terminal.onResize = (w, h, pw, ph) => pty.resize(h, w);

      pty.exitCode.then((_) {
        if (phase != TerminalPhase.error) _setPhase(TerminalPhase.disconnected);
      });

      _setPhase(TerminalPhase.connected);
    } catch (e) {
      errorDetail = e.toString();
      _setPhase(TerminalPhase.error);
    }
  }

  void reconnect() {
    _pty?.kill();
    _pty = null;
    start();
  }

  void dispose() {
    _pty?.kill();
    _pty = null;
    phaseNotifier.dispose();
  }
}
```

- [ ] **Step 3: Verify it compiles**

Run: `flutter analyze lib/src/features/workspace/ssh_terminal_controller.dart`
Expected: 0 errors. (If `Terminal.viewWidth`/`viewHeight` names differ in xterm 4.0.0, use the real getters — check the installed package's `terminal.dart`; the concept is initial cols/rows.)

- [ ] **Step 4: Commit**

```bash
git add pubspec.yaml pubspec.lock lib/src/features/workspace/ssh_terminal_controller.dart
git commit -m "feat(workspace): ssh terminal controller (pty + xterm)"
```

---

### Task 3: SSH terminal tab widget

**Files:**
- Create: `lib/src/features/workspace/ssh_terminal_tab.dart`

**Interfaces:**
- Consumes: `SshTerminalController`, `TerminalPhase` (Task 2); `WorkspaceSession` (Task 1); `activeConnectionsProvider` (`connect`), `getUsername()`.
- Produces: `class SshTerminalTab extends ConsumerStatefulWidget { final WorkspaceSession session; }` — a self-contained widget that owns its controller for its whole lifetime.

- [ ] **Step 1: Implement**

`lib/src/features/workspace/ssh_terminal_tab.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import '../gcloud_provider.dart';
import '../../bridge/api.dart/api.dart';
import 'ssh_terminal_controller.dart';
import 'workspace_session.dart';

class SshTerminalTab extends ConsumerStatefulWidget {
  final WorkspaceSession session;
  const SshTerminalTab({super.key, required this.session});

  @override
  ConsumerState<SshTerminalTab> createState() => _SshTerminalTabState();
}

class _SshTerminalTabState extends ConsumerState<SshTerminalTab> {
  SshTerminalController? _controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  Future<void> _boot() async {
    final vm = widget.session.target;
    final username = await getUsername();
    final controller = SshTerminalController(
      username: username,
      instanceName: vm.name,
      ensureTunnel: () => ref
          .read(activeConnectionsProvider.notifier)
          .connect(vm.projectId, vm.zone, vm.name, remotePort: 22),
    );
    setState(() => _controller = controller);
    await controller.start();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final c = _controller;
    if (c == null) {
      return Center(child: Text(l10n.workspaceTerminalConnecting));
    }
    return ValueListenableBuilder<TerminalPhase>(
      valueListenable: c.phaseNotifier,
      builder: (context, phase, _) {
        switch (phase) {
          case TerminalPhase.connectingTunnel:
          case TerminalPhase.launching:
            return Center(child: Text(l10n.workspaceTerminalConnecting));
          case TerminalPhase.error:
            return _statusPanel(l10n.workspaceTerminalError(c.errorDetail ?? ''),
                l10n.commonRetry, c.reconnect);
          case TerminalPhase.disconnected:
            return Column(children: [
              Expanded(child: TerminalView(c.terminal)),
              _reconnectBar(l10n, c.reconnect),
            ]);
          case TerminalPhase.connected:
            return TerminalView(c.terminal);
        }
      },
    );
  }

  Widget _reconnectBar(AppLocalizations l10n, VoidCallback onReconnect) =>
      Container(
        padding: const EdgeInsets.all(8),
        color: Colors.orange.shade50,
        child: Row(children: [
          Expanded(child: Text(l10n.workspaceTerminalDisconnected)),
          TextButton(onPressed: onReconnect, child: Text(l10n.workspaceReconnect)),
        ]),
      );

  Widget _statusPanel(String message, String action, VoidCallback onAction) =>
      Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          ElevatedButton(onPressed: onAction, child: Text(action)),
        ]),
      );
}
```
(The l10n keys `workspaceTerminalConnecting`, `workspaceTerminalError`, `workspaceTerminalDisconnected`, `workspaceReconnect` are added in Task 6's i18n step — declare them there; this file will not compile until then, which is fine because Task 3 and Task 6 land before the panel wires them together. To keep this task self-contained, add those four keys to both .arb files in this task's Step 2 instead.)

- [ ] **Step 2: Add the terminal l10n keys**

`lib/l10n/app_en.arb` (append): `"workspaceTerminalConnecting": "Connecting…"`, `"workspaceTerminalDisconnected": "Session ended."`, `"workspaceReconnect": "Reconnect"`, and:
```json
"workspaceTerminalError": "Could not open the SSH session: {detail}",
"@workspaceTerminalError": { "placeholders": { "detail": {"type": "String"} } }
```
`lib/l10n/app_es.arb`: `"workspaceTerminalConnecting": "Conectando…"`, `"workspaceTerminalDisconnected": "La sesión terminó."`, `"workspaceReconnect": "Reconectar"`, `"workspaceTerminalError": "No se pudo abrir la sesión SSH: {detail}"`.
Run `flutter gen-l10n`.

- [ ] **Step 3: Verify**

Run: `flutter analyze lib/src/features/workspace/ssh_terminal_tab.dart`
Expected: 0 errors. (Confirm `TerminalView` constructor takes the `Terminal` positionally in xterm 4.0.0; adjust if the API is `TerminalView(terminal: c.terminal)`.)

- [ ] **Step 4: Commit**

```bash
git add lib/src/features/workspace/ssh_terminal_tab.dart lib/l10n
git commit -m "feat(workspace): SSH terminal tab with connecting/error/reconnect states"
```

---

### Task 4: SFTP tab (reuse the existing browser as a panel)

**Files:**
- Create: `lib/src/features/workspace/sftp_tab.dart`
- Read (do not restructure): `lib/src/features/sftp_browser.dart` — `SftpBrowserDialog` at line 601 wraps the browser in a `Dialog`; the tab reuses the same inner content without the Dialog chrome.

**Interfaces:**
- Consumes: `WorkspaceSession`; `activeConnectionsProvider` (`connect` to get the port); `getUsername()`; the existing SFTP browser widget/provider.
- Produces: `class SftpTab extends ConsumerStatefulWidget { final WorkspaceSession session; }`.

- [ ] **Step 1: Implement**

`SftpTab` mirrors `SftpBrowserDialog`'s bootstrap (ensure tunnel to port 22 → get local port → build the browser body against `host: 'localhost', port: <localPort>, username`), but returns the browser body directly instead of inside a `Dialog(child: Container(width:900,height:700,...))`. Read `SftpBrowserDialog` (`sftp_browser.dart:601`) and its state (`_SftpBrowserDialogState.build`) and extract the `Column(...)` body into the tab; keep the notifier wiring (`createSftpBrowserProvider`, `initialize(host, port, username, l10n)`) identical. The only differences from the dialog: (a) no fixed 900×700 `Container` — use `Expanded`/full-size; (b) no close `IconButton` in the header (the tab strip owns closing); (c) the tunnel is established here (await `connect(projectId, zone, name, remotePort: 22)`), showing a "connecting" placeholder until the port is ready, then passing that port to the browser.

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import '../gcloud_provider.dart';
import '../../bridge/api.dart/api.dart';
import 'workspace_session.dart';
// import the SFTP browser body widget you extract/expose from sftp_browser.dart

class SftpTab extends ConsumerStatefulWidget {
  final WorkspaceSession session;
  const SftpTab({super.key, required this.session});

  @override
  ConsumerState<SftpTab> createState() => _SftpTabState();
}

class _SftpTabState extends ConsumerState<SftpTab> {
  int? _port;
  String? _username;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  Future<void> _boot() async {
    final vm = widget.session.target;
    try {
      final username = await getUsername();
      final port = await ref
          .read(activeConnectionsProvider.notifier)
          .connect(vm.projectId, vm.zone, vm.name, remotePort: 22);
      if (port == null) throw Exception('Tunnel could not be established');
      if (mounted) setState(() { _port = port; _username = username; });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (_error != null) {
      return Center(child: Text(l10n.workspaceTerminalError(_error!)));
    }
    if (_port == null) {
      return Center(child: Text(l10n.workspaceTerminalConnecting));
    }
    // Return the extracted SFTP browser body bound to localhost:_port / _username.
    return SftpBrowserBody(
      host: 'localhost',
      port: _port!,
      username: _username!,
      instanceName: widget.session.target.name,
    );
  }
}
```
To make `SftpBrowserBody` exist: in `sftp_browser.dart`, extract the current `_SftpBrowserDialogState.build`'s inner `Column` into a public `SftpBrowserBody` widget taking `{host, port, username, instanceName}`, and have `SftpBrowserDialog` render `Dialog(child: SizedBox(width:900,height:700, child: SftpBrowserBody(...)))`. This is a pure extraction — no behavior change — so the existing SFTP dialog still works.

- [ ] **Step 2: Verify**

Run: `flutter analyze lib/src/features/workspace/sftp_tab.dart lib/src/features/sftp_browser.dart && flutter test`
Expected: 0 errors; existing SFTP tests still pass.

- [ ] **Step 3: Commit**

```bash
git add lib/src/features/workspace/sftp_tab.dart lib/src/features/sftp_browser.dart
git commit -m "feat(workspace): SFTP tab reusing the browser body"
```

---

### Task 5: Overview tab (extract current detail pane)

**Files:**
- Create: `lib/src/features/workspace/overview_tab.dart`
- Modify: `lib/main.dart` (`InstanceDetailPane` ~line 2030)

**Interfaces:**
- Produces: `class OverviewTab extends ConsumerWidget { final ProjectAwareInstance target; }` rendering the current instance detail (resources + Actions) for a GIVEN VM (not the globally-selected one), and calling `workspaceProvider` for the connect actions.

- [ ] **Step 1: Extract**

Move the body of `InstanceDetailPane` (the resources card + Actions rows) into `OverviewTab`, parameterized by `target` instead of reading `multiProjectSelectedInstanceProvider`. The Actions that open SSH/SFTP must now call `ref.read(workspaceProvider.notifier).openSsh(target)` / `.openSftp(target)` (Task 7 wires the sidebar; here the buttons open tabs). RDP/VNC/Database/etc. keep their existing external-launch calls unchanged. Keep the existing layout (this task does NOT do the visual redesign — that is project A).

- [ ] **Step 2: Verify**

Run: `flutter analyze && flutter test`
Expected: 0 errors; tests pass.

- [ ] **Step 3: Commit**

```bash
git add lib/src/features/workspace/overview_tab.dart lib/main.dart
git commit -m "feat(workspace): overview tab extracted from InstanceDetailPane"
```

---

### Task 6: Workspace panel (tab strip + IndexedStack) + i18n

**Files:**
- Create: `lib/src/features/workspace/workspace_panel.dart`
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_es.arb`
- Test: `test/workspace_panel_test.dart`

**Interfaces:**
- Consumes: `workspaceProvider`, `WorkspaceSession`, `SessionType`, and the three tab widgets (Tasks 3-5).
- Produces: `class WorkspacePanel extends ConsumerWidget` — the widget that replaces `InstanceDetailPane` in the root `Row`.

- [ ] **Step 1: Write the failing widget test (IndexedStack keeps children mounted)**

`test/workspace_panel_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// A minimal stand-in proving the load-bearing invariant: switching the visible
// index of an IndexedStack must NOT dispose the hidden child (that is what keeps
// a live SSH session alive). WorkspacePanel must use IndexedStack, not TabBarView.
class _Probe extends StatefulWidget {
  const _Probe();
  @override
  State<_Probe> createState() => _ProbeState();
}
int _disposes = 0;
class _ProbeState extends State<_Probe> {
  @override
  void dispose() { _disposes++; super.dispose(); }
  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  testWidgets('IndexedStack keeps hidden children mounted across index change',
      (tester) async {
    _disposes = 0;
    var index = 0;
    await tester.pumpWidget(StatefulBuilder(builder: (context, setState) {
      return MaterialApp(
        home: Column(children: [
          TextButton(
            onPressed: () => setState(() => index = 1),
            child: const Text('switch'),
          ),
          Expanded(
            child: IndexedStack(index: index, children: const [
              _Probe(key: ValueKey('a')),
              SizedBox(key: ValueKey('b')),
            ]),
          ),
        ]),
      );
    }));
    await tester.tap(find.text('switch'));
    await tester.pumpAndSettle();
    expect(_disposes, 0); // the hidden _Probe was NOT disposed
  });
}
```

- [ ] **Step 2: Run to verify it passes as a guard** (this test encodes the requirement; it passes because IndexedStack behaves this way — it exists so a future refactor to TabBarView breaks it).

Run: `flutter test test/workspace_panel_test.dart`
Expected: PASS.

- [ ] **Step 3: Add i18n keys**

`lib/l10n/app_en.arb` (append): `"workspaceNoTabs": "Select a VM to get started"`, `"workspaceCloseTab": "Close tab"`, `"workspaceTabOverview": "Overview"`, `"workspaceTabSsh": "SSH"`, `"workspaceTabSftp": "SFTP"`.
`lib/l10n/app_es.arb`: `"workspaceNoTabs": "Selecciona una VM para empezar"`, `"workspaceCloseTab": "Cerrar pestaña"`, `"workspaceTabOverview": "Resumen"`, `"workspaceTabSsh": "SSH"`, `"workspaceTabSftp": "SFTP"`.
Run `flutter gen-l10n`; verify parity → `PARITY OK`.

- [ ] **Step 4: Implement the panel**

`lib/src/features/workspace/workspace_panel.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import 'workspace_provider.dart';
import 'workspace_session.dart';
import 'overview_tab.dart';
import 'ssh_terminal_tab.dart';
import 'sftp_tab.dart';

class WorkspacePanel extends ConsumerWidget {
  const WorkspacePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final ws = ref.watch(workspaceProvider);
    final notifier = ref.read(workspaceProvider.notifier);

    if (ws.sessions.isEmpty) {
      return Center(child: Text(l10n.workspaceNoTabs));
    }
    final activeIndex =
        ws.sessions.indexWhere((s) => s.id == ws.activeId).clamp(0, ws.sessions.length - 1);

    return Column(children: [
      _TabStrip(sessions: ws.sessions, activeId: ws.activeId, notifier: notifier),
      const Divider(height: 1),
      Expanded(
        child: IndexedStack(
          index: activeIndex,
          children: [
            for (final s in ws.sessions)
              KeyedSubtree(key: ValueKey(s.id), child: _content(s)),
          ],
        ),
      ),
    ]);
  }

  Widget _content(WorkspaceSession s) {
    switch (s.type) {
      case SessionType.overview:
        return OverviewTab(target: s.target);
      case SessionType.ssh:
        return SshTerminalTab(session: s);
      case SessionType.sftp:
        return SftpTab(session: s);
    }
  }
}

class _TabStrip extends StatelessWidget {
  final List<WorkspaceSession> sessions;
  final String? activeId;
  final WorkspaceNotifier notifier;
  const _TabStrip(
      {required this.sessions, required this.activeId, required this.notifier});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    String label(WorkspaceSession s) {
      final kind = switch (s.type) {
        SessionType.overview => l10n.workspaceTabOverview,
        SessionType.ssh => l10n.workspaceTabSsh,
        SessionType.sftp => l10n.workspaceTabSftp,
      };
      return '${s.target.name} · $kind';
    }

    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final s in sessions)
            _Tab(
              label: label(s),
              active: s.id == activeId,
              onTap: () => notifier.focus(s.id),
              onClose: () => notifier.close(s.id),
              closeTooltip: l10n.workspaceCloseTab,
            ),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final String closeTooltip;
  const _Tab(
      {required this.label,
      required this.active,
      required this.onTap,
      required this.onClose,
      required this.closeTooltip});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              width: 2,
              color: active ? scheme.primary : Colors.transparent,
            ),
          ),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label,
              style: TextStyle(
                  fontWeight: active ? FontWeight.bold : FontWeight.normal)),
          const SizedBox(width: 6),
          IconButton(
            icon: const Icon(Icons.close, size: 14),
            tooltip: closeTooltip,
            visualDensity: VisualDensity.compact,
            onPressed: onClose,
          ),
        ]),
      ),
    );
  }
}
```

- [ ] **Step 5: Verify**

Run: `flutter gen-l10n && flutter analyze && flutter test`
Expected: 0 errors; all tests pass (workspace provider, panel probe, es_overflow, tunnel l10n).

- [ ] **Step 6: Commit**

```bash
git add lib/src/features/workspace/workspace_panel.dart lib/l10n test/workspace_panel_test.dart
git commit -m "feat(workspace): tab strip + IndexedStack panel"
```

---

### Task 7: Wire the workspace into the dashboard; sidebar becomes a launcher

**Files:**
- Modify: `lib/main.dart` (root `Row` at ~437; `ResourceTree` click handlers at ~1448, ~1737, ~1923)

**Interfaces:**
- Consumes: `WorkspacePanel`, `workspaceProvider`.

- [ ] **Step 1: Replace the right pane**

In the root `Row` (`lib/main.dart:437`), replace `Expanded(child: InstanceDetailPane())` with `Expanded(child: WorkspacePanel())` (import from the workspace module). Keep `ResourceTree` and the `VerticalDivider`.

- [ ] **Step 2: Sidebar click opens/focuses an Overview tab**

In `ResourceTree`, the tap handlers that currently call `ref.read(multiProjectSelectedInstanceProvider.notifier).select(pai)` (lines ~1448, ~1737, ~1923) now ALSO call `ref.read(workspaceProvider.notifier).openOverview(pai)`. Keep the `select(...)` call only if it still drives the row-highlight; the highlight should track the active tab's VM instead — set `isSelected` from `ref.watch(workspaceProvider).activeSession?.vmKey == pai.uniqueKey` (add a convenience `WorkspaceSession? get activeSession` to `WorkspaceState` returning the session whose id == activeId, or compute inline). Remove any code path where selecting a VM rebuilds the right pane.

- [ ] **Step 3: Verify + manual smoke**

Run: `flutter analyze && flutter test && flutter build linux --debug`
Expected: 0 errors; tests pass; build succeeds. Manually: launching the app shows the empty-workspace hint; clicking a VM opens its Overview tab; opening SSH/SFTP from Overview adds tabs; switching VMs in the sidebar does not close existing tabs.

- [ ] **Step 4: Commit**

```bash
git add lib/main.dart
git commit -m "feat(workspace): wire tabbed panel into dashboard; sidebar launches tabs"
```

---

### Task 8: Close-with-live-sessions guard

**Files:**
- Modify: `lib/main.dart` (`main()` and the top-level app widget)
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_es.arb`

**Interfaces:**
- Consumes: `workspaceProvider` (`hasLiveSessions`), `window_manager`.

- [ ] **Step 1: Add the i18n keys**

`app_en.arb`: `"workspaceCloseTitle": "Close app?"`, and:
```json
"workspaceCloseWithSessions": "You have {count} active session(s). Close anyway?",
"@workspaceCloseWithSessions": { "placeholders": { "count": {"type": "int"} } },
"workspaceCloseAnyway": "Close anyway"
```
`app_es.arb`: `"workspaceCloseTitle": "¿Cerrar la aplicación?"`, `"workspaceCloseWithSessions": "Tienes {count} sesión(es) activa(s). ¿Cerrar de todos modos?"`, `"workspaceCloseAnyway": "Cerrar de todos modos"`. Run `flutter gen-l10n`.

- [ ] **Step 2: Register the window listener**

In `main()` (`lib/main.dart:50`), after `WidgetsFlutterBinding.ensureInitialized()`, initialize window_manager and set `await windowManager.setPreventClose(true);` (guard with `if (Platform.isLinux || Platform.isMacOS || Platform.isWindows)`). Make the top-level `MyApp` (or a wrapper) a `ConsumerStatefulWidget` implementing `WindowListener`; in `onWindowClose()`, read `ref.read(workspaceProvider.notifier).hasLiveSessions`; if false, `await windowManager.destroy()`; if true, show the confirm dialog (`workspaceCloseWithSessions` with the live count) and only `destroy()` on confirm. The live count = `ref.read(workspaceProvider).sessions.where((s)=>s.type!=SessionType.overview).length`.

- [ ] **Step 3: Verify + manual**

Run: `flutter gen-l10n && flutter analyze && flutter test && flutter build linux --debug`
Expected: green. Manually: with no SSH/SFTP tab, closing the window exits immediately; with a live SSH tab, closing shows the confirm dialog; cancel keeps the app; confirm exits.

- [ ] **Step 4: Commit**

```bash
git add lib/main.dart lib/l10n
git commit -m "feat(workspace): confirm on close when SSH/SFTP sessions are live"
```

---

### Task 9: Full gate + manual QA checklist

**Files:**
- Create: `docs/superpowers/plans/2026-07-22-tabbed-workspace-manual-qa.md`

- [ ] **Step 1: Full gate**

```bash
cd native && cargo test && cd ..
flutter gen-l10n && flutter analyze && flutter test && flutter build linux --debug
python3 -c "import json;a=json.load(open('lib/l10n/app_en.arb'));b=json.load(open('lib/l10n/app_es.arb'));ka={k for k in a if not k.startswith('@')};kb={k for k in b if not k.startswith('@')};print(sorted(ka^kb) or 'PARITY OK')"
```
Expected: Rust green (unchanged), 0 analyze errors, all Flutter tests pass, build succeeds, `PARITY OK`.

- [ ] **Step 2: Write the manual QA checklist**

Create `docs/superpowers/plans/2026-07-22-tabbed-workspace-manual-qa.md`:
```markdown
# Manual QA — tabbed workspace + SSH terminal (27H1)

Default gcloud tunnel engine; no env vars.

- [ ] Click a VM → its Overview tab opens; clicking again focuses it (no duplicate).
- [ ] Open SSH from Overview → terminal connects; type `ls`, output renders; resize the window and confirm the terminal reflows.
- [ ] Open SSH to a SECOND VM → both tabs alive; switching between them keeps both shells running (scrollback intact).
- [ ] Open SFTP tab for a VM that already has an SSH tab → both share one tunnel (check the log: one "Tunnel established" for that VM).
- [ ] Close one of two SSH tabs to the same VM → tunnel stays up; close the last → "Stopping tunnel" appears in the log.
- [ ] Drop the network briefly during an SSH session → tab shows "Session ended" + Reconnect; Reconnect restores a working shell.
- [ ] RDP / VNC buttons still launch the external client (not a tab).
- [ ] With a live SSH tab, close the app window → confirm dialog appears; Cancel keeps it; Close exits. With only Overview tabs, closing exits immediately.
- [ ] Reopen the app → starts with no tabs (no session restore, by design).
- [ ] Spanish: switch to ES and confirm tab labels, terminal states, and the close dialog are translated and not clipped.
```

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/plans/2026-07-22-tabbed-workspace-manual-qa.md
git commit -m "docs(workspace): manual QA checklist for tabbed workspace"
```

---

## Self-Review (done at write time)

- **Spec coverage:** §1 model → Task 1; §2 terminal → Tasks 2-3, SFTP tab → Task 4; §3 lifecycle (close tab/ref-count → Task 1; reconnect/error → Task 3; app-close guard → Task 8); §4 i18n → spread across Tasks 3/6/8; §5 deps → Task 2; §6 verification (provider unit test → Task 1; IndexedStack widget test → Task 6; manual → Task 9). Overview-as-tab + sidebar-launcher → Tasks 5, 7. Out-of-scope (visual redesign, RDP/VNC embed, restore) untouched. No gaps.
- **Placeholder scan:** the widget/integration tasks (4, 5, 7, 8) name exact files, line anchors, and the load-bearing code; where exact verbatim depends on reading a 4768-line file (extracting InstanceDetailPane, the sidebar handlers), the plan gives the precise interface and the calls to add rather than inventing line-by-line content that would be stale. The xterm/pty API-name caveats (viewWidth/TerminalView ctor) are flagged with how to confirm against the installed package.
- **Type consistency:** `SessionType {overview,ssh,sftp}`, `WorkspaceSession.{id,type,target,vmKey}`, `WorkspaceNotifier.{openOverview,openSsh,openSftp,focus,close,reorder,hasLiveSessions}`, `TerminalPhase {connectingTunnel,launching,connected,disconnected,error}`, `SshTerminalController.{terminal,phaseNotifier,errorDetail,start,reconnect,dispose}` — all referenced consistently across Tasks 1-8. Tunnel ops use `connect(projectId, zone, name, remotePort:22)` and `disconnect(name, 22)` matching `gcloud_provider.dart`.
