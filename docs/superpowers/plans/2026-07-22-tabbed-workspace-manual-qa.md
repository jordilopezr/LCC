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

## Known deferrals carried out of the plan

These are intentional gaps recorded during subagent-driven execution; verify they behave as noted rather than filing them as bugs:

- **Sidebar row highlight** still tracks the selected-instance provider, not the active tab. Switching tabs without a sidebar click can leave the highlight on a different VM than the frontmost tab. (Task 7 — brief made the rewire conditional; left as-is.)
- **`InstanceDetailPane`** remains defined in `lib/main.dart` as dead code after being reduced to a thin wrapper; the root layout now renders `WorkspacePanel`. Safe to delete in a later cleanup.
- **ResourceTree context menu** still launches SSH via the external `launchSsh` (gnome-terminal) path; only the Overview tab's SSH action opens an embedded terminal. Reconciling the two entry points is future work.
- **Visual redesign** (Connect/Tools/Lifecycle grouping, single accent, theming the reconnect bar / close-dialog destructive color) is project A — deliberately out of scope here.
- **`workspace_panel_test.dart`** proves the `IndexedStack` keep-mounted invariant generically; a `WorkspacePanel`-level regression test (that would fail if the panel were switched to `TabBarView`) is worth adding later.
- **Tab reorder is not wired to the UI.** `WorkspaceNotifier.reorder()` exists and is unit-tested, but the tab strip is a plain horizontal `ListView`, not a `ReorderableListView`, so drag-to-reorder (spec §1 "reordenable") is not reachable yet. Deferred deliberately — wire it in a later pass.
- **Tunnels are keyed by VM `name` only, not `uniqueKey`.** The workspace ref-count keys by `projectId:zone:name`, but the Rust tunnel and `disconnect(name, 22)` key by bare `name`. Two VMs sharing a `name` across different projects/zones would collide onto one tunnel. Pre-existing limitation, but multi-VM sessions make it more reachable now — follow-up: key tunnels by `uniqueKey`.

## QA run 2026-07-23 — results

Verified against live `backupmig` (project-shared-backup), gcloud engine:

- [x] App boots with the new panel; GCP auth + instance listing OK.
- [x] Overview opens on VM click; second click focuses (no duplicate).
- [x] SFTP tab connects, authenticates, lists directory.
- [x] **Tunnel sharing / ref-count:** two sessions to one VM shared a single tunnel (same local port); "Stopping tunnel" fired exactly once, on the last close.
- [x] SSH terminal connects, `ls` renders, terminal reflows on window resize.
- [x] Close app with a live SSH session → confirm dialog appears; Cancel keeps the app running (Task 8).
- [x] RDP launches the external client (not a tab).

Not yet exercised: two different VMs alive simultaneously; reconnect after network drop; reopen-has-no-tabs; full Spanish visual pass.

### Findings

1. **Tab overflow is unrecoverable (defect).** The tab strip is a plain horizontal `ListView` (`workspace_panel.dart` `_TabStrip`). When more tabs are open than fit the panel width, the overflow tabs are off-screen with no scroll affordance (no arrows; desktop mouse-wheel doesn't scroll a horizontal list), so newly opened tabs are effectively lost. Needs proper tab navigation/organization — see the separate design for tab management (scroll/overflow, reorder, grouping by instance). Supersedes the earlier "reorder not wired" deferral.
2. **Force-kill orphans tunnels (pre-existing, out of scope).** `kill -9` / crash / OOM of the app leaves gcloud tunnel processes and their `ssh` children running (re-parented to systemd), because teardown only runs on a graceful close. The close-guard (Task 8) does not cover abnormal exit. Not introduced by this feature; worth a future robustness pass (e.g. a startup sweep of stale tunnels, or a supervisor).
