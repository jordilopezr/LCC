# SSH Port Forward (Sub-project B) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add an "SSH forward" mode to the Custom Tunnel dialog that runs a managed `gcloud compute ssh … -- -L … -N` process to reach localhost-only VM services that IAP can't.

**Architecture:** A new Rust `start_ssh_forward` mirrors `start_gcloud` (spawns a managed gcloud-ssh child, reuses `get_free_port`/`drain_stderr`/the success reattach) and registers it in the shared `TUNNELS` map under a `sshfwd:` key so it coexists with IAP tunnels and the backend-agnostic reaper reaps it. New bridge fns `start_ssh_forward`/`stop_ssh_forward` (bridge regen). Dart routes the dialog's mode to a `connectSshForward` path, keys the state under `sshfwd:`, excludes SSH forwards from the 30s health-check/auto-reconnect (avoids the composite-key mismatch), and labels them in the Tunnel Manager. Success/failure UX reuses sub-project A.

**Tech Stack:** Rust (std::process, gcloud CLI), flutter_rust_bridge 2.11.1, Flutter/Dart, gen-l10n.

## Global Constraints

- **Branch `27H1-Preview`.** Do not push.
- **frb 2.11.1 bridge regen** (Task 2 adds bridge fns): `/home/jlopezre/.cargo/bin/flutter_rust_bridge_codegen generate --rust-input "crate::api" --rust-root native --dart-output lib/src/bridge/api.dart`; confirm the diff is additive.
- **After Rust changes:** both `cargo build` and `cargo build --release` in `native/` must succeed (the app loads `native/target/release/libnative.so`).
- **Reuse, do not reinvent:** `get_free_port`, `drain_stderr`, the success-path stderr reattach, `Backend::Gcloud`, and the reaper already exist in `native/src/tunnel.rs` (from sub-project A + the reconciliation). SSH forward errors are plain `anyhow` (not `TunnelError`), mapped to `TunnelFailure { code: "protocol_error", detail }` like the gcloud IAP path.
- **The gcloud command** is exactly: `gcloud compute ssh <instance> --tunnel-through-iap --zone=<zone> --project=<project> -- -L <local>:localhost:<remote> -N`.
- **l10n EN/ES parity:** new keys in BOTH arb files; `@`-metadata EN-only; `flutter gen-l10n` after edits.
- **SSH forwards are NOT health-checked/auto-reconnected** in this version (the reaper still reaps idle ones); documented as intentional.
- **Code commits → NO `Co-Authored-By` trailer.** Verify Dart with `flutter analyze` (0 errors) + `flutter test`.

## File Structure

- **Modify** `native/src/tunnel.rs` — add `ssh_forward_args` (pure), `make_ssh_forward_key`, `spawn_ssh_forward`, `start_ssh_forward`, `stop_ssh_forward`; unit tests.
- **Modify** `native/src/api.rs` — add bridge fns `start_ssh_forward`, `stop_ssh_forward`.
- **Regenerate** `lib/src/bridge/api.dart/…` + `native/src/frb_generated.rs`.
- **Modify** `lib/src/features/gcloud_provider.dart` — `makeSshForwardKey`, `isSshForwardKey`, `parseTunnelKey` prefix handling, `connectSshForward`, `disconnectByKey` + route existing disconnect callers, skip `sshfwd:` in `_checkAllTunnels`.
- **Modify** `lib/src/features/workspace/overview_tab.dart` — dialog mode selector, dialog returns port+mode, handler routes, suppress localhost hint in SSH mode.
- **Modify** `lib/src/features/tunnel_manager_dialog.dart` — "SSH forward" label on `sshfwd:` cards.
- **Modify** `lib/l10n/app_en.arb`, `lib/l10n/app_es.arb` — new keys.
- **Test:** `native` cargo tests; `test/ssh_forward_key_test.dart`.

---

### Task 1: Rust — `start_ssh_forward` (managed gcloud ssh -L)

**Files:**
- Modify: `native/src/tunnel.rs`

**Interfaces:**
- Produces: `pub fn start_ssh_forward(project: &str, zone: &str, instance: &str, remote_port: u16) -> Result<u16>`; `pub fn stop_ssh_forward(instance: &str, remote_port: u16) -> Result<()>`; helpers `ssh_forward_args`, `make_ssh_forward_key`.

- [ ] **Step 1: Write the failing tests**

Add to `native/src/tunnel.rs` (new `#[cfg(test)] mod ssh_forward_tests`):
```rust
#[cfg(test)]
mod ssh_forward_tests {
    use super::{ssh_forward_args, make_ssh_forward_key};

    #[test]
    fn args_have_tunnel_through_iap_and_L_and_N() {
        let args = ssh_forward_args("vm1", "us-central1-a", "proj", 5000, 8443);
        assert_eq!(
            args,
            vec![
                "compute", "ssh", "vm1",
                "--tunnel-through-iap",
                "--zone=us-central1-a",
                "--project=proj",
                "--",
                "-L", "5000:localhost:8443",
                "-N",
            ]
        );
    }

    #[test]
    fn ssh_forward_key_is_prefixed() {
        assert_eq!(make_ssh_forward_key("vm1", 8443), "sshfwd:vm1:8443");
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd native && cargo test ssh_forward_tests`
Expected: FAIL — `ssh_forward_args`/`make_ssh_forward_key` not defined.

- [ ] **Step 3: Add the helpers**

In `native/src/tunnel.rs`, near `make_tunnel_key`/`start_gcloud`:
```rust
/// TUNNELS key for an SSH port-forward, distinct from IAP tunnels so both can
/// coexist for the same instance:port.
fn make_ssh_forward_key(instance: &str, remote_port: u16) -> String {
    format!("sshfwd:{}:{}", instance, remote_port)
}

/// gcloud args for an IAP-tunneled SSH local port forward
/// (`-L <local>:localhost:<remote> -N`). Pure, for testability.
fn ssh_forward_args(instance: &str, zone: &str, project: &str, local: u16, remote: u16) -> Vec<String> {
    vec![
        "compute".to_string(),
        "ssh".to_string(),
        instance.to_string(),
        "--tunnel-through-iap".to_string(),
        format!("--zone={}", zone),
        format!("--project={}", project),
        "--".to_string(),
        "-L".to_string(),
        format!("{}:localhost:{}", local, remote),
        "-N".to_string(),
    ]
}
```

- [ ] **Step 4: Run to verify the helper tests pass**

Run: `cd native && cargo test ssh_forward_tests`
Expected: PASS (2 tests).

- [ ] **Step 5: Add `spawn_ssh_forward`, `start_ssh_forward`, `stop_ssh_forward`**

```rust
/// Spawn the managed gcloud-ssh forward child, mirroring `start_gcloud`.
fn spawn_ssh_forward(project: &str, zone: &str, instance: &str, remote_port: u16) -> Result<IapTunnel> {
    let local = get_free_port()?;
    let args = ssh_forward_args(instance, zone, project, local, remote_port);
    let mut child = Command::new(crate::gcloud_bin::gcloud_path()?)
        .args(&args)
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| anyhow!("Failed to spawn gcloud ssh: {}", e))?;

    let mut stderr_handle = child.stderr.take();
    let mut tunnel = IapTunnel { local_port: local, backend: Backend::Gcloud(child), last_active: std::time::Instant::now() };
    std::thread::sleep(Duration::from_millis(1000));
    if !tunnel.is_process_alive() {
        return Err(anyhow!("ssh forward failed: {}", drain_stderr(stderr_handle.take())));
    }
    // gcloud ssh may provision keys / do a first connection: allow up to ~20s.
    for _ in 0..40 {
        if tunnel.is_port_listening() {
            if let Backend::Gcloud(ref mut c) = tunnel.backend {
                c.stderr = stderr_handle.take();
            }
            return Ok(tunnel);
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    let _ = tunnel.stop();
    Err(anyhow!("ssh forward timed out (port {} never listened): {}", local, drain_stderr(stderr_handle.take())))
}

/// Start (or reuse) an SSH port-forward. Registered in TUNNELS under a
/// `sshfwd:` key; the idle reaper reaps it like any tunnel.
pub fn start_ssh_forward(project: &str, zone: &str, instance: &str, remote_port: u16) -> Result<u16> {
    validate_project_id(project)?;
    validate_zone(zone)?;
    validate_instance_name(instance)?;
    let key = make_ssh_forward_key(instance, remote_port);
    {
        let mut tunnels = TUNNELS.lock().map_err(|_| anyhow!("Tunnel lock poisoned"))?;
        if let Some(t) = tunnels.get_mut(&key) {
            t.last_active = Instant::now();
            return Ok(t.local_port);
        }
    }
    let tunnel = spawn_ssh_forward(project, zone, instance, remote_port)?;
    let local = tunnel.local_port;
    let mut tunnels = TUNNELS.lock().map_err(|_| anyhow!("Tunnel lock poisoned"))?;
    tunnels.insert(key, tunnel);
    drop(tunnels);
    start_reaper_once();
    tracing::info!(instance, remote_port, local_port = local, "SSH forward established");
    Ok(local)
}

/// Stop an SSH port-forward.
pub fn stop_ssh_forward(instance: &str, remote_port: u16) -> Result<()> {
    let key = make_ssh_forward_key(instance, remote_port);
    let mut tunnels = TUNNELS.lock().map_err(|_| anyhow!("Tunnel lock poisoned"))?;
    if let Some(mut tunnel) = tunnels.remove(&key) {
        tracing::info!(instance, remote_port, local_port = tunnel.local_port, "Stopping SSH forward");
        tunnel.stop()?;
    }
    Ok(())
}
```

- [ ] **Step 6: Verify build + tests (both profiles)**

Run:
```bash
cd native && cargo build && cargo build --release && cargo test 2>&1 | tail -15 && cd ..
```
Expected: both builds succeed; all tests pass including `ssh_forward_tests`.

- [ ] **Step 7: Commit**

```bash
git add native/src/tunnel.rs
git commit -m "feat(tunnel): managed gcloud ssh -L port forward (start/stop_ssh_forward)"
```

---

### Task 2: Bridge + Dart provider wiring

**Files:**
- Modify: `native/src/api.rs`
- Regenerate: `lib/src/bridge/api.dart/…`, `native/src/frb_generated.rs`
- Modify: `lib/src/features/gcloud_provider.dart`
- Test: `test/ssh_forward_key_test.dart`

**Interfaces:**
- Consumes: `start_ssh_forward`/`stop_ssh_forward` (Rust, Task 1).
- Produces (Dart): `String makeSshForwardKey(String, int)`; `bool isSshForwardKey(String)`; `Future<int?> connectSshForward(String projectId, String zone, String instanceName, {required int remotePort})` on `ConnectionsNotifier`; `Future<void> disconnectByKey(String tunnelKey)`. Generated bridge: `startSshForward`, `stopSshForward`.

- [ ] **Step 1: Add the bridge functions in `native/src/api.rs`**

After `stop_connection`:
```rust
pub fn start_ssh_forward(
    project_id: String,
    zone: String,
    instance_name: String,
    remote_port: u16,
) -> Result<u16, TunnelFailure> {
    crate::tunnel::start_ssh_forward(&project_id, &zone, &instance_name, remote_port).map_err(|err| {
        TunnelFailure { code: "protocol_error".to_string(), detail: Some(err.to_string()) }
    })
}

pub fn stop_ssh_forward(instance_name: String, remote_port: u16) -> anyhow::Result<()> {
    crate::tunnel::stop_ssh_forward(&instance_name, remote_port)
}
```

- [ ] **Step 2: Regenerate the bridge**

Run: `/home/jlopezre/.cargo/bin/flutter_rust_bridge_codegen generate --rust-input "crate::api" --rust-root native --dart-output lib/src/bridge/api.dart`
Then `git diff --stat lib/src/bridge/ native/src/frb_generated.rs` — expect additive (`startSshForward`, `stopSshForward` getters). `cd native && cargo build && cd ..` to confirm the regenerated Rust compiles.

- [ ] **Step 3: Write the failing key test**

Create `test/ssh_forward_key_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/src/features/gcloud_provider.dart';

void main() {
  test('makeSshForwardKey is prefixed', () {
    expect(makeSshForwardKey('vm1', 8443), 'sshfwd:vm1:8443');
  });
  test('isSshForwardKey distinguishes', () {
    expect(isSshForwardKey('sshfwd:vm1:8443'), isTrue);
    expect(isSshForwardKey('vm1:8443'), isFalse);
  });
  test('parseTunnelKey strips the sshfwd prefix', () {
    expect(parseTunnelKey('sshfwd:vm1:8443'), ('vm1', 8443));
    expect(parseTunnelKey('vm1:8443'), ('vm1', 8443));
  });
}
```

- [ ] **Step 4: Run to verify it fails**

Run: `flutter test test/ssh_forward_key_test.dart`
Expected: FAIL — `makeSshForwardKey`/`isSshForwardKey` not defined.

- [ ] **Step 5: Add the key helpers + prefix-aware parse in `gcloud_provider.dart`**

Next to `makeTunnelKey`:
```dart
const _sshForwardPrefix = 'sshfwd:';

String makeSshForwardKey(String instanceName, int remotePort) =>
    '$_sshForwardPrefix$instanceName:$remotePort';

// 3 colon parts — so an IAP tunnel for an instance literally named `sshfwd`
// (key `sshfwd:<port>`, 2 parts) is not misclassified as a forward.
bool isSshForwardKey(String key) =>
    key.startsWith(_sshForwardPrefix) && key.split(':').length == 3;
```
Update `parseTunnelKey` to strip the prefix (only for real forward keys):
```dart
(String, int)? parseTunnelKey(String key) {
  final bare = isSshForwardKey(key)
      ? key.substring(_sshForwardPrefix.length)
      : key;
  final parts = bare.split(':');
  if (parts.length != 2) return null;
  final port = int.tryParse(parts[1]);
  if (port == null) return null;
  return (parts[0], port);
}
```

- [ ] **Step 6: Run the key test to verify it passes**

Run: `flutter test test/ssh_forward_key_test.dart`
Expected: PASS.

- [ ] **Step 7: Add `connectSshForward` (single-flight) + `disconnectByKey` + health-check skip**

In `ConnectionsNotifier`, add a single-flight `connectSshForward` mirroring `connect`/`_connect` but keyed with `makeSshForwardKey` and calling the `startSshForward` bridge fn (import it from the bridge if not already in scope):
```dart
Future<int?> connectSshForward(
  String projectId,
  String zone,
  String instanceName, {
  required int remotePort,
}) {
  final tunnelKey = makeSshForwardKey(instanceName, remotePort);
  final existing = _inFlightConnects[tunnelKey];
  if (existing != null) return existing;
  final future =
      _connectSshForward(projectId, zone, instanceName, remotePort, tunnelKey);
  _inFlightConnects[tunnelKey] = future;
  future.whenComplete(() {
    if (identical(_inFlightConnects[tunnelKey], future)) {
      _inFlightConnects.remove(tunnelKey);
    }
  });
  return future;
}

Future<int?> _connectSshForward(String projectId, String zone,
    String instanceName, int remotePort, String tunnelKey) async {
  state = {...state, tunnelKey: const TunnelState(status: 'connecting')};
  try {
    final port = await startSshForward(
      projectId: projectId,
      zone: zone,
      instanceName: instanceName,
      remotePort: remotePort,
    );
    final now = DateTime.now();
    state = {
      ...state,
      tunnelKey: TunnelState(
        status: 'connected',
        port: port,
        remotePort: remotePort,
        createdAt: now,
        lastHealthCheck: now,
        projectId: projectId,
        zone: zone,
        autoReconnectEnabled: false,
      ),
    };
    return port;
  } on TunnelFailure catch (e) {
    state = {
      ...state,
      tunnelKey: TunnelState(
        status: 'error',
        remotePort: remotePort,
        error: e.detail ?? e.code,
        errorCode: e.code,
        projectId: projectId,
        zone: zone,
      ),
    };
    return null;
  } catch (e) {
    state = {
      ...state,
      tunnelKey: TunnelState(
        status: 'error',
        remotePort: remotePort,
        error: e.toString(),
        projectId: projectId,
        zone: zone,
      ),
    };
    return null;
  }
}
```
Add `disconnectByKey` and make `disconnect` delegate to it:
```dart
Future<void> disconnectByKey(String tunnelKey) async {
  final parsed = parseTunnelKey(tunnelKey);
  if (parsed != null) {
    try {
      if (isSshForwardKey(tunnelKey)) {
        await stopSshForward(instanceName: parsed.$1, remotePort: parsed.$2);
      } else {
        await stopConnection(instanceName: parsed.$1, remotePort: parsed.$2);
      }
    } catch (e) {
      debugPrint('Error stopping tunnel $tunnelKey: $e');
    }
  }
  final newState = Map<String, TunnelState>.from(state);
  newState.remove(tunnelKey);
  state = newState;
}
```
Change the existing `disconnect(String instanceName, int remotePort)` body to `return disconnectByKey(makeTunnelKey(instanceName, remotePort));` (IAP callers keep working). In `disconnectAll`, iterate `state.entries` and call `disconnectByKey(entry.key)`. In `disconnectAllForInstance`, filter by `parseTunnelKey(entry.key)?.$1 == instanceName` (NOT `entry.key.startsWith('$instanceName:')`, which misses `sshfwd:` keys) and call `disconnectByKey(entry.key)` — so an instance's SSH forwards are stopped too, not leaked.

In `_checkAllTunnels`, at the top of the per-entry loop (before the health logic), skip SSH forwards:
```dart
if (isSshForwardKey(tunnelKey)) continue; // not auto-health-checked in this version
```

- [ ] **Step 8: Verify + commit**

Run:
```bash
flutter test test/ssh_forward_key_test.dart 2>&1 | tail -3
flutter analyze lib/src/features/gcloud_provider.dart 2>&1 | tail -4
cd native && cargo build --release 2>&1 | tail -2 && cd ..
```
Expected: key tests pass; analyze 0 errors; release lib builds. Commit:
```bash
git add native/src/api.rs lib/src/bridge/ native/src/frb_generated.rs lib/src/features/gcloud_provider.dart test/ssh_forward_key_test.dart
git commit -m "feat(tunnel): SSH-forward bridge fns + Dart provider (connectSshForward, key routing)"
```

---

### Task 3: UI — dialog mode selector + Tunnel Manager label + l10n

**Files:**
- Modify: `lib/src/features/workspace/overview_tab.dart`
- Modify: `lib/src/features/tunnel_manager_dialog.dart`
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_es.arb`

**Interfaces:**
- Consumes: `connectSshForward` (Task 2); `isSshForwardKey` (Task 2); `localizedError`/`isBackendUnreachable` (sub-project A).

- [ ] **Step 1: Add l10n keys**

`lib/l10n/app_en.arb`:
```json
  "customTunnelModeDirect": "Direct (IAP)",
  "customTunnelModeSshForward": "SSH forward",
  "customTunnelSshForwardHint": "For services listening only on 127.0.0.1 on the VM (IAP can't reach them).",
  "tunnelKindSshForward": "SSH forward",
```
`lib/l10n/app_es.arb`:
```json
  "customTunnelModeDirect": "Directo (IAP)",
  "customTunnelModeSshForward": "Reenvío SSH",
  "customTunnelSshForwardHint": "Para servicios que escuchan solo en 127.0.0.1 en la VM (IAP no los alcanza).",
  "tunnelKindSshForward": "Reenvío SSH",
```
Run `flutter gen-l10n`.

- [ ] **Step 2: Make `_showCustomTunnelDialog` return port + mode**

Change its signature to `Future<({int port, bool sshForward})?>`. Add a `bool sshForward = false;` state var in the `StatefulBuilder`. At the top of the dialog `Column` (before the presets), add a mode selector:
```dart
SegmentedButton<bool>(
  segments: [
    ButtonSegment(value: false, label: Text(l10n.customTunnelModeDirect)),
    ButtonSegment(value: true, label: Text(l10n.customTunnelModeSshForward)),
  ],
  selected: {sshForward},
  onSelectionChanged: (s) => setState(() => sshForward = s.first),
),
if (sshForward) ...[
  const SizedBox(height: 8),
  Text(l10n.customTunnelSshForwardHint,
      style: const TextStyle(fontSize: 12, color: Colors.grey)),
],
const SizedBox(height: 12),
```
Change the two `Navigator.pop` calls: cancel → `Navigator.pop(context, null)`; connect → `Navigator.pop(context, (port: selectedPort!, sshForward: sshForward))`.

- [ ] **Step 3: Route the handler by mode**

In the Custom Tunnel button `onPressed` (from sub-project A), change the result handling:
```dart
final choice = await _showCustomTunnelDialog(context);
if (choice == null || !context.mounted) return;
final messenger = ScaffoldMessenger.of(context);
final localPort = choice.sshForward
    ? await ref.read(activeConnectionsProvider.notifier).connectSshForward(
        selectedProject, target.zone, target.name, remotePort: choice.port)
    : await ref.read(activeConnectionsProvider.notifier).connect(
        selectedProject, target.zone, target.name, remotePort: choice.port);
if (!context.mounted) return;
if (localPort != null) {
  final address = '127.0.0.1:$localPort';
  messenger.showSnackBar(SnackBar(
    content: Text(l10n.customTunnelReady(address)),
    action: SnackBarAction(
      label: l10n.commonCopy,
      onPressed: () {
        Clipboard.setData(ClipboardData(text: address));
        messenger.showSnackBar(
            SnackBar(content: Text(l10n.customTunnelAddressCopied)));
      },
    ),
  ));
} else {
  final key = choice.sshForward
      ? makeSshForwardKey(target.name, choice.port)
      : makeTunnelKey(target.name, choice.port);
  final error = ref.read(activeConnectionsProvider)[key]?.error ?? '';
  await _showCustomTunnelError(
    context,
    error: error,
    projectId: selectedProject,
    zone: target.zone,
    instanceName: target.name,
    // SSH forward is itself the localhost fix — don't show that hint.
    showLocalhostHint: !choice.sshForward,
  );
}
```
Add a `required bool showLocalhostHint` parameter to `_showCustomTunnelError` (default the existing behavior to `true` at its other/only call site) and gate the hint on `showLocalhostHint && isBackendUnreachable(error)` instead of `isBackendUnreachable(error)` alone. Ensure `makeSshForwardKey` is imported (it's in `gcloud_provider.dart`, already imported).

- [ ] **Step 4: Label SSH forwards in the Tunnel Manager**

In `lib/src/features/tunnel_manager_dialog.dart`, `_TunnelCard.build` (around line 260, after `parseTunnelKey`), when `isSshForwardKey(tunnelKey)` show a small badge/label using `l10n.tunnelKindSshForward` next to the instance name (a `Chip`/`Text` with a distinct color). Import `isSshForwardKey` from `gcloud_provider.dart` if needed (the file already imports it).

- [ ] **Step 5: Full gate**

```bash
flutter gen-l10n
python3 -c "import json; en=json.load(open('lib/l10n/app_en.arb')); es=json.load(open('lib/l10n/app_es.arb')); ek={k for k in en if not k.startswith('@')}; sk={k for k in es if not k.startswith('@')}; print('missing ES:', ek-sk, '| missing EN:', sk-ek)"
flutter analyze 2>&1 | grep -cE '^\s*error •'   # expect 0
flutter test 2>&1 | tail -3                       # All tests passed
flutter build linux --debug 2>&1 | tail -2        # Built
```
Expected: no missing keys; 0 analyze errors; suite green; app builds.

- [ ] **Step 6: Commit**

```bash
git add lib/
git commit -m "feat(tunnel): SSH-forward mode in Custom Tunnel dialog + manager label"
```

---

## Future work (documented per the spec)

Replace the managed `gcloud compute ssh -- -L` with a **native `ssh2` local forward** over the existing IAP tunnel to :22 (as SFTP already does: `Session` + `userauth_agent`/`userauth_pubkey_file` + a local listener opening `direct-tcpip` channels to `localhost:<remote>`), to drop the gcloud dependency for the forward. Add to the project roadmap.

## Manual QA (after implementation)

- On a VM with a service bound to `127.0.0.1:<port>` (the 8443 case): Custom Tunnel → **SSH forward** → tunnel is created, shows `127.0.0.1:<localPort>`, and a client connecting there reaches the service (which direct IAP could not). It appears in the Tunnel Manager labelled "SSH forward" and can be stopped. Leaving it idle >2 min lets the reaper reap it.
- Direct (IAP) mode still behaves exactly as before.
- Spanish: mode labels, the SSH-forward hint, and the manager label are translated.
