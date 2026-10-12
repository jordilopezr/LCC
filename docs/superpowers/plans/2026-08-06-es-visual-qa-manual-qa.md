# Manual QA — ES visual (deferred surfaces)

The automated `es_overflow_test` now covers 10 dialogs + the Overview tab in
Spanish at 1280/1024/720 widths. These surfaces can't be pumped headlessly
(providers/bridge or inline dialogs) — check them by eye in Spanish, ideally
at a narrow window:

- [ ] Workspace tab strip: tab labels ("<vm> · Resumen", "· Diagnóstico", "· Reenvío SSH"/SFTP/SSH) don't overflow or clip the strip; the overflow arrows/all-tabs menu appear when needed.
- [ ] Custom Tunnel dialog: the mode selector, the local-port field, the port presets/chips, and the dedup warning snackbar all fit in Spanish.
- [ ] Full dashboard: the ResourceTree (left) + the WorkspacePanel (right) header/labels/buttons in Spanish at a narrow window.
- [ ] Windows Credentials / SSHFS Mount dialogs (skipped in the automated suite): fields/labels/buttons fit in Spanish.
- [ ] Desktop notifications in Spanish (from SP1) aren't truncated by the OS notification width.
