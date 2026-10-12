# Custom Tunnel Diagnostics (Sub-project A) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make the Custom Tunnel button surface the real gcloud error (instead of discarding it) and give clear feedback — the local port on success, an error dialog with a localhost hint on failure.

**Architecture:** Rust `start_gcloud` drains the gcloud child's stderr (currently piped but never read) and includes it, capped, in the error — so the real reason reaches Dart via the existing `TunnelFailure { code: "protocol_error", detail }` path (no bridge regen). The Dart Custom Tunnel handler captures `connect()`'s return: on success it shows `127.0.0.1:<localPort>` with a Copy action; on failure it reads the tunnel state's error and shows a dialog with `localizedError` + a localhost hint (when the error signals an unreachable backend) + the raw detail + a "Run Doctor" action.

**Tech Stack:** Rust (std::process), Flutter/Dart, flutter gen-l10n.

## Global Constraints

- **Branch `27H1-Preview`.** Do not push.
- **No bridge regen:** Task 1 changes only the *content* of an `anyhow::Error`, not `start_connection`'s signature. Do NOT run `flutter_rust_bridge_codegen`. No changes under `lib/src/bridge/**`.
- **After Rust changes:** both `cargo build` and `cargo build --release` must succeed (the app loads `native/target/release/libnative.so`).
- **l10n EN/ES parity:** every new `customTunnel*` key in BOTH `lib/l10n/app_en.arb` and `lib/l10n/app_es.arb`; placeholder metadata (`@key`) in the EN template only; run `flutter gen-l10n` after ARB edits.
- **Reuse the existing helper:** the failure message uses `localizedError(l10n, error)` from `lib/src/features/app_error.dart` (already exists). The tunnel-error routing and taxonomy are done — do not reimplement.
- **These are code commits → NO `Co-Authored-By` trailer.**
- Verify Dart with `flutter analyze` (0 errors) and `flutter test`.

## File Structure

- **Modify** `native/src/tunnel.rs` — add pure helper `truncate_stderr`; `start_gcloud` takes the child's stderr handle and includes drained stderr in both failure errors. Add a `truncate_stderr` unit test in the existing test module.
- **Modify** `lib/src/features/app_error.dart` — add top-level `bool isBackendUnreachable(dynamic e)`.
- **Modify** `test/app_error_test.dart` — test `isBackendUnreachable`.
- **Modify** `lib/src/features/workspace/overview_tab.dart` — rework the Custom Tunnel button handler (success SnackBar + Copy; failure dialog) + fix the two minors (`context.mounted`, dispose the dialog's controller).
- **Modify** `lib/l10n/app_en.arb`, `lib/l10n/app_es.arb` — new `customTunnel*` keys.

---

### Task 1: Rust — capture gcloud's real stderr

**Files:**
- Modify: `native/src/tunnel.rs` (imports; `start_gcloud`; add `truncate_stderr`; test in the existing test module)

**Interfaces:**
- Produces: `fn truncate_stderr(s: &str, max_lines: usize, max_chars: usize) -> String` (module-private, pure). `start_gcloud`'s failure `anyhow!` messages now embed the drained stderr.

- [ ] **Step 1: Write the failing test**

Add to `native/src/tunnel.rs`'s `#[cfg(test)] mod reaper_tests` (reuse the module; or add a new `#[cfg(test)] mod stderr_tests` above it):

```rust
#[cfg(test)]
mod stderr_tests {
    use super::truncate_stderr;

    #[test]
    fn short_stderr_is_unchanged() {
        assert_eq!(truncate_stderr("boom\n", 15, 2048), "boom");
    }

    #[test]
    fn keeps_only_last_lines() {
        let s = (1..=20).map(|i| format!("line{}", i)).collect::<Vec<_>>().join("\n");
        let out = truncate_stderr(&s, 3, 2048);
        assert_eq!(out, "line18\nline19\nline20");
    }

    #[test]
    fn truncates_overlong_tail_with_ellipsis() {
        let s = "x".repeat(5000);
        let out = truncate_stderr(&s, 15, 100);
        assert!(out.chars().count() <= 101); // 100 + leading ellipsis
        assert!(out.starts_with('…'));
    }

    #[test]
    fn empty_stays_empty() {
        assert_eq!(truncate_stderr("   ", 15, 2048), "");
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd native && cargo test stderr_tests`
Expected: FAIL — `truncate_stderr` not defined.

- [ ] **Step 3: Add imports + the `truncate_stderr` helper**

At the top of `native/src/tunnel.rs`, extend the process import and add the io trait:
```rust
use std::process::{Command, Child, ChildStderr, Stdio};
use std::io::Read;
```
Add the helper (place it near `start_gcloud`, module scope):
```rust
/// Keep the last `max_lines` lines of `s`, then cap to `max_chars` characters
/// (keeping the tail, where gcloud's actual error usually is). Used to embed a
/// bounded slice of gcloud's stderr in tunnel errors.
fn truncate_stderr(s: &str, max_lines: usize, max_chars: usize) -> String {
    let trimmed = s.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    let lines: Vec<&str> = trimmed.lines().collect();
    let start = lines.len().saturating_sub(max_lines);
    let tail = lines[start..].join("\n");
    if tail.chars().count() > max_chars {
        let kept: String = {
            let mut chars: Vec<char> = tail.chars().collect();
            chars = chars.split_off(chars.len() - max_chars);
            chars.into_iter().collect()
        };
        format!("…{}", kept)
    } else {
        tail
    }
}

/// Drain a (dead) child's stderr into a bounded string. Only call after the
/// process has exited or been killed, so `read_to_string` returns promptly.
fn drain_stderr(handle: Option<ChildStderr>) -> String {
    match handle {
        Some(mut h) => {
            let mut buf = String::new();
            let _ = h.read_to_string(&mut buf);
            truncate_stderr(&buf, 15, 2048)
        }
        None => String::new(),
    }
}
```

- [ ] **Step 4: Run the helper test to verify it passes**

Run: `cd native && cargo test stderr_tests`
Expected: PASS (4 tests).

- [ ] **Step 5: Wire the stderr capture into `start_gcloud`**

In `start_gcloud`, take the stderr handle before moving the child into the tunnel, and include drained stderr in both failure paths. The function becomes:

```rust
fn start_gcloud(project: &str, zone: &str, instance: &str, remote_port: u16) -> Result<IapTunnel> {
    let port = get_free_port()?;
    let mut child = Command::new(crate::gcloud_bin::gcloud_path()?)
        .args([
            "compute",
            "start-iap-tunnel",
            instance,
            &remote_port.to_string(),
            &format!("--local-host-port=localhost:{}", port),
            "--zone", zone,
            "--project", project,
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| anyhow!("Failed to spawn gcloud tunnel: {}", e))?;

    let mut stderr_handle = child.stderr.take();

    let mut tunnel = IapTunnel { local_port: port, backend: Backend::Gcloud(child), last_active: std::time::Instant::now() };
    std::thread::sleep(Duration::from_millis(1000));
    if !tunnel.is_process_alive() {
        // Process died: it is dead, so its stderr can be drained safely.
        return Err(anyhow!("gcloud tunnel failed: {}", drain_stderr(stderr_handle.take())));
    }
    for _ in 0..20 {
        if tunnel.is_port_listening() {
            // Reattach the stderr pipe to the still-running child. Otherwise the
            // taken handle would drop here and close the read end while gcloud
            // keeps running for the tunnel's lifetime — a closed pipe risks
            // SIGPIPE killing an otherwise-healthy tunnel.
            if let Backend::Gcloud(ref mut c) = tunnel.backend {
                c.stderr = stderr_handle.take();
            }
            return Ok(tunnel);
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    let _ = tunnel.stop(); // kill the process before draining its stderr
    Err(anyhow!("gcloud tunnel timed out (port {} never listened): {}", port, drain_stderr(stderr_handle.take())))
}
```

- [ ] **Step 6: Verify build + tests (both profiles)**

Run:
```bash
cd native && cargo build && cargo build --release && cargo test 2>&1 | tail -15 && cd ..
```
Expected: both builds succeed; all tests pass including `stderr_tests` (pre-existing env-dependent failures, if any, unchanged).

- [ ] **Step 7: Commit**

```bash
git add native/src/tunnel.rs
git commit -m "feat(tunnel): surface gcloud's real stderr on custom-tunnel failure"
```

---

### Task 2: Dart — success/failure UX + localhost hint + l10n + minors

**Files:**
- Modify: `lib/src/features/app_error.dart` (add `isBackendUnreachable`)
- Modify: `test/app_error_test.dart` (test it)
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_es.arb` (new keys)
- Modify: `lib/src/features/workspace/overview_tab.dart` (handler + error dialog + minors)

**Interfaces:**
- Consumes: `localizedError(AppLocalizations, dynamic, {bool standalone})` and (new) `isBackendUnreachable(dynamic)` from `app_error.dart`; `makeTunnelKey(String, int)`, `activeConnectionsProvider` from `gcloud_provider.dart`; `showConnectivityDoctor(BuildContext, {required String projectId, required String zone, required String instanceName})` from `connectivity_doctor.dart`.

- [ ] **Step 1: Write the failing test for `isBackendUnreachable`**

Append to `test/app_error_test.dart` a new group:
```dart
  group('isBackendUnreachable', () {
    test('true for backend-refused signals', () {
      expect(isBackendUnreachable('gcloud tunnel failed: ... 4003. failed to connect to backend'), isTrue);
      expect(isBackendUnreachable('Connection refused'), isTrue);
    });
    test('false otherwise', () {
      expect(isBackendUnreachable('PERMISSION_DENIED'), isFalse);
      expect(isBackendUnreachable('some other error'), isFalse);
      // A local port containing 4003 in a plain timeout must NOT match.
      expect(
          isBackendUnreachable(
              'gcloud tunnel timed out (port 34003 never listened): '),
          isFalse);
    });
  });
```
(The test file already imports `app_error.dart`.)

- [ ] **Step 2: Run it to verify it fails**

Run: `flutter test test/app_error_test.dart`
Expected: FAIL — `isBackendUnreachable` not defined.

- [ ] **Step 3: Implement `isBackendUnreachable` in `app_error.dart`**

Append to `lib/src/features/app_error.dart`:
```dart
/// Whether an error looks like "the IAP tunnel reached the VM but the target
/// port refused the connection" — the classic symptom of a service bound only
/// to 127.0.0.1 (unreachable via IAP). Drives the Custom Tunnel localhost hint.
bool isBackendUnreachable(dynamic e) {
  final s = e.toString().toLowerCase();
  // `\b4003\b`, not a bare substring: the timeout error embeds the local port
  // ("port 34003 never listened"), and a port containing 4003 must not be
  // mistaken for the IAP backend-refused code.
  return RegExp(r'\b4003\b').hasMatch(s) ||
      s.contains('failed to connect to backend') ||
      s.contains('connection refused');
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `flutter test test/app_error_test.dart`
Expected: PASS.

- [ ] **Step 5: Add the `customTunnel*` l10n keys**

`lib/l10n/app_en.arb` (add near the other `dashboard*`/`app*` keys):
```json
  "customTunnelReady": "Tunnel ready at {address}",
  "@customTunnelReady": {
    "placeholders": { "address": {"type": "String"} }
  },
  "customTunnelAddressCopied": "Address copied",
  "customTunnelFailedTitle": "Couldn't create the tunnel",
  "customTunnelLocalhostHint": "The service may be listening only on 127.0.0.1; IAP can't reach localhost-only services. Bind it to 0.0.0.0 or use SSH forwarding.",
  "customTunnelRunDoctor": "Run Doctor",
```
`lib/l10n/app_es.arb` (values only, no `@`):
```json
  "customTunnelReady": "Túnel listo en {address}",
  "customTunnelAddressCopied": "Dirección copiada",
  "customTunnelFailedTitle": "No se pudo crear el túnel",
  "customTunnelLocalhostHint": "El servicio puede estar escuchando solo en 127.0.0.1; IAP no alcanza servicios en localhost. Enlázalo a 0.0.0.0 o usa reenvío SSH.",
  "customTunnelRunDoctor": "Ejecutar Doctor",
```
Then run `flutter gen-l10n` (getters `customTunnelReady(String address)`, `customTunnelAddressCopied`, etc. appear).

- [ ] **Step 6: Ensure imports in `overview_tab.dart`**

At the top of `lib/src/features/workspace/overview_tab.dart`, ensure these imports exist (add any missing):
```dart
import 'package:flutter/services.dart'; // Clipboard
import '../app_error.dart';             // localizedError, isBackendUnreachable
import '../connectivity_doctor.dart';   // showConnectivityDoctor
```
`makeTunnelKey`/`activeConnectionsProvider` come from `gcloud_provider.dart` (already imported for the existing `connect` call).

- [ ] **Step 7: Rework the Custom Tunnel button handler**

Replace the button's `onPressed` body (currently at `overview_tab.dart:474-497`, the `_ActionButton` labelled `l10n.dashboardCustomTunnelButton`) with:
```dart
onPressed: (!isRunning || isConnecting)
    ? null
    : () async {
        final selectedPort = await _showCustomTunnelDialog(context);
        if (selectedPort == null || !context.mounted) return;
        final messenger = ScaffoldMessenger.of(context);
        final localPort = await ref
            .read(activeConnectionsProvider.notifier)
            .connect(selectedProject, target.zone, target.name,
                remotePort: selectedPort);
        if (!context.mounted) return;
        if (localPort != null) {
          final address = '127.0.0.1:$localPort';
          messenger.showSnackBar(SnackBar(
            content: Text(l10n.customTunnelReady(address)),
            action: SnackBarAction(
              label: l10n.commonCopy,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: address));
                messenger.showSnackBar(SnackBar(
                    content: Text(l10n.customTunnelAddressCopied)));
              },
            ),
          ));
        } else {
          final error = ref.read(activeConnectionsProvider)[
                  makeTunnelKey(target.name, selectedPort)]
              ?.error ??
              '';
          await _showCustomTunnelError(
            context,
            error: error,
            projectId: selectedProject,
            zone: target.zone,
            instanceName: target.name,
          );
        }
      },
```

- [ ] **Step 8: Add the failure dialog helper**

Add this method to the same class as `_showCustomTunnelDialog` (the widget/State that builds the action buttons) in `overview_tab.dart`:
```dart
Future<void> _showCustomTunnelError(
  BuildContext context, {
  required String error,
  required String projectId,
  required String zone,
  required String instanceName,
}) async {
  final l10n = AppLocalizations.of(context);
  await showDialog<void>(
    context: context,
    // Name the builder context `dialogContext` so it does not shadow the outer
    // `context`. The Doctor button pops the dialog (dialogContext) and then
    // opens the doctor on the still-mounted outer `context`.
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.customTunnelFailedTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(localizedError(l10n, error)),
            if (isBackendUnreachable(error)) ...[
              const SizedBox(height: 12),
              Text(l10n.customTunnelLocalhostHint,
                  style: TextStyle(color: Colors.orange.shade900)),
            ],
            if (error.isNotEmpty) ...[
              const SizedBox(height: 12),
              SelectableText(error,
                  style:
                      const TextStyle(fontSize: 11, fontFamily: 'monospace')),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.pop(dialogContext);
            showConnectivityDoctor(context,
                projectId: projectId, zone: zone, instanceName: instanceName);
          },
          child: Text(l10n.customTunnelRunDoctor),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(l10n.commonClose),
        ),
      ],
    ),
  );
}
```

- [ ] **Step 9: Fix the two minors in `_showCustomTunnelDialog`**

In `_showCustomTunnelDialog` (`overview_tab.dart:1006`): the `customPortController` is never disposed. Wrap the return so it is disposed after the dialog closes:
```dart
final customPortController = TextEditingController();
try {
  return await showDialog<int>( ... );  // the existing dialog body, unchanged
} finally {
  customPortController.dispose();
}
```
(The existing `if (!context.mounted) return null;` guard before `showDialog` stays.)

- [ ] **Step 10: Full gate**

Run:
```bash
flutter gen-l10n
python3 -c "import json; en=json.load(open('lib/l10n/app_en.arb')); es=json.load(open('lib/l10n/app_es.arb')); ek={k for k in en if not k.startswith('@')}; sk={k for k in es if not k.startswith('@')}; print('missing ES:', ek-sk, '| missing EN:', sk-ek)"
flutter analyze lib/src/features/workspace/overview_tab.dart lib/src/features/app_error.dart 2>&1 | tail -5
flutter test test/app_error_test.dart 2>&1 | tail -3
flutter build linux --debug 2>&1 | tail -2
```
Expected: no missing keys either direction; analyze 0 errors; app_error tests pass; app builds.

- [ ] **Step 11: Commit**

```bash
git add lib/src/features/app_error.dart test/app_error_test.dart lib/l10n/ lib/src/features/workspace/overview_tab.dart
git commit -m "feat(tunnel): custom-tunnel success/failure UX with localhost hint"
```

---

## Manual QA (after implementation)

- Custom Tunnel to a port with a service bound to `0.0.0.0` → SnackBar "Tunnel ready at 127.0.0.1:<port>"; Copy action copies it (paste to verify).
- Custom Tunnel to a `127.0.0.1`-only port (the trigger case) → error dialog shows the real gcloud error (a `4003`/"failed to connect to backend" line), the **localhost hint**, and the raw detail; "Run Doctor" opens the Connectivity Doctor.
- Switch to Spanish → all four strings (ready / copied / failed title / hint) are Spanish.
