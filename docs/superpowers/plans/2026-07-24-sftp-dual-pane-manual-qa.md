# Manual QA — SFTP dual-pane (27H1)

- [ ] SFTP tab opens in DUAL view (local left, remote right); toggle to CLASSIC shows only the remote browser (today's behavior); toggle back.
- [ ] Existing remote buttons (upload file/folder, download, mkdir, delete, preview) still work in both views (direct, with the banner).
- [ ] Drag a local file onto the remote pane → it enqueues as an upload (⬆); progress bar advances; the completed file's `sha256sum` matches local vs remote.
- [ ] Drag a remote file onto the local pane → download (⬇) with progress; checksum matches.
- [ ] Drag a local FOLDER onto remote → subdirs created first (including deep/package trees like `com/example/app/`), one queue item per file; queue drains sequentially (item N+1 starts only after N).
- [ ] Drop onto a folder row transfers INTO that folder; drop onto the pane background uses the current directory. Dropping on a folder enqueues exactly one batch (no double-enqueue).
- [ ] Dragging within the same pane does nothing (cross-pane only).
- [ ] Cancel a mid-transfer item (✕) → it stops promptly, the partial destination file is deleted (verify it's gone), and the queue moves on.
- [ ] Cancel a queued (not-yet-started) item → it never starts.
- [ ] A failed item shows ↻ retry and re-runs on click.
- [ ] Overwrite conflict: drop files whose names already exist → one dialog (Overwrite all / Skip existing / Cancel); Skip omits colliding files; Overwrite replaces them; **Cancel creates no directories and enqueues nothing**.
- [ ] Close the SFTP tab mid-transfer → the active transfer is cancelled (no lingering gcloud/ssh work; partial cleaned up).
- [ ] Spanish: toggle, queue labels, and the conflict dialog are translated and not clipped.

## Deferred items carried out of execution (verify as noted, not bugs)

- **`sftpLocal`/`sftpRemote` i18n keys are unused** — the local/remote panes don't render a text header yet (local shows the path + a computer icon; remote shows its own title). Either wire pane-header labels or drop the keys.
- **Cancelled items render as "error" (orange)** — no dedicated `sftpQueueCancelled` label; a cancel reads the same as a failure apart from color.
- **Queue provider is not `.autoDispose`** — opening/closing many SFTP tabs leaves orphaned `TransferQueueNotifier` providers in the container for the session (the explicit on-close cancel still works; this is a memory-tidiness follow-up).
- **`_dropClaimed` guard is dead code** — Flutter delivers the drop to the innermost `DragTarget` only, so the guard never fires; harmless, remove or fix its comment.
- **Remote folder expansion does one `sftpListDir` per subdirectory level** — deep remote trees expand slower than local ones (no recursive-list bridge call); UX latency only.
- **`TransferQueueDrawer` row rendering (status/button mapping) has no widget test** — verified by review reading only; a drawer test would guard against silent regressions.
