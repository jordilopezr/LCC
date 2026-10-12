# Custom Tunnel Local Port Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user optionally choose the local port for a Custom Tunnel in both modes (Direct IAP and SSH forward); empty keeps today's auto-assignment.

**Architecture:** Thread a `local_port: Option<u16>` (`None` = auto) from the Custom Tunnel dialog down through the Dart provider, the regenerated bridge, and the Rust tunnel stack (gcloud + native backends + SSH forward). gcloud paths pre-bind the chosen port for a clean error; the native path reuses the existing `TunnelError::LocalPortUnavailable`.

**Tech Stack:** Rust (tokio, std::net), flutter_rust_bridge codegen, Flutter/Riverpod, flutter gen-l10n. Spec: `docs/superpowers/specs/2026-08-06-custom-tunnel-local-port-design.md`.

## Global Constraints

- `None`/`null` local port = auto (unchanged: `get_free_port()` for gcloud paths, bind `127.0.0.1:0` for the native path). Every existing caller that omits a local port keeps auto behavior.
- UI validation range **1–65535**, no ≥1024 restriction; occupied/privileged ports surface a clean error, not a UI block.
- gcloud paths (`start_gcloud`, `spawn_ssh_forward`): a chosen port is pre-bound via `ensure_local_port_available(port)` → error `"Local port {p} is not available: {e}"`. Native path: `bind_local_port(Some(p))` → `TunnelError::LocalPortUnavailable { port: p }` (variant already exists, code `"local_port_unavailable"`).
- Dedup key stays `instance:remote` (unchanged). Auto-reconnect stays auto (out of scope): the reconnect `startConnection` call passes `localPort: null`.
- Bridge regen command (per project memory): `flutter_rust_bridge_codegen generate --rust-input "crate::api" --rust-root native --dart-output lib/src/bridge/api.dart` (binary at `/home/jlopezre/.cargo/bin/flutter_rust_bridge_codegen`). Do NOT hand-edit generated files under `lib/src/bridge/api.dart/`.
- Rebuild BOTH `cargo build` and `cargo build --release` before finishing (the app loads `native/target/release/libnative.so`). Do NOT run `dart format`.
- The repo does NOT analyze clean (~85 pre-existing analyzer issues, 0 errors); the bar is **no new issues / no new errors**, not "No issues found!".
- Code commits must NOT carry the `Co-Authored-By: Claude` trailer (docs commits only). Branch: `27H1-Preview`.

---

### Task 1: Thread `local_port: Option<u16>` through the Rust tunnel stack

All signature changes land together so the crate keeps compiling. Covers the native path (`iap_tunnel/listener.rs`), the gcloud + SSH-forward paths and the new pre-bind helper (`tunnel.rs`), and the two bridge entry points (`api.rs`).

**Files:**
- Modify: `native/src/iap_tunnel/listener.rs`
- Modify: `native/src/tunnel.rs`
- Modify: `native/src/api.rs`

**Interfaces:**
- Consumes: existing `TunnelError::LocalPortUnavailable { port: u16 }` (`iap_tunnel/error.rs`), `get_free_port()`, `ssh_forward_args`, `make_tunnel_key`/`make_ssh_forward_key`.
- Produces (used by Task 2 after regen): `pub fn start_connection(project_id, zone, instance_name, remote_port: u16, local_port: Option<u16>) -> Result<u16, TunnelFailure>` and `pub fn start_ssh_forward(project_id, zone, instance_name, remote_port: u16, local_port: Option<u16>) -> Result<u16, TunnelFailure>`.

- [ ] **Step 1: Native path — `bind_local_port` takes `Option<u16>`**

In `native/src/iap_tunnel/listener.rs`, change `bind_local_port` to honor a requested port:

```rust
async fn bind_local_port(local_port: Option<u16>) -> Result<TcpListener, TunnelError> {
    let requested = local_port.unwrap_or(0);
    TcpListener::bind(("127.0.0.1", requested))
        .await
        .map_err(|_| TunnelError::LocalPortUnavailable { port: requested })
}
```

Update `pub async fn start(...)` to take and forward the port:

```rust
pub async fn start(target: TunnelTarget, local_port: Option<u16>) -> Result<NativeTunnel, TunnelError> {
    let listener = bind_local_port(local_port).await?;
    // ...rest unchanged (local_addr, token, probe, spawn_accept_loop)...
```

In `start_without_probe` (the `#[cfg(test)]` helper), change its one call to `bind_local_port(None).await?`.

- [ ] **Step 2: Native path — add the two `bind_local_port` tests**

In the `#[cfg(test)] mod tests` of `native/src/iap_tunnel/listener.rs`, add (use the same async-test attribute the existing async tests in this module use — `#[tokio::test]`):

```rust
#[tokio::test]
async fn bind_local_port_honors_a_specific_free_port() {
    let probe = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = probe.local_addr().unwrap().port();
    drop(probe);
    let listener = super::bind_local_port(Some(port)).await.unwrap();
    assert_eq!(listener.local_addr().unwrap().port(), port);
}

#[tokio::test]
async fn bind_local_port_reports_unavailable_when_taken() {
    let held = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = held.local_addr().unwrap().port();
    let err = super::bind_local_port(Some(port)).await.unwrap_err();
    assert!(matches!(err, TunnelError::LocalPortUnavailable { port: p } if p == port));
}
```

- [ ] **Step 3: `tunnel.rs` — add `ensure_local_port_available`**

In `native/src/tunnel.rs`, add near `get_free_port` (uses the same `std::net::TcpListener` already imported):

```rust
/// Pre-bind a specific local port to fail fast with a clean message when it is
/// occupied or privileged, before spawning gcloud. Same brief TOCTOU window as
/// get_free_port (bind, drop, then the child rebinds).
fn ensure_local_port_available(port: u16) -> Result<()> {
    match TcpListener::bind(("127.0.0.1", port)) {
        Ok(_) => Ok(()),
        Err(e) => Err(anyhow!("Local port {} is not available: {}", port, e)),
    }
}
```

- [ ] **Step 4: `tunnel.rs` — thread `local_port` through the gcloud + SSH-forward + native fns**

Make these signature + body changes in `native/src/tunnel.rs`:

`start_tunnel` — add the param and forward it to both backends:
```rust
pub fn start_tunnel(project: &str, zone: &str, instance: &str, remote_port: u16, local_port: Option<u16>) -> Result<u16> {
    // ...validation + dedup unchanged...
    if forced == Some(TunnelEngine::Native) {
        let tunnel = start_native(project, zone, instance, remote_port, local_port)?;
        // ...unchanged...
    }
    let tunnel = start_gcloud(project, zone, instance, remote_port, local_port)?;
    // ...unchanged...
}
```

`start_native` — add the param, forward to `iap_tunnel::start`:
```rust
fn start_native(project: &str, zone: &str, instance: &str, remote_port: u16, local_port: Option<u16>) -> Result<IapTunnel> {
    let target = crate::iap_tunnel::TunnelTarget::new(project, zone, instance, remote_port);
    let native = crate::logging::block_on(crate::iap_tunnel::start(target, local_port))
        .map_err(anyhow::Error::new)?;
    Ok(IapTunnel { local_port: native.local_port, backend: Backend::Native(native), last_active: std::time::Instant::now() })
}
```

`start_gcloud` — add the param; replace `let port = get_free_port()?;` with:
```rust
fn start_gcloud(project: &str, zone: &str, instance: &str, remote_port: u16, local_port: Option<u16>) -> Result<IapTunnel> {
    let port = match local_port {
        Some(p) => { ensure_local_port_available(p)?; p }
        None => get_free_port()?,
    };
    // ...rest unchanged (uses `port` in --local-host-port and IapTunnel)...
}
```

`spawn_ssh_forward` — add the param; replace `let local = get_free_port()?;` with:
```rust
fn spawn_ssh_forward(project: &str, zone: &str, instance: &str, remote_port: u16, local_port: Option<u16>) -> Result<IapTunnel> {
    let local = match local_port {
        Some(p) => { ensure_local_port_available(p)?; p }
        None => get_free_port()?,
    };
    // ...rest unchanged (ssh_forward_args(instance, zone, project, local, remote_port), IapTunnel)...
}
```

`start_ssh_forward` — add the param; forward to `spawn_ssh_forward`:
```rust
pub fn start_ssh_forward(project: &str, zone: &str, instance: &str, remote_port: u16, local_port: Option<u16>) -> Result<u16> {
    // ...validation + dedup unchanged...
    let tunnel = spawn_ssh_forward(project, zone, instance, remote_port, local_port)?;
    // ...rest unchanged...
}
```

- [ ] **Step 5: `tunnel.rs` — add the `ensure_local_port_available` tests**

In the `#[cfg(test)] mod tests` of `native/src/tunnel.rs`, add:

```rust
#[test]
fn ensure_local_port_available_ok_for_free_port() {
    let probe = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = probe.local_addr().unwrap().port();
    drop(probe);
    assert!(super::ensure_local_port_available(port).is_ok());
}

#[test]
fn ensure_local_port_available_errs_when_taken() {
    let _held = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = _held.local_addr().unwrap().port();
    assert!(super::ensure_local_port_available(port).is_err());
}
```

- [ ] **Step 6: `api.rs` — thread `local_port` through both bridge fns**

In `native/src/api.rs`, add `local_port: Option<u16>` to both fns and forward it:

```rust
pub fn start_connection(
    project_id: String,
    zone: String,
    instance_name: String,
    remote_port: u16,
    local_port: Option<u16>,
) -> Result<u16, TunnelFailure> {
    crate::tunnel::start_tunnel(&project_id, &zone, &instance_name, remote_port, local_port).map_err(|err| {
        // ...existing downcast/TunnelFailure mapping unchanged...
    })
}

pub fn start_ssh_forward(
    project_id: String,
    zone: String,
    instance_name: String,
    remote_port: u16,
    local_port: Option<u16>,
) -> Result<u16, TunnelFailure> {
    crate::tunnel::start_ssh_forward(&project_id, &zone, &instance_name, remote_port, local_port).map_err(|err| {
        TunnelFailure { code: "protocol_error".to_string(), detail: Some(err.to_string()) }
    })
}
```

- [ ] **Step 7: Build and test**

Run: `cd native && cargo build 2>&1 | tail -20`
Expected: builds with no errors and no new warnings for the touched items.

Run: `cd native && cargo test 2>&1 | tail -25`
Expected: the four new tests pass (`bind_local_port_honors_a_specific_free_port`, `bind_local_port_reports_unavailable_when_taken`, `ensure_local_port_available_ok_for_free_port`, `ensure_local_port_available_errs_when_taken`), and the existing suite (including `start_binds_a_local_port_immediately`, `ssh_forward_args` test) stays green.

- [ ] **Step 8: Commit**

```bash
cd /home/jlopezre/GitHub/LCC
git add native/src/iap_tunnel/listener.rs native/src/tunnel.rs native/src/api.rs
git commit -m "feat(tunnel): thread optional local_port through the tunnel stack"
```

---

### Task 2: Regenerate the bridge and thread `localPort` through the Dart provider

**Files:**
- Regenerate: `lib/src/bridge/api.dart/` (via codegen — do not hand-edit)
- Modify: `lib/src/features/gcloud_provider.dart`

**Interfaces:**
- Consumes: regenerated `startConnection({..., required int remotePort, int? localPort})` and `startSshForward({..., required int remotePort, int? localPort})`.
- Produces (used by Task 3): `connect(String projectId, String zone, String instanceName, {int remotePort, int? localPort})` and `connectSshForward(String projectId, String zone, String instanceName, {required int remotePort, int? localPort})`.

- [ ] **Step 1: Regenerate the bridge**

Run: `/home/jlopezre/.cargo/bin/flutter_rust_bridge_codegen generate --rust-input "crate::api" --rust-root native --dart-output lib/src/bridge/api.dart`
Expected: regenerates `lib/src/bridge/api.dart/api.dart` so `startConnection`/`startSshForward` gain an `int? localPort` named parameter.

Run: `flutter analyze lib/src/bridge/ 2>&1 | tail -20`
Expected: no errors in generated code. (Per project memory, regen can occasionally touch other structs — if analyze flags a call site in `gcloud_provider.dart` or `manual_instance_dialog.dart` unrelated to localPort, fix it minimally and note it in the report.)

- [ ] **Step 2: Thread `localPort` into `connect`/`_connect`**

In `lib/src/features/gcloud_provider.dart`, add the optional param to `connect` (line ~847):

```dart
  Future<int?> connect(
    String projectId,
    String zone,
    String instanceName, {
    int remotePort = 3389,
    int? localPort,
  }) {
```

Pass it into the internal call (line ~867):

```dart
    final future = _connect(projectId, zone, instanceName, remotePort, tunnelKey, localPort);
```

Add the param to `_connect` (line ~879) and forward it to `startConnection` (line ~895):

```dart
  Future<int?> _connect(
    String projectId,
    String zone,
    String instanceName,
    int remotePort,
    String tunnelKey,
    int? localPort,
  ) async {
    // ...unchanged until the startConnection call...
      final port = await startConnection(
        projectId: projectId,
        zone: zone,
        instanceName: instanceName,
        remotePort: remotePort,
        localPort: localPort,
```

- [ ] **Step 3: Keep the auto-reconnect path on auto**

Find the other `startConnection(...)` call in `gcloud_provider.dart` (the auto-reconnect path, ~line 691). Add `localPort: null,` to it (auto — preserving the chosen port across reconnect is out of scope):

```dart
      final port = await startConnection(
        // ...existing named args...
        localPort: null,
      );
```

- [ ] **Step 4: Thread `localPort` into `connectSshForward`/`_connectSshForward`**

Add the param to `connectSshForward` (line ~950) and forward it:

```dart
  Future<int?> connectSshForward(
    String projectId,
    String zone,
    String instanceName, {
    required int remotePort,
    int? localPort,
  }) {
    final tunnelKey = makeSshForwardKey(instanceName, remotePort);
    final existing = _inFlightConnects[tunnelKey];
    if (existing != null) return existing;
    final future =
        _connectSshForward(projectId, zone, instanceName, remotePort, tunnelKey, localPort);
    // ...unchanged...
  }
```

Add the param to `_connectSshForward` (line ~970) and forward to `startSshForward` (line ~974):

```dart
  Future<int?> _connectSshForward(String projectId, String zone,
      String instanceName, int remotePort, String tunnelKey, int? localPort) async {
    state = {...state, tunnelKey: const TunnelState(status: 'connecting')};
    try {
      final port = await startSshForward(
        projectId: projectId,
        zone: zone,
        instanceName: instanceName,
        remotePort: remotePort,
        localPort: localPort,
      );
```

- [ ] **Step 5: Analyze + test**

Run: `flutter analyze lib/src/features/gcloud_provider.dart 2>&1 | tail -20`
Expected: no new issues attributable to this change.

Run: `flutter test 2>&1 | tail -15`
Expected: the existing suite stays green (no test targets these methods directly; this confirms no compile breakage across the app).

- [ ] **Step 6: Commit**

```bash
cd /home/jlopezre/GitHub/LCC
git add lib/src/bridge/api.dart lib/src/features/gcloud_provider.dart
git commit -m "feat(tunnel): thread optional localPort through the Dart connect providers"
```

---

### Task 3: Custom Tunnel dialog — optional "Local port" field + wiring

**Files:**
- Modify: `lib/src/features/workspace/overview_tab.dart`
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_es.arb`

**Interfaces:**
- Consumes: `connect(..., {int? localPort})`, `connectSshForward(..., {int? localPort})` (Task 2).
- Produces: `_showCustomTunnelDialog` now returns `Future<({int port, bool sshForward, int? localPort})?>`.

- [ ] **Step 1: Add the two i18n keys and regenerate**

In `lib/l10n/app_en.arb`, near the other `customTunnel*` keys, add:

```json
  "customTunnelLocalPortLabel": "Local port (optional)",
  "customTunnelLocalPortHint": "Empty = auto-assigned",
```

In `lib/l10n/app_es.arb`, near the other `customTunnel*` keys, add:

```json
  "customTunnelLocalPortLabel": "Puerto local (opcional)",
  "customTunnelLocalPortHint": "Vacío = automático",
```

(Mind the JSON commas.) Then run: `flutter gen-l10n`
Expected: `AppLocalizations` gains `customTunnelLocalPortLabel` and `customTunnelLocalPortHint`.

- [ ] **Step 2: Change the dialog's return type and add local-port state**

In `lib/src/features/workspace/overview_tab.dart::_showCustomTunnelDialog`:

- Change the method return type to `Future<({int port, bool sshForward, int? localPort})?>`.
- Change the `showDialog<...>` type argument to `({int port, bool sshForward, int? localPort})`.
- Next to `final customPortController = TextEditingController();` add:
  ```dart
  final localPortController = TextEditingController();
  ```
- Next to `int? selectedPort;` add:
  ```dart
  int? localPort;
  bool localPortValid = true; // empty is valid (auto)
  ```
- In the `finally` block, alongside `customPortController.dispose();` add `localPortController.dispose();`.

- [ ] **Step 3: Add the "Local port" TextField (visible in both modes)**

In the dialog body, immediately AFTER the existing custom-port `TextField` (the one bound to `customPortController`, ends ~line 1151) and before the `if (selectedPort != null) ...` confirmation block, insert:

```dart
                    const SizedBox(height: 12),
                    TextField(
                      controller: localPortController,
                      decoration: InputDecoration(
                        labelText: l10n.customTunnelLocalPortLabel,
                        hintText: l10n.customTunnelLocalPortHint,
                        prefixIcon: const Icon(Icons.dns_outlined),
                        border: const OutlineInputBorder(),
                        errorText: localPortValid ? null : l10n.appCustomPortHint,
                      ),
                      keyboardType: TextInputType.number,
                      onChanged: (value) {
                        setState(() {
                          if (value.isEmpty) {
                            localPort = null;
                            localPortValid = true;
                          } else {
                            final p = int.tryParse(value);
                            if (p != null && p >= 1 && p <= 65535) {
                              localPort = p;
                              localPortValid = true;
                            } else {
                              localPort = null;
                              localPortValid = false;
                            }
                          }
                        });
                      },
                    ),
```

- [ ] **Step 4: Gate the Connect button on local-port validity and return the record**

In the Connect `ElevatedButton` (line ~1189):

```dart
                ElevatedButton(
                  onPressed: (selectedPort == null || !localPortValid)
                      ? null
                      : () => Navigator.pop(context, (
                          port: selectedPort!,
                          sshForward: sshForward,
                          localPort: localPort,
                        )),
                  child: Text(l10n.commonConnect),
                ),
```

- [ ] **Step 5: Pass `choice.localPort` to the connect calls**

In the Custom Tunnel button handler (line ~479-488), thread the chosen local port:

```dart
                        final localPort = choice.sshForward
                            ? await ref
                                .read(activeConnectionsProvider.notifier)
                                .connectSshForward(
                                    selectedProject, target.zone, target.name,
                                    remotePort: choice.port,
                                    localPort: choice.localPort)
                            : await ref
                                .read(activeConnectionsProvider.notifier)
                                .connect(selectedProject, target.zone, target.name,
                                    remotePort: choice.port,
                                    localPort: choice.localPort);
```

(The local variable `localPort` here is the RESULT port from the notifier — unrelated to `choice.localPort`; leave its name as-is to minimize the diff.)

- [ ] **Step 6: Analyze + test**

Run: `flutter analyze lib/src/features/workspace/overview_tab.dart 2>&1 | tail -20`
Expected: no new issues.

Run: `flutter test 2>&1 | tail -15`
Expected: existing suite green.

- [ ] **Step 7: Commit**

```bash
cd /home/jlopezre/GitHub/LCC
git add lib/src/features/workspace/overview_tab.dart lib/l10n/app_en.arb lib/l10n/app_es.arb lib/l10n/gen/
git commit -m "feat(tunnel): choose local port in the Custom Tunnel dialog"
```

---

### Task 4: Full gate + manual QA checklist

**Files:**
- Create: `docs/superpowers/plans/2026-08-06-custom-tunnel-local-port-manual-qa.md`

- [ ] **Step 1: Rust release + full test**

Run: `cd native && cargo test 2>&1 | tail -8` — Expected: all pass.
Run: `cd native && cargo build 2>&1 | tail -5` and `cd native && cargo build --release 2>&1 | tail -5` — Expected: both succeed (release `.so` is what the app loads).

- [ ] **Step 2: Flutter gate**

Run: `flutter analyze 2>&1 | tail -8` — Expected: zero ERRORS; no issue in the files this feature touched (over the ~85 pre-existing baseline).
Run: `flutter test 2>&1 | tail -8` — Expected: all pass.
Run: `flutter build linux --release 2>&1 | tail -5` — Expected: `✓ Built build/linux/x64/release/bundle/lightweight_cloud_connector`.

- [ ] **Step 3: Write the manual QA checklist**

Create `docs/superpowers/plans/2026-08-06-custom-tunnel-local-port-manual-qa.md`:

```markdown
# Manual QA — Choose local port for Custom Tunnel

Run on a real desktop with a reachable GCP VM.

- [ ] Custom Tunnel → Direct (IAP) mode: leave "Local port" empty → connects on an auto-assigned port (as before).
- [ ] Custom Tunnel → Direct (IAP) mode: type a free local port (e.g. 15900) → success snackbar reads `127.0.0.1:15900`.
- [ ] Custom Tunnel → SSH forward mode: type a free local port → forward established on exactly that port.
- [ ] Type a local port already in use → clear error dialog ("Local port N is not available: …" / localizedError), not a silent failure.
- [ ] Type a non-numeric / out-of-range value → inline field error, Connect disabled.
- [ ] Reopen the dialog for a VM:port that already has a tunnel and pick a different local port → returns the existing tunnel's port (dedup), shown truthfully in the snackbar.
- [ ] Spanish locale: the field reads "Puerto local (opcional)" with hint "Vacío = automático".
```

- [ ] **Step 4: Commit**

```bash
cd /home/jlopezre/GitHub/LCC
git add docs/superpowers/plans/2026-08-06-custom-tunnel-local-port-manual-qa.md
git commit -m "docs(qa): manual QA checklist for Custom Tunnel local port"
```

---

## Self-Review

**1. Spec coverage:**
- Optional local-port field, both modes → Task 3 (Steps 3-5). ✓
- `local_port: Option<u16>` through Rust (gcloud + native + SSH forward) → Task 1 (Steps 1,4). ✓
- `ensure_local_port_available` pre-bind + clean error → Task 1 Step 3; native `LocalPortUnavailable` → Task 1 Step 1. ✓
- Bridge regen; `start_connection`/`start_ssh_forward` gain `local_port` → Task 1 Step 6 + Task 2 Step 1. ✓
- Dart `connect`/`connectSshForward` gain `int? localPort`; reconnect passes null → Task 2 (Steps 2-4). ✓
- Record `({int port, bool sshForward, int? localPort})` → Task 3 Steps 2,4. ✓
- 2 i18n keys → Task 3 Step 1. ✓
- Range 1–65535, no ≥1024 block → Task 3 Step 3. ✓
- Dedup unchanged; one tunnel per instance:remote → no task alters `make_*_key` or the dedup blocks. ✓
- Tests: `ensure_local_port_available` + `bind_local_port(Some)` → Task 1 Steps 2,5. ✓
- Rebuild both cargo profiles + flutter build → Task 4. ✓

**2. Placeholder scan:** No TBD/TODO. Rust bodies marked "unchanged" are anchored to named, quoted current code (`let port = get_free_port()?;`, `let local = get_free_port()?;`, the `--local-host-port` line, `ssh_forward_args(...)`). Dart edits show full signatures and the exact call-arg additions. ✓

**3. Type consistency:** `local_port: Option<u16>` is identical across `start`, `bind_local_port`, `start_tunnel`, `start_native`, `start_gcloud`, `spawn_ssh_forward`, `start_ssh_forward`, and both `api.rs` fns. Dart `int? localPort` is consistent across `startConnection`/`startSshForward` (regen), `connect`/`_connect`, `connectSshForward`/`_connectSshForward`, and the dialog record. `TunnelError::LocalPortUnavailable { port }` matches the existing variant shape. ✓
