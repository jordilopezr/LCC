# SFTP Parallel Ranged Transfers Implementation Plan (27H1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Speed SFTP uploads and downloads from ~0.7 MB/s to ≈3–5 MB/s by transferring file ranges over K parallel SSH connections, with aggregate progress for folder uploads.

**Architecture:** A pure `split_ranges` partitioner plus two symmetric Rust functions (`sftp_upload_file_parallel`, `sftp_download_file_parallel`) that open K worker SSH sessions (+1 coordinator session) and read/write contiguous ranges at offsets, reporting bytes through a shared `AtomicU64` that a coordinator loop emits as `SftpProgress`. Dart uploads folders through a 3-worker pool with a global bytes-based progress bar.

**Tech Stack:** Rust (ssh2 0.9 — `File` implements `Seek`, `Session` is `Send`; std threads/atomics/mpsc), flutter_rust_bridge 2.11.1 StreamSink, Flutter/Dart with gen-l10n.

**Spec:** `docs/superpowers/specs/2026-07-22-sftp-transfer-speed-design.md`

## Global Constraints

- Branch: `27H1`. `cd native && cargo test` and `flutter analyze` (0 errors) must pass at every commit.
- Partitioning rules (verbatim from spec): K=4 default; files **< 8 MB** use one connection (no partitioning); the non-divisible remainder goes to the last range; size 0 → one empty range.
- Folder pool: 3 concurrent files, each with `concurrency: 2`; single-file transfers use `concurrency: 4`.
- The existing single-connection functions (`sftp_upload_file`, `sftp_upload_file_streaming`, `sftp_download_file`) must NOT change behavior; parallel failure at session-setup falls back to the single-connection path (log the reason at warn).
- On any transfer error: set the cancel flag, delete the partial destination file, return the first error.
- Progress events throttle to ~10/s (existing pattern); `SftpProgress { transferred, total }` is the existing bridge type — reuse it.
- After ANY bridge regeneration: rebuild BOTH Rust profiles (`cargo build` and `cargo build --release`) — the app loads the release lib even under `flutter build linux --debug`.
- i18n: every new key goes to BOTH `lib/l10n/app_en.arb` and `lib/l10n/app_es.arb` (parity enforced); Spanish uses neutral register; run `flutter gen-l10n` after .arb edits and commit `lib/l10n/gen/`.
- Reference for auth/session conventions: `native/src/sftp.rs::create_ssh_session` (agent → `~/.ssh/id_rsa`); reuse it, do not duplicate auth logic.

---

### Task 1: Range partitioner (`split_ranges`)

**Files:**
- Modify: `native/src/sftp.rs` (add near the top, after `copy_with_limit`)

**Interfaces:**
- Produces: `pub(crate) fn split_ranges(size: u64, k: usize) -> Vec<(u64, u64)>` — list of `(offset, length)` covering `[0, size)` contiguously; `pub(crate) const PARALLEL_MIN_SIZE: u64 = 8 * 1024 * 1024;`

- [ ] **Step 1: Write the failing tests**

Append inside the existing `#[cfg(test)] mod tests` block in `native/src/sftp.rs`:

```rust
    #[test]
    fn split_ranges_covers_file_contiguously() {
        // 100 bytes over 4 ranges: remainder goes to the LAST range.
        let r = split_ranges(100, 4);
        assert_eq!(r, vec![(0, 25), (25, 25), (50, 25), (75, 25)]);
        let r = split_ranges(103, 4);
        assert_eq!(r, vec![(0, 25), (25, 25), (50, 25), (75, 28)]);
    }

    #[test]
    fn split_ranges_small_file_is_single_range() {
        // Below PARALLEL_MIN_SIZE the caller uses one connection; split_ranges
        // itself must still behave: k=1 yields the whole file.
        assert_eq!(split_ranges(1234, 1), vec![(0, 1234)]);
    }

    #[test]
    fn split_ranges_zero_size_is_one_empty_range() {
        assert_eq!(split_ranges(0, 4), vec![(0, 0)]);
    }

    #[test]
    fn split_ranges_more_workers_than_bytes() {
        // 3 bytes, 4 workers: never emit zero-length ranges except size==0.
        let r = split_ranges(3, 4);
        assert_eq!(r, vec![(0, 1), (1, 1), (2, 1)]);
    }

    #[test]
    fn split_ranges_reassembles_exactly() {
        for (size, k) in [(8 * 1024 * 1024u64, 4usize), (1, 4), (999_999, 3)] {
            let r = split_ranges(size, k);
            let mut expected_offset = 0u64;
            for (off, len) in &r {
                assert_eq!(*off, expected_offset);
                expected_offset += len;
            }
            assert_eq!(expected_offset, size);
        }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd native && cargo test sftp::tests::split_ranges`
Expected: FAIL — `split_ranges` not found.

- [ ] **Step 3: Implement**

Add to `native/src/sftp.rs` (top level, after `copy_with_limit`):

```rust
/// Files below this size are not worth parallelizing (handshake dominates).
pub(crate) const PARALLEL_MIN_SIZE: u64 = 8 * 1024 * 1024;

/// Partition `[0, size)` into up to `k` contiguous `(offset, length)` ranges.
/// The non-divisible remainder goes to the last range. Never returns
/// zero-length ranges except for `size == 0` (one `(0, 0)` range).
pub(crate) fn split_ranges(size: u64, k: usize) -> Vec<(u64, u64)> {
    if size == 0 {
        return vec![(0, 0)];
    }
    let k = (k.max(1) as u64).min(size);
    let base = size / k;
    let mut ranges = Vec::with_capacity(k as usize);
    let mut offset = 0u64;
    for i in 0..k {
        let len = if i == k - 1 { size - offset } else { base };
        ranges.push((offset, len));
        offset += len;
    }
    ranges
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd native && cargo test sftp::tests::split_ranges`
Expected: PASS — 5 tests.

- [ ] **Step 5: Commit**

```bash
git add native/src/sftp.rs
git commit -m "feat(sftp): range partitioner for parallel transfers"
```

---

### Task 2: Parallel upload in Rust

**Files:**
- Modify: `native/src/sftp.rs`

**Interfaces:**
- Consumes: `split_ranges`, `PARALLEL_MIN_SIZE` (Task 1); existing `create_ssh_session`, `validate_local_path`, `validate_and_normalize_path`, `SftpProgress`, `sftp_upload_file_streaming` (fallback; note `StreamSink` derives `Clone`).
- Produces: `pub fn sftp_upload_file_parallel(host: String, port: u16, username: String, local_path: String, remote_path: String, concurrency: Option<u8>, sink: crate::frb_generated::StreamSink<SftpProgress>) -> Result<()>`

- [ ] **Step 1: Implement**

Add to `native/src/sftp.rs` (after `sftp_upload_file_streaming`). Imports to add at the top of the file: `use ssh2::{OpenFlags, OpenType, FileStat};` and `use std::io::Seek; use std::io::SeekFrom;` and `use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering}; use std::sync::Arc;`.

```rust
/// Upload a file over `concurrency` parallel SSH connections, each writing a
/// contiguous range at its offset. Falls back to the single-connection
/// streaming path when the extra sessions cannot be established.
pub fn sftp_upload_file_parallel(
    host: String,
    port: u16,
    username: String,
    local_path: String,
    remote_path: String,
    concurrency: Option<u8>,
    sink: crate::frb_generated::StreamSink<SftpProgress>,
) -> Result<()> {
    let k = concurrency.unwrap_or(4).clamp(1, 8) as usize;
    let validated_local = validate_local_path(&local_path)?;
    let validated_remote = validate_and_normalize_path(&remote_path, &username)?;

    let total = std::fs::metadata(&validated_local)
        .map_err(|e| anyhow!("Failed to stat local file '{}': {}", validated_local.display(), e))?
        .len();
    if total > MAX_FILE_SIZE {
        return Err(anyhow!(
            "File size exceeds the {} GB limit",
            MAX_FILE_SIZE / (1024 * 1024 * 1024)
        ));
    }

    // Small files: parallel setup costs more than it saves.
    if total < PARALLEL_MIN_SIZE || k == 1 {
        return sftp_upload_file_streaming(host, port, username, local_path, remote_path, sink);
    }

    tracing::info!(
        local_path = %validated_local.display(),
        remote_path = %validated_remote.display(),
        total_bytes = total,
        workers = k,
        "Uploading file via SFTP (parallel)"
    );

    // Coordinator session (file create/truncate, final verification, cleanup)
    // plus K worker sessions, all opened up-front so a MaxSessions-style
    // rejection is detected here and triggers the single-connection fallback.
    let coord = create_ssh_session(&host, port, &username)?;
    let coord_sftp = coord.sftp().map_err(|e| anyhow!("SFTP session failed: {}", e))?;
    let mut workers = Vec::with_capacity(k);
    for i in 0..k {
        match create_ssh_session(&host, port, &username) {
            Ok(sess) => workers.push(sess),
            Err(e) => {
                tracing::warn!(
                    worker = i,
                    error = %e,
                    "Parallel upload: extra session failed, falling back to single connection"
                );
                return sftp_upload_file_streaming(
                    host, port, username, local_path, remote_path, sink,
                );
            }
        }
    }

    // Create the remote file and set its final size (spec: truncate up-front).
    {
        let f = coord_sftp
            .create(&validated_remote)
            .map_err(|e| anyhow!("Failed to create remote file '{}': {}", validated_remote.display(), e))?;
        drop(f);
        let stat = FileStat {
            size: Some(total),
            uid: None,
            gid: None,
            perm: None,
            atime: None,
            mtime: None,
        };
        coord_sftp
            .setstat(&validated_remote, stat)
            .map_err(|e| anyhow!("Failed to size remote file: {}", e))?;
    }

    let transferred = Arc::new(AtomicU64::new(0));
    let cancel = Arc::new(AtomicBool::new(false));
    let remaining = Arc::new(AtomicUsize::new(k));
    let (err_tx, err_rx) = std::sync::mpsc::channel::<anyhow::Error>();
    let ranges = split_ranges(total, k);

    let mut handles = Vec::with_capacity(k);
    for (sess, (offset, len)) in workers.into_iter().zip(ranges.into_iter()) {
        let transferred = Arc::clone(&transferred);
        let cancel = Arc::clone(&cancel);
        let remaining = Arc::clone(&remaining);
        let err_tx = err_tx.clone();
        let local = validated_local.clone();
        let remote = validated_remote.clone();
        handles.push(std::thread::spawn(move || {
            let result = (|| -> Result<()> {
                let sftp = sess.sftp().map_err(|e| anyhow!("worker sftp: {}", e))?;
                let mut rf = sftp
                    .open_mode(&remote, OpenFlags::WRITE, 0o644, OpenType::File)
                    .map_err(|e| anyhow!("worker open remote: {}", e))?;
                rf.seek(SeekFrom::Start(offset))
                    .map_err(|e| anyhow!("worker seek remote: {}", e))?;
                let mut lf = std::fs::File::open(&local)
                    .map_err(|e| anyhow!("worker open local: {}", e))?;
                lf.seek(SeekFrom::Start(offset))
                    .map_err(|e| anyhow!("worker seek local: {}", e))?;

                let mut buf = vec![0u8; 128 * 1024];
                let mut left = len;
                while left > 0 {
                    if cancel.load(Ordering::Relaxed) {
                        return Err(anyhow!("cancelled by sibling failure"));
                    }
                    let want = buf.len().min(left as usize);
                    let n = lf
                        .read(&mut buf[..want])
                        .map_err(|e| anyhow!("worker read: {}", e))?;
                    if n == 0 {
                        return Err(anyhow!("local file shrank during upload"));
                    }
                    rf.write_all(&buf[..n])
                        .map_err(|e| anyhow!("worker write: {}", e))?;
                    left -= n as u64;
                    transferred.fetch_add(n as u64, Ordering::Relaxed);
                }
                Ok(())
            })();
            if let Err(e) = result {
                cancel.store(true, Ordering::Relaxed);
                let _ = err_tx.send(e);
            }
            remaining.fetch_sub(1, Ordering::Relaxed);
        }));
    }
    drop(err_tx);

    // Coordinator: emit throttled progress until all workers finish.
    let _ = sink.add(SftpProgress { transferred: 0, total });
    while remaining.load(Ordering::Relaxed) > 0 {
        std::thread::sleep(std::time::Duration::from_millis(100));
        let _ = sink.add(SftpProgress {
            transferred: transferred.load(Ordering::Relaxed),
            total,
        });
    }
    for h in handles {
        let _ = h.join();
    }

    if let Ok(first_err) = err_rx.try_recv() {
        let _ = coord_sftp.unlink(&validated_remote);
        return Err(anyhow!("Parallel upload failed: {}", first_err));
    }

    // Verify the remote size before declaring success.
    let st = coord_sftp
        .stat(&validated_remote)
        .map_err(|e| anyhow!("Failed to stat uploaded file: {}", e))?;
    if st.size != Some(total) {
        let _ = coord_sftp.unlink(&validated_remote);
        return Err(anyhow!(
            "Uploaded size mismatch: expected {}, got {:?}",
            total,
            st.size
        ));
    }

    let _ = sink.add(SftpProgress { transferred: total, total });
    tracing::info!(bytes = total, workers = k, "File uploaded successfully (parallel)");
    Ok(())
}
```

- [ ] **Step 2: Verify it compiles and the suite passes**

Run: `cd native && cargo build && cargo test`
Expected: build clean; all tests pass (the parallel path is network code — its correctness gate is the benchmark in Task 7 plus checksum QA).

- [ ] **Step 3: Commit**

```bash
git add native/src/sftp.rs
git commit -m "feat(sftp): parallel ranged upload over multiple SSH sessions"
```

---

### Task 3: Parallel download in Rust

**Files:**
- Modify: `native/src/sftp.rs` (after `sftp_upload_file_parallel`)

**Interfaces:**
- Consumes: everything Task 2 uses, plus existing `sftp_download_file` (single-connection; used for small files and fallback — note it takes no sink, so the fallback wraps it and emits start/end progress).
- Produces: `pub fn sftp_download_file_parallel(host: String, port: u16, username: String, remote_path: String, local_path: String, concurrency: Option<u8>, sink: crate::frb_generated::StreamSink<SftpProgress>) -> Result<()>`

- [ ] **Step 1: Implement**

```rust
/// Download a file over `concurrency` parallel SSH connections (symmetric to
/// [`sftp_upload_file_parallel`]). Small files and session-setup failures use
/// the single-connection path, emitting only start/end progress.
pub fn sftp_download_file_parallel(
    host: String,
    port: u16,
    username: String,
    remote_path: String,
    local_path: String,
    concurrency: Option<u8>,
    sink: crate::frb_generated::StreamSink<SftpProgress>,
) -> Result<()> {
    let k = concurrency.unwrap_or(4).clamp(1, 8) as usize;
    let validated_remote = validate_and_normalize_path(&remote_path, &username)?;
    let validated_local = validate_local_path(&local_path)?;

    let coord = create_ssh_session(&host, port, &username)?;
    let coord_sftp = coord.sftp().map_err(|e| anyhow!("SFTP session failed: {}", e))?;
    let total = coord_sftp
        .stat(&validated_remote)
        .map_err(|e| anyhow!("Failed to stat remote file '{}': {}", validated_remote.display(), e))?
        .size
        .ok_or_else(|| anyhow!("Remote file has no size"))?;
    if total > MAX_FILE_SIZE {
        return Err(anyhow!(
            "File size exceeds the {} GB limit",
            MAX_FILE_SIZE / (1024 * 1024 * 1024)
        ));
    }

    // Single-connection path for small files, wrapped so callers still get
    // start/end progress on the sink.
    let single = |sink: &crate::frb_generated::StreamSink<SftpProgress>| -> Result<()> {
        let _ = sink.add(SftpProgress { transferred: 0, total });
        sftp_download_file(
            host.clone(),
            port,
            username.clone(),
            remote_path.clone(),
            local_path.clone(),
        )?;
        let _ = sink.add(SftpProgress { transferred: total, total });
        Ok(())
    };
    if total < PARALLEL_MIN_SIZE || k == 1 {
        return single(&sink);
    }

    tracing::info!(
        remote_path = %validated_remote.display(),
        local_path = %validated_local.display(),
        total_bytes = total,
        workers = k,
        "Downloading file via SFTP (parallel)"
    );

    let mut workers = Vec::with_capacity(k);
    for i in 0..k {
        match create_ssh_session(&host, port, &username) {
            Ok(sess) => workers.push(sess),
            Err(e) => {
                tracing::warn!(
                    worker = i,
                    error = %e,
                    "Parallel download: extra session failed, falling back to single connection"
                );
                return single(&sink);
            }
        }
    }

    // Preallocate the local file to its final size.
    {
        let f = std::fs::File::create(&validated_local)
            .map_err(|e| anyhow!("Failed to create local file '{}': {}", validated_local.display(), e))?;
        f.set_len(total)
            .map_err(|e| anyhow!("Failed to preallocate local file: {}", e))?;
    }

    let transferred = Arc::new(AtomicU64::new(0));
    let cancel = Arc::new(AtomicBool::new(false));
    let remaining = Arc::new(AtomicUsize::new(k));
    let (err_tx, err_rx) = std::sync::mpsc::channel::<anyhow::Error>();
    let ranges = split_ranges(total, k);

    let mut handles = Vec::with_capacity(k);
    for (sess, (offset, len)) in workers.into_iter().zip(ranges.into_iter()) {
        let transferred = Arc::clone(&transferred);
        let cancel = Arc::clone(&cancel);
        let remaining = Arc::clone(&remaining);
        let err_tx = err_tx.clone();
        let local = validated_local.clone();
        let remote = validated_remote.clone();
        handles.push(std::thread::spawn(move || {
            let result = (|| -> Result<()> {
                let sftp = sess.sftp().map_err(|e| anyhow!("worker sftp: {}", e))?;
                let mut rf = sftp.open(&remote).map_err(|e| anyhow!("worker open remote: {}", e))?;
                rf.seek(SeekFrom::Start(offset))
                    .map_err(|e| anyhow!("worker seek remote: {}", e))?;
                let mut lf = std::fs::OpenOptions::new()
                    .write(true)
                    .open(&local)
                    .map_err(|e| anyhow!("worker open local: {}", e))?;
                lf.seek(SeekFrom::Start(offset))
                    .map_err(|e| anyhow!("worker seek local: {}", e))?;

                let mut buf = vec![0u8; 128 * 1024];
                let mut left = len;
                while left > 0 {
                    if cancel.load(Ordering::Relaxed) {
                        return Err(anyhow!("cancelled by sibling failure"));
                    }
                    let want = buf.len().min(left as usize);
                    let n = rf
                        .read(&mut buf[..want])
                        .map_err(|e| anyhow!("worker read remote: {}", e))?;
                    if n == 0 {
                        return Err(anyhow!("remote file shrank during download"));
                    }
                    lf.write_all(&buf[..n])
                        .map_err(|e| anyhow!("worker write local: {}", e))?;
                    left -= n as u64;
                    transferred.fetch_add(n as u64, Ordering::Relaxed);
                }
                Ok(())
            })();
            if let Err(e) = result {
                cancel.store(true, Ordering::Relaxed);
                let _ = err_tx.send(e);
            }
            remaining.fetch_sub(1, Ordering::Relaxed);
        }));
    }
    drop(err_tx);

    let _ = sink.add(SftpProgress { transferred: 0, total });
    while remaining.load(Ordering::Relaxed) > 0 {
        std::thread::sleep(std::time::Duration::from_millis(100));
        let _ = sink.add(SftpProgress {
            transferred: transferred.load(Ordering::Relaxed),
            total,
        });
    }
    for h in handles {
        let _ = h.join();
    }

    if let Ok(first_err) = err_rx.try_recv() {
        let _ = std::fs::remove_file(&validated_local);
        return Err(anyhow!("Parallel download failed: {}", first_err));
    }

    let got = std::fs::metadata(&validated_local)
        .map_err(|e| anyhow!("Failed to stat downloaded file: {}", e))?
        .len();
    if got != total {
        let _ = std::fs::remove_file(&validated_local);
        return Err(anyhow!("Downloaded size mismatch: expected {}, got {}", total, got));
    }

    let _ = sink.add(SftpProgress { transferred: total, total });
    tracing::info!(bytes = total, workers = k, "File downloaded successfully (parallel)");
    Ok(())
}
```

- [ ] **Step 2: Verify build + suite**

Run: `cd native && cargo build && cargo test`
Expected: clean build, all tests pass.

- [ ] **Step 3: Commit**

```bash
git add native/src/sftp.rs
git commit -m "feat(sftp): parallel ranged download over multiple SSH sessions"
```

---

### Task 4: Bridge wrappers + regeneration

**Files:**
- Modify: `native/src/api.rs` (after the existing `sftp_upload_streaming` wrapper)
- Regenerate: `lib/src/bridge/api.dart/` and `native/src/frb_generated.rs`

**Interfaces:**
- Consumes: Tasks 2–3 functions.
- Produces (Dart, generated): `Stream<SftpProgress> sftpUploadParallel({required String host, required int port, required String username, required String localPath, required String remotePath, int? concurrency})` and `Stream<SftpProgress> sftpDownloadParallel({required String host, required int port, required String username, required String remotePath, required String localPath, int? concurrency})`.

- [ ] **Step 1: Add wrappers**

```rust
/// Parallel upload: K SSH connections write ranges; emits aggregate progress.
pub fn sftp_upload_parallel(
    host: String,
    port: u16,
    username: String,
    local_path: String,
    remote_path: String,
    concurrency: Option<u8>,
    sink: crate::frb_generated::StreamSink<crate::sftp::SftpProgress>,
) -> anyhow::Result<()> {
    crate::sftp::sftp_upload_file_parallel(host, port, username, local_path, remote_path, concurrency, sink)
}

/// Parallel download: K SSH connections read ranges; emits aggregate progress.
pub fn sftp_download_parallel(
    host: String,
    port: u16,
    username: String,
    remote_path: String,
    local_path: String,
    concurrency: Option<u8>,
    sink: crate::frb_generated::StreamSink<crate::sftp::SftpProgress>,
) -> anyhow::Result<()> {
    crate::sftp::sftp_download_file_parallel(host, port, username, remote_path, local_path, concurrency, sink)
}
```

- [ ] **Step 2: Regenerate the bridge**

```bash
/home/jlopezre/.cargo/bin/flutter_rust_bridge_codegen generate --rust-input "crate::api" --rust-root native --dart-output lib/src/bridge/api.dart
```
Expected: exits 0; `sftpUploadParallel`/`sftpDownloadParallel` appear in `lib/src/bridge/api.dart/api.dart`.

- [ ] **Step 3: Rebuild BOTH Rust profiles** (content-hash lesson: the app loads the release lib)

```bash
cd native && cargo build && cargo build --release && cargo test && cd ..
flutter analyze
```
Expected: clean builds, tests pass, 0 analyze errors.

- [ ] **Step 4: Commit**

```bash
git add native/src/api.rs native/src/frb_generated.rs lib/src/bridge
git commit -m "feat(sftp): expose parallel transfers across the bridge"
```

---

### Task 5: Dart — single file upload/download use the parallel path

**Files:**
- Modify: `lib/src/features/sftp_browser.dart` (`uploadFile` ~line 174, `downloadFile` ~line 336)

**Interfaces:**
- Consumes: `sftpUploadParallel` / `sftpDownloadParallel` (Task 4); existing state fields `operationInProgress`, `progress`.

- [ ] **Step 1: Switch `uploadFile`**

In `uploadFile`, replace the `sftpUploadStreaming` loop with the parallel call (identical shape, `concurrency: 4`):

```dart
        final label = l10n.sftpUploadingFile(fileName);
        state = state.copyWith(operationInProgress: label, progress: 0);

        await for (final p in sftpUploadParallel(
          host: host,
          port: port,
          username: username,
          localPath: localPath,
          remotePath: remotePath,
          concurrency: 4,
        )) {
          final total = p.total.toInt();
          state = state.copyWith(
            operationInProgress: label,
            progress: total > 0 ? p.transferred.toInt() / total : null,
          );
        }

        state = state.copyWith(operationInProgress: null);
        await refresh(l10n);
```

- [ ] **Step 2: Switch `downloadFile` and give it a progress bar**

Replace the `sftpDownload(...)` call inside `downloadFile` with:

```dart
        final label = l10n.sftpDownloadingFile(file.name);
        state = state.copyWith(operationInProgress: label, progress: 0);

        await for (final p in sftpDownloadParallel(
          host: host,
          port: port,
          username: username,
          remotePath: file.path,
          localPath: localPath,
          concurrency: 4,
        )) {
          final total = p.total.toInt();
          state = state.copyWith(
            operationInProgress: label,
            progress: total > 0 ? p.transferred.toInt() / total : null,
          );
        }

        state = state.copyWith(operationInProgress: null);
```
(Keep the surrounding directory-picker logic and error handling exactly as they are.)

- [ ] **Step 3: Verify**

Run: `flutter analyze && flutter test`
Expected: 0 errors; all tests pass.

- [ ] **Step 4: Commit**

```bash
git add lib/src/features/sftp_browser.dart
git commit -m "feat(sftp): single-file transfers use the parallel path with progress"
```

---

### Task 6: Dart — folder upload pool + global progress + i18n

**Files:**
- Modify: `lib/src/features/sftp_browser.dart` (`uploadFolder`)
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_es.arb` (append-only; do not reformat)

**Interfaces:**
- Consumes: `sftpUploadParallel` (Task 4).
- Produces: l10n key `sftpFolderProgressLabel(int percent, int done, int total, int filesDone, int filesTotal)`.

- [ ] **Step 1: Add the i18n keys**

`lib/l10n/app_en.arb` (append before the closing brace, keeping formatting):
```json
  "sftpFolderProgressLabel": "{percent}% — {done}/{total} MB, {filesDone}/{filesTotal} files",
  "@sftpFolderProgressLabel": {
    "placeholders": {
      "percent": {"type": "int"},
      "done": {"type": "int"},
      "total": {"type": "int"},
      "filesDone": {"type": "int"},
      "filesTotal": {"type": "int"}
    }
  }
```
`lib/l10n/app_es.arb`:
```json
  "sftpFolderProgressLabel": "{percent} % — {done}/{total} MB, {filesDone}/{filesTotal} archivos"
```
Run `flutter gen-l10n`; verify parity with the usual python one-liner → `PARITY OK`.

- [ ] **Step 2: Rewrite the file-upload phase of `uploadFolder`**

Replace the sequential per-file loop (the `var uploaded = 0; for (final f in files) { ... }` block) with a 3-worker pool and byte-aggregate progress. Directory creation above it stays unchanged.

```dart
      // Total bytes for the whole folder (for the global progress bar).
      final sizes = <String, int>{};
      var totalBytes = 0;
      for (final f in files) {
        final len = await f.length();
        sizes[f.path] = len;
        totalBytes += len;
      }

      // 3 files in flight, each with 2 internal connections (≤6 total).
      var nextIndex = 0;
      var filesDone = 0;
      var doneBytes = 0;
      final inFlight = <String, int>{};

      void emitProgress() {
        final current =
            doneBytes + inFlight.values.fold<int>(0, (a, b) => a + b);
        final fraction = totalBytes > 0 ? current / totalBytes : null;
        state = state.copyWith(
          operationInProgress: l10n.sftpFolderProgressLabel(
            totalBytes > 0 ? (current * 100 ~/ totalBytes) : 100,
            current ~/ 1000000,
            totalBytes ~/ 1000000,
            filesDone,
            files.length,
          ),
          progress: fraction,
        );
      }

      Future<void> worker() async {
        while (true) {
          final i = nextIndex++;
          if (i >= files.length) return;
          final f = files[i];
          final rel = path.relative(f.path, from: localDir!);
          await for (final p in sftpUploadParallel(
            host: host,
            port: port,
            username: username,
            localPath: f.path,
            remotePath: path.join(remoteRoot, rel),
            concurrency: 2,
          )) {
            inFlight[f.path] = p.transferred.toInt();
            emitProgress();
          }
          inFlight.remove(f.path);
          doneBytes += sizes[f.path] ?? 0;
          filesDone++;
          emitProgress();
        }
      }

      emitProgress();
      await Future.wait([worker(), worker(), worker()]);

      state = state.copyWith(operationInProgress: null);
      await refresh(l10n);
```
NOTE: `localDir` is non-null past the early-return guard; if the analyzer objects to `localDir!`, capture `final dir = localDir;` after the guard and use `dir`.

- [ ] **Step 3: Verify**

Run: `flutter gen-l10n && flutter analyze && flutter test`
Expected: 0 errors; all tests pass (including `es_overflow_test.dart` — the banner layout is unchanged).

- [ ] **Step 4: Commit**

```bash
git add lib/src/features/sftp_browser.dart lib/l10n
git commit -m "feat(sftp): parallel folder upload with global byte progress"
```

---

### Task 7: Benchmark parallel mode + full gate + manual QA

**Files:**
- Modify: `native/examples/transfer_bench.rs`
- Create: `docs/superpowers/plans/2026-07-22-sftp-speed-manual-qa.md`

- [ ] **Step 1: Add a parallel mode to the benchmark**

Append to `main()` in `native/examples/transfer_bench.rs` (after the RAW section), an optional 6th arg `K` enabling a ranged-parallel upload measurement:

```rust
    // --- optional: parallel ranged upload with K sessions ---
    if let Some(k_arg) = std::env::args().nth(6) {
        let k: usize = k_arg.parse().expect("K");
        let par_path = format!("{remote_dir}/bench_par.bin");
        // Create + size the remote file first.
        let f = sftp.create(Path::new(&par_path)).expect("create par");
        drop(f);
        let ranges: Vec<(u64, u64)> = {
            let base = size / k as u64;
            (0..k as u64)
                .map(|i| {
                    let off = i * base;
                    let len = if i == k as u64 - 1 { size - off } else { base };
                    (off, len)
                })
                .collect()
        };
        let start = Instant::now();
        let mut handles = Vec::new();
        for (off, len) in ranges {
            let host = host.clone();
            let user = user.clone();
            let data = data.clone();
            let par_path = par_path.clone();
            handles.push(std::thread::spawn(move || {
                let sess = session(&host, port, &user);
                let sftp = sess.sftp().unwrap();
                let mut rf = sess_open_write(&sftp, &par_path);
                use std::io::Seek;
                rf.seek(std::io::SeekFrom::Start(off)).unwrap();
                let end = (off + len) as usize;
                for chunk in data[off as usize..end].chunks(BUF) {
                    rf.write_all(chunk).unwrap();
                }
            }));
        }
        for h in handles {
            h.join().unwrap();
        }
        report(&format!("PAR{k}"), size, start.elapsed().as_secs_f64());
        let st = sftp.stat(Path::new(&par_path)).expect("stat par");
        assert_eq!(st.size, Some(size), "parallel size mismatch");
        sftp.unlink(Path::new(&par_path)).expect("unlink par");
        println!("parallel verified and cleaned up");
    }
```
And add this helper above `main`:
```rust
fn sess_open_write(sftp: &ssh2::Sftp, path: &str) -> ssh2::File {
    sftp.open_mode(
        Path::new(path),
        ssh2::OpenFlags::WRITE,
        0o644,
        ssh2::OpenType::File,
    )
    .expect("open write")
}
```
Note `data` must become `let data = std::sync::Arc::new(std::fs::read(local).expect("read local file"));` at the top of `main` (and `size = data.len() as u64` unchanged; earlier uses index via `&data[..]`).

- [ ] **Step 2: Run the benchmark against the real VM** (developer step; needs a tunnel)

```bash
cd native && cargo build --release --example transfer_bench
gcloud compute start-iap-tunnel backupmig 22 --local-host-port=localhost:42022 \
  --zone=southamerica-west1-c --project=project-shared-backup &
sleep 8
./target/release/examples/transfer_bench localhost 42022 <user> <20MB-file> /home/<user> 4
kill %1
```
Expected: `PAR4` reports ≥3 MB/s (spec target 3–5 MB/s). Record the numbers in the commit message.

- [ ] **Step 3: Full gate**

```bash
cd native && cargo test && cargo build --release && cd ..
flutter gen-l10n && flutter analyze && flutter test && flutter build linux --debug
python3 -c "import json;a=json.load(open('lib/l10n/app_en.arb'));b=json.load(open('lib/l10n/app_es.arb'));ka={k for k in a if not k.startswith('@')};kb={k for k in b if not k.startswith('@')};print(sorted(ka^kb) or 'PARITY OK')"
```
Expected: all green, `PARITY OK`.

- [ ] **Step 4: Write the manual QA checklist**

Create `docs/superpowers/plans/2026-07-22-sftp-speed-manual-qa.md`:
```markdown
# Manual QA — SFTP parallel transfers (27H1)

Run with the app's default engine (gcloud tunnel), no env vars needed.

- [ ] Upload a >100 MB file; the bar advances and the transfer completes ≥3x
      faster than before (~0.7 MB/s baseline).
- [ ] `sha256sum` of the uploaded file matches the local one (run on the VM).
- [ ] Download the same file back; progress bar shows; checksum matches.
- [ ] Upload the offline-bundle folder (12 files, ~250 MB): global bar shows
      "N% — X/Y MB, F/12 archivos" and total time is ~1–1.5 min.
- [ ] Small file (<8 MB) uploads still work (single-connection path).
- [ ] Kill the tunnel mid-upload: the app shows an error, and the partial
      remote file was deleted (verify on the VM).
- [ ] Close the dialog mid-upload: app does not crash (same behavior as before).
```

- [ ] **Step 5: Commit**

```bash
git add native/examples/transfer_bench.rs docs/superpowers/plans/2026-07-22-sftp-speed-manual-qa.md
git commit -m "chore(sftp): parallel benchmark mode + manual QA checklist"
```

---

## Self-Review (done at write time)

- **Spec coverage:** §1 Rust (split_ranges → T1; upload → T2; download → T3; fallback → T2/T3 session-setup paths; cleanup+cancel → worker closures) ; §2 bridge + both profiles → T4; §3 folder pool + global bar → T6; §4 downloads with progress → T5; §5 i18n → T6; §6 verificación (unit tests → T1; benchmark → T7; checksum + QA manual → T7 checklist). Out-of-scope items untouched. No gaps.
- **Placeholders:** none — every code step carries the code. The benchmark run (T7 step 2) is a developer-executed step against the real VM by nature.
- **Type consistency:** `split_ranges(u64, usize) -> Vec<(u64,u64)>` used identically in T2/T3; `SftpProgress { transferred, total }` matches the existing bridge type; Dart signatures in T5/T6 match T4's produced API (`concurrency: int?`); `PARALLEL_MIN_SIZE` referenced in T2/T3 as defined in T1.
