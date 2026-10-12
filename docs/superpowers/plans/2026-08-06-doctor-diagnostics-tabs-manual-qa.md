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
