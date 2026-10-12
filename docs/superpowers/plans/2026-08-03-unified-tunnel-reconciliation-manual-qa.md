# Manual QA — Unified IapTunnel Reconciliation (27H1-Preview)

**Date:** 2026-08-03
**Branch:** `27H1-Preview` @ `6045f0c` (after merging `feature/native-iap-tunnel` + `feature/tabbed-workspace`)
**Plan:** [2026-08-03-unified-tunnel-reconciliation.md](2026-08-03-unified-tunnel-reconciliation.md)

The automated gate is green and requires no display. The items below need a real
Linux desktop (a running app, a real GCP instance, an interactive session) and are
for the maintainer to run before publishing the branch.

## Automated gate (already passing — for reference)

- `cd native && cargo build && cargo build --release` — both succeed.
- `cd native && cargo test` — 156 passed / 0 failed / 2 ignored (+7 doc-tests), including the reaper reap-path test `reap_removes_idle_tunnel_with_no_active_connection`.
- `flutter analyze` — 0 errors (info/warnings only; all pre-existing or from already-reviewed feature code).
- `flutter gen-l10n` — no drift; `app_en.arb`/`app_es.arb` = 727 keys each, exact EN/ES parity.
- `flutter build linux --debug` — builds `lightweight_cloud_connector`.
- **Known pre-existing failure (NOT a reconciliation regression):** `flutter test` reports 2 failures in `es_overflow_test.dart` — `SettingsDialog` overflows ~151px in Spanish (desktop 1280×800 and small 1024×640). Proven identical at `2171232` (before this reconciliation); `settings_dialog.dart` is unchanged by both merges. Tracked separately as the known "visual QA Spanish overflow" item.

## Manual checklist

### 1. Idle reaper — default gcloud engine
- [ ] Launch the app (no env override → gcloud engine). Open a tunnel to a real instance (RDP/VNC/SSH) and immediately close the client, leaving NO active connection to the local port.
- [ ] Within ≤150 s the tunnel is reaped: the log shows `Reaping idle tunnel (no active connection for >120s)` and the local port stops listening.
- [ ] Open a tunnel and keep a live client session on it, idle (no traffic) for >2 min. It is NOT reaped (the ESTABLISHED loopback connection keeps `last_active` fresh).
- [ ] Reconnect to an existing tunnel (same instance+port) after it had gone quiet: it is reused and its idle timer resets (no reap race).

### 2. Idle reaper — native engine (opt-in)
- [ ] Relaunch with `LCC_TUNNEL_ENGINE=native`. Open a tunnel; confirm it works end-to-end (the native relay engine, not gcloud).
- [ ] Leave a native tunnel with no client connection → it is reaped within ≤150 s.
- [ ] **Critical (the spec's key risk):** after a native tunnel is reaped, confirm its local port is fully released — `ss -ltn` shows no lingering LISTEN on that port, and a new tunnel can bind it. (Verifies `NativeTunnel::stop()` tears down the listener/tasks cleanly.)
- [ ] A live native session left idle is NOT reaped.

### 3. Tabbed workspace
- [ ] The dashboard right panel is the tabbed workspace: open an Overview tab, an embedded SSH terminal tab, and an SFTP tab.
- [ ] Tabs survive sidebar selection changes (switching instances does not close open session tabs).
- [ ] Tab strip behaviors work: scroll/overflow arrows, all-tabs menu, pin, groups, drag-reorder.
- [ ] SFTP dual-pane: local+remote panes, transfer queue drawer, cross-pane drag-and-drop.

### 4. Session-expired banner + re-login (must be unchanged by the merges)
- [ ] With an expired GCP session (e.g. after the token lapses so projects fail to list), the `GcpSessionBanner` appears at the top of the dashboard — ABOVE the tabbed workspace.
- [ ] The banner's Re-login button runs `reauthenticate()` and, after sign-in, the app recovers (projects list again) without a restart.

### 5. Spanish (i18n)
- [ ] Switch language to Spanish (Settings). Workspace/tab, tunnel-engine, tunnel-error, and session-banner strings are translated (no raw keys, no English leakage in these surfaces).
- [ ] Trigger a tunnel error (e.g. an unreachable instance) and confirm the localized `tunnelError*` message shows in Spanish.

## Sign-off

- [ ] All manual items pass on a real desktop.
- [ ] Then the branch is clear for the maintainer to push/publish (pushing is done by the maintainer, not automated).
