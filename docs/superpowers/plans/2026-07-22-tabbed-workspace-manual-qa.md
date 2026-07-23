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
