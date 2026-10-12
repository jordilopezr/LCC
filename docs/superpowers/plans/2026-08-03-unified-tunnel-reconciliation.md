# Unified IapTunnel Reconciliation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax. This is an INTEGRATION plan (merge + conflict resolution), not greenfield TDD — tasks are "merge → resolve per recipe → verify".

**Goal:** On `27H1-Preview`, reconcile `native/src/tunnel.rs` into a unified `IapTunnel` (native-engine `Backend` enum + loopback's idle reaper + `gcloud_path` hardening), then merge `feature/native-iap-tunnel` and `feature/tabbed-workspace` cleanly.

**Architecture:** Two orthogonal concerns combine: the native engine's `Backend{Native,Gcloud}` abstraction and loopback's connection-based idle reaper. The reaper is backend-agnostic (detects ESTABLISHED loopback connections on `local_port` via `/proc/net/tcp`; reaps via `tunnel.stop()`).

**Tech Stack:** Rust (flutter_rust_bridge 2.11.1), Flutter (gen-l10n EN/ES), git merge.

## Global Constraints

- **Work happens on `27H1-Preview`.** Do NOT switch to another branch. Do NOT push.
- **frb 2.11.1.** After any `api.rs`/merge that touches the bridge, regenerate: `/home/jlopezre/.cargo/bin/flutter_rust_bridge_codegen generate --rust-input "crate::api" --rust-root native --dart-output lib/src/bridge/api.dart`, then `git diff --stat lib/src/bridge/ native/src/frb_generated.rs` and confirm additive.
- **After Rust changes, rebuild BOTH** `cargo build` **and** `cargo build --release` in `native/` — both must succeed.
- **Reaper logic and timeouts are unchanged** from loopback: `IDLE_TIMEOUT = 120s`, `POLL_INTERVAL = 30s`, `port_has_active_connection`, `should_reap`. Only the reap action becomes `tunnel.stop()`.
- **The `Gcloud` backend spawns via `crate::gcloud_bin::gcloud_path()?`** (never `Command::new("gcloud")`).
- **Native engine stays opt-in, default gcloud** — do NOT change `selected_engine()` / the default. `LCC_TUNNEL_ENGINE=native` is the opt-in.
- **l10n EN/ES parity:** when combining `.arb` files, keep BOTH sides' keys, no duplicates; then `flutter gen-l10n`.
- **Merge/resolution commits contain code → NO `Co-Authored-By` trailer.**

## File Structure

- **Resolve** `native/src/tunnel.rs` → unified design (Task 1).
- **Add** `native/src/iap_tunnel.rs` (native engine, from `feature/native-iap-tunnel`) + `pub mod iap_tunnel;` in `native/src/lib.rs` (Task 1, via the merge).
- **Combine** `lib/l10n/app_en.arb`, `lib/l10n/app_es.arb` + regen `lib/l10n/gen/` (Tasks 1 and 2).
- **Regenerate** `lib/src/bridge/api.dart/…` + `native/src/frb_generated.rs` (Tasks 1 and 2).
- **Resolve** `lib/main.dart` (banner atop the tabbed dashboard) (Task 2).

---

### Task 1: Merge `feature/native-iap-tunnel` + unified `tunnel.rs`

**Files:** `native/src/tunnel.rs` (resolve), `native/src/iap_tunnel.rs` (added by merge), `native/src/lib.rs` (added by merge), `lib/l10n/*` (combine + regen), bridge (regen).

- [ ] **Step 1: Start the merge**

Run: `git merge --no-edit feature/native-iap-tunnel`
Expected: conflicts in `lib/l10n/app_en.arb`, `lib/l10n/app_es.arb`, `lib/l10n/gen/*` (5 files), and `native/src/tunnel.rs`. `native/src/iap_tunnel.rs` and `native/src/lib.rs` (`pub mod iap_tunnel;`) come in without conflict; `native/src/api.rs`, `gcloud_provider.dart`, `settings_dialog.dart`, `tunnel_manager_dialog.dart` auto-merge (the re-login banner is preserved).

- [ ] **Step 2: Resolve `native/src/tunnel.rs` to the unified design (the recipe)**

Take the native-engine version as the base, then graft loopback's reaper onto it:

1. `git checkout --theirs native/src/tunnel.rs` (native's version: `enum Backend{Native,Gcloud}`, `IapTunnel{backend,local_port}`, `stop()/is_process_alive()/is_port_listening()`, `selected_engine()`, `start_tunnel`/`start_native`/`start_gcloud`).
2. Edit `IapTunnel` to add the reaper field:
   ```rust
   pub struct IapTunnel {
       backend: Backend,
       pub local_port: u16,
       pub last_active: std::time::Instant,
   }
   ```
3. In BOTH `start_native` and `start_gcloud`, set `last_active` on the constructed `IapTunnel`:
   ```rust
   Ok(IapTunnel { local_port: native.local_port, backend: Backend::Native(native), last_active: std::time::Instant::now() })
   // and for gcloud:
   let mut tunnel = IapTunnel { local_port: port, backend: Backend::Gcloud(child), last_active: std::time::Instant::now() };
   ```
4. In `start_gcloud`, change the spawn from `Command::new("gcloud")` to `Command::new(crate::gcloud_bin::gcloud_path()?)`.
5. In `start_tunnel`, after each `tunnels.insert(...)` (both the native and gcloud engine paths), drop the lock and start the reaper:
   ```rust
   let mut tunnels = TUNNELS.lock().map_err(|_| anyhow!("Tunnel lock poisoned"))?;
   tunnels.insert(make_tunnel_key(instance, remote_port), tunnel);
   drop(tunnels);
   start_reaper_once();
   ```
6. Append loopback's reaper block verbatim. Recover it from the pre-merge Preview version (during the in-progress merge, `HEAD` is still the Preview commit): `git show HEAD:native/src/tunnel.rs` — copy the items: `IDLE_TIMEOUT`, `POLL_INTERVAL`, `read_proc_net_tcp()`, `port_has_active_connection()`, `should_reap()`, `reap_idle_tunnels_once()`, `start_reaper_once()`, `touch_tunnel_by_local_port()`, and the `#[cfg(test)] mod tests` reaper tests. In `reap_idle_tunnels_once`, the reap action is `tunnel.stop()` (the unified `IapTunnel::stop()` already dispatches to both backends). Ensure needed imports (`std::time::{Duration, Instant}`) are present. (Equivalent source: `git show security/loopback-listener:native/src/tunnel.rs`.)

- [ ] **Step 3: Combine the l10n `.arb` conflicts + regen**

For `lib/l10n/app_en.arb` and `lib/l10n/app_es.arb`: resolve each conflict by KEEPING BOTH sides' keys (the native branch adds tunnel-engine keys; ours has the session keys). No key may appear twice. Then for the generated files, take either side (they will be regenerated): `git checkout --theirs lib/l10n/gen/` then run `flutter gen-l10n`. Confirm the 5 session keys AND the native tunnel-engine keys are all present in both arb files.

- [ ] **Step 4: Complete the merge commit**

```bash
git add native/src/tunnel.rs native/src/iap_tunnel.rs native/src/lib.rs lib/l10n/
git commit --no-edit
```

- [ ] **Step 5: Regenerate the bridge (api.rs now has reauthenticate + touch_tunnel + native engine bindings)**

**Do NOT skip this because the merge auto-resolved the generated files.** A cleanly-merged bridge whose content-hash no longer matches the compiled `libnative.so` compiles fine but throws at `RustLib.init` (no window) — the exact runtime bug that broke the CI packages earlier this cycle. Regenerating produces a self-consistent bridge by construction. Run the regen command (Global Constraints), then `git diff --stat lib/src/bridge/ native/src/frb_generated.rs`. Commit:
```bash
git add lib/src/bridge/ native/src/frb_generated.rs
git commit -m "chore(bridge): regenerate after native-iap-tunnel merge"
```
(Skip only this commit if the regen produced a genuinely empty diff.)

- [ ] **Step 6: Verify it compiles + tests**

Run:
```bash
cd native && cargo build && cargo build --release && cargo test 2>&1 | tail -20 && cd ..
```
Expected: both builds succeed; the reaper unit tests (`port_has_active_connection`, `should_reap`) pass. (Pre-existing env-dependent test failures like `test_get_access_token`/`test_list_projects` are acceptable — confirm they fail identically on the pre-merge commit.)

- [ ] **Step 7: Add a reap-path integration test (real coverage of `reap_idle_tunnels_once`)**

Do NOT add another `should_reap` assertion — `reaper_tests::should_reap_respects_timeout` already covers that predicate; a second one duplicates it and asserts nothing new. Instead cover the reap PATH, which currently has zero direct test: that `reap_idle_tunnels_once()` removes an idle tunnel with no active loopback connection. A real `Backend::Native` needs a running relay engine, so use a `Backend::Gcloud` wrapping a dummy long-lived child as the backend stand-in (native port-release is covered by Task 3 manual QA). Add to `mod reaper_tests` in `native/src/tunnel.rs` (Linux-only, `sleep` from coreutils):

```rust
#[test]
fn reap_removes_idle_tunnel_with_no_active_connection() {
    use std::process::Command;
    // A dummy long-lived child stands in for a backend process. A real
    // Backend::Native needs a running relay engine, so native port-release
    // is verified by manual QA (Task 3), not here.
    let child = Command::new("sleep").arg("60").spawn().expect("spawn sleep");
    let key = "reaper-integration-test-instance:1".to_string();
    // Port 1: never bound here, so read_proc_net_tcp will not see it active.
    let tunnel = IapTunnel {
        backend: Backend::Gcloud(child),
        local_port: 1,
        last_active: Instant::now() - Duration::from_secs(3600),
    };
    TUNNELS.lock().unwrap().insert(key.clone(), tunnel);
    reap_idle_tunnels_once();
    assert!(
        !TUNNELS.lock().unwrap().contains_key(&key),
        "idle tunnel with no active connection should have been reaped"
    );
}
```

If the field/enum names differ from the unified design (Step 2), adjust this test to match — the intent (insert idle tunnel → `reap_idle_tunnels_once()` → assert removed) is fixed. Run `cd native && cargo test reap_removes_idle_tunnel -- --exact` and confirm it passes.

- [ ] **Step 8: Dart gate + commit any l10n regen**

Run:
```bash
flutter gen-l10n && flutter analyze lib/src/features/gcloud_provider.dart lib/main.dart 2>&1 | tail -4 && flutter test test/gcp_error_classifier_test.dart test/gcp_session_banner_test.dart 2>&1 | tail -3
```
Expected: gen-l10n clean (no drift), analyze 0 errors, tests pass. Commit the test addition:
```bash
git add native/src/tunnel.rs
git commit -m "test(tunnel): reaper decision is backend-agnostic (unified IapTunnel)"
```

---

### Task 2: Merge `feature/tabbed-workspace`

**Files:** `native/src/tunnel.rs` (now matches → clean), `lib/main.dart` (resolve: banner in tabbed dashboard), `lib/l10n/*` (combine + regen), bridge (regen).

- [ ] **Step 1: Start the merge**

Run: `git merge --no-edit feature/tabbed-workspace`
Expected: `native/src/tunnel.rs` NO LONGER conflicts (it now matches the unified design). Conflicts remain in `lib/main.dart`, `lib/l10n/app_en.arb`, `lib/l10n/app_es.arb`, `lib/l10n/gen/*`, and the generated bridge (`lib/src/bridge/api.dart/frb_generated.dart`, `native/src/frb_generated.rs`). If `tunnel.rs` DOES still conflict, stop and report — the Task 1 unified design didn't match; re-examine.

- [ ] **Step 2: Resolve `lib/main.dart` — mount the banner in the tabbed dashboard**

`feature/tabbed-workspace` replaced the dashboard body with its tabbed workspace; `main` (ours) wrapped the body as `Column(children:[const GcpSessionBanner(), Expanded(child: statusAsync.when(...))])`. Resolve by taking the tabbed-workspace dashboard structure and mounting `const GcpSessionBanner()` at the top of its body, same pattern: the top-level body becomes `Column(children:[const GcpSessionBanner(), Expanded(child: <tabbed-workspace body>)])`. Keep the `import 'src/features/gcp_session_banner.dart';` import. Do NOT drop the tabbed-workspace body or the banner. Read both conflict sides fully before resolving.

- [ ] **Step 3: Combine l10n + resolve generated files**

For `app_en.arb`/`app_es.arb`: keep BOTH key sets (tabbed-workspace adds workspace/terminal/SFTP-dual-pane/tab-strip keys; ours has session keys). For `lib/l10n/gen/*` and the two `frb_generated.*`: take either side (`git checkout --theirs …`) — they will be regenerated.

- [ ] **Step 4: Complete the merge commit**

```bash
git add lib/main.dart lib/l10n/ lib/src/bridge/ native/src/frb_generated.rs
git commit --no-edit
```

- [ ] **Step 5: Regenerate bridge + l10n, then verify**

```bash
/home/jlopezre/.cargo/bin/flutter_rust_bridge_codegen generate --rust-input "crate::api" --rust-root native --dart-output lib/src/bridge/api.dart
flutter gen-l10n
cd native && cargo build && cargo build --release && cd ..
flutter analyze lib/main.dart 2>&1 | tail -4
flutter test 2>&1 | tail -5
```
Expected: bridge regen additive; gen-l10n clean; both cargo builds succeed; analyze no NEW errors; tests pass. Commit the regenerated bridge/l10n if changed:
```bash
git add lib/src/bridge/ native/src/frb_generated.rs lib/l10n/
git commit -m "chore(bridge,l10n): regenerate after tabbed-workspace merge"
```

- [ ] **Step 6: Build the app**

Run: `flutter build linux --debug`
Expected: builds successfully (the whole integrated tree compiles).

---

### Task 3: Full gate + manual QA checklist

**Files:** none (verification only).

- [ ] **Step 1: Automated gate**

```bash
cd native && cargo build && cargo build --release && cargo test 2>&1 | tail -20 && cd ..
flutter gen-l10n
flutter analyze lib/main.dart lib/src/features/gcp_session_banner.dart lib/src/features/gcloud_provider.dart 2>&1 | tail -4
flutter test 2>&1 | tail -5
flutter build linux --debug 2>&1 | tail -3
```
Expected: all green (0 analyze errors; reaper tests pass; app builds).

- [ ] **Step 2: EN/ES parity spot-check**

Confirm the 5 session keys (`sessionExpired*`) plus a sample of the native-engine and tabbed-workspace keys exist in BOTH `app_en.arb` and `app_es.arb`.

- [ ] **Step 3: Manual QA (maintainer, real desktop)**

1. Launch the app (default gcloud engine). Open a tunnel (RDP/VNC/SSH); leave it with NO client connection → it is reaped within ≤150s (log `idle reap`); a live session left idle >2 min is NOT reaped.
2. Re-run with `LCC_TUNNEL_ENGINE=native`: a native tunnel left idle is reaped; a live native session is not. **Confirm the reaped native tunnel releases its local port** (no lingering LISTEN — the key risk).
3. The **tabbed workspace** works: tabs survive sidebar changes, embedded SSH terminal, SFTP panel, tab strip.
4. The **session-expired banner** still appears on an expired session and re-login works (unchanged by this merge).
5. Language = Spanish: workspace/tunnel-engine/session strings are translated.
