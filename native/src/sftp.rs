use anyhow::{Result, anyhow};
use serde::{Deserialize, Serialize};
use ssh2::{FileStat, OpenFlags, OpenType, Session};
use std::io::{Read, Seek, SeekFrom, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::Arc;
use tracing;

/// Maximum file size for transfers (10 GB)
/// This prevents DoS attacks via disk exhaustion
const MAX_FILE_SIZE: u64 = 10 * 1024 * 1024 * 1024;

/// Represents a remote file or directory entry
#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct RemoteFileEntry {
    pub name: String,
    pub path: String,
    pub is_directory: bool,
    pub size: u64,
    pub modified: Option<i64>, // Unix timestamp
    pub permissions: Option<u32>,
}

/// SFTP connection parameters
#[allow(dead_code)]
#[derive(Debug, Clone)]
pub struct SftpConnectionParams {
    pub host: String,
    pub port: u16,
    pub username: String,
}

/// Copy data from reader to writer with size limit to prevent DoS attacks
///
/// This function prevents disk exhaustion attacks by limiting the maximum
/// amount of data that can be transferred in a single operation.
///
/// # Security
/// This prevents CWE-400 (Uncontrolled Resource Consumption) attacks
fn copy_with_limit<R: Read, W: Write>(
    reader: &mut R,
    writer: &mut W,
    max_size: u64,
) -> Result<u64> {
    // 128 KB buffer (heap-allocated). SFTP over libssh2 does a round-trip per
    // write, so an 8 KB buffer meant ~27,900 round-trips for a 218 MB file
    // (~170 KB/s over the IAP tunnel). A larger buffer cuts round-trips by 16x.
    let mut buffer = vec![0u8; 128 * 1024];
    let mut total_bytes = 0u64;

    loop {
        // Read chunk from source
        let bytes_read = reader.read(&mut buffer)
            .map_err(|e| anyhow!("Read error during file transfer: {}", e))?;

        if bytes_read == 0 {
            break; // EOF reached
        }

        // Check size limit BEFORE writing
        total_bytes += bytes_read as u64;
        if total_bytes > max_size {
            let max_gb = max_size / (1024 * 1024 * 1024);
            return Err(anyhow!(
                "File size exceeds maximum allowed size of {} GB ({} bytes). Transfer aborted.",
                max_gb,
                max_size
            ));
        }

        // Write chunk to destination
        writer.write_all(&buffer[..bytes_read])
            .map_err(|e| anyhow!("Write error during file transfer: {}", e))?;
    }

    Ok(total_bytes)
}

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

/// Get the real home directory for a remote user
///
/// This function determines the correct home directory by checking common patterns.
/// In most Linux systems, home directories follow standard conventions:
/// - Standard: /home/{username}
/// - LDAP/AD: May vary, but usually follows standard pattern
/// - Root: /root
///
/// # Security
/// We use a whitelist approach to prevent path injection attacks
fn get_remote_home_directory(username: &str) -> PathBuf {
    // Special case for root user
    if username == "root" {
        return PathBuf::from("/root");
    }

    // For all other users, use standard /home/{username} pattern
    // This is the most common convention and is enforced for security
    // Note: If NSS/LDAP users have different home paths, the sysadmin should
    // configure pam_mkhomedir or similar to ensure /home/{user} exists
    PathBuf::from(format!("/home/{}", username))
}

/// Validate and normalize a remote path for browsing the VM's filesystem.
///
/// This function ensures that:
/// 1. The username is valid (POSIX format)
/// 2. The path does not contain ".." components (parent directory references)
/// 3. Relative paths resolve against the user's home directory
/// 4. The path is normalized to an absolute path
///
/// # Security
/// The remote SFTP/SSH server enforces the authenticated user's real
/// permissions, so browsing is NOT jailed to the home directory — an operator
/// legitimately needs to reach `/var/log`, `/etc`, `/`, etc. CWE-22 (path
/// traversal) is mitigated by rejecting `..` components before normalization
/// and by the server-side permission model. Note: writes to the LOCAL machine
/// (downloads) stay jailed to the local home via `validate_local_path`.
fn validate_and_normalize_path(remote_path: &str, username: &str) -> Result<PathBuf> {
    // SECURITY: Validate username first to prevent path injection
    crate::validation::validate_username(username)?;

    let path = Path::new(remote_path);

    // Security check: Reject paths with parent directory components
    if path.components().any(|c| matches!(c, std::path::Component::ParentDir)) {
        tracing::warn!(
            remote_path = remote_path,
            username = username,
            "Path traversal attempt detected"
        );
        return Err(anyhow!("Path traversal not allowed (.. components forbidden)"));
    }

    // Get the allowed base directory for this user
    let allowed_base = get_remote_home_directory(username);

    // Resolve to full path
    let full_path = if path.is_absolute() {
        path.to_path_buf()
    } else {
        allowed_base.join(path)
    };

    // Normalize the path by processing components
    let normalized = full_path.components()
        .fold(PathBuf::new(), |mut acc, component| {
            match component {
                std::path::Component::ParentDir => {
                    // Pop if not at root
                    acc.pop();
                },
                std::path::Component::Normal(c) => {
                    acc.push(c);
                },
                std::path::Component::RootDir => {
                    acc.push("/");
                },
                std::path::Component::CurDir => {
                    // Skip current directory references
                },
                std::path::Component::Prefix(_) => {
                    // Windows paths not applicable on Linux
                },
            }
            acc
        });

    // No home-directory jail: the remote SFTP server authorizes access per the
    // authenticated user's real permissions. `..` was already rejected above,
    // so `normalized` is an absolute, traversal-free path.
    tracing::debug!(
        original_path = remote_path,
        normalized_path = %normalized.display(),
        "Path validated successfully"
    );

    Ok(normalized)
}

/// Validate local file path for downloads/uploads
///
/// This function ensures that:
/// 1. The path does not contain ".." components (parent directory traversal)
/// 2. The path is within allowed directories (user's home)
/// 3. The path is properly normalized
///
/// # Security
/// Prevents writing to arbitrary system locations (CWE-22)
fn validate_local_path(local_path: &str) -> Result<PathBuf> {
    let path = Path::new(local_path);

    // Security check: Reject paths with parent directory components
    if path.components().any(|c| matches!(c, std::path::Component::ParentDir)) {
        tracing::warn!(
            local_path = local_path,
            "Local path traversal attempt detected"
        );
        return Err(anyhow!("Local path traversal not allowed (.. components forbidden)"));
    }

    // Get user's home directory
    let home_dir = dirs::home_dir()
        .ok_or_else(|| anyhow!("Could not determine home directory"))?;

    // Resolve to full path
    let full_path = if path.is_absolute() {
        path.to_path_buf()
    } else {
        home_dir.join(path)
    };

    // Canonicalize to resolve any symlinks and normalize
    let normalized = full_path.canonicalize()
        .or_else(|_| {
            // If path doesn't exist yet, validate parent directory
            if let Some(parent) = full_path.parent() {
                parent.canonicalize().map(|p| p.join(full_path.file_name().unwrap()))
            } else {
                Err(std::io::Error::new(std::io::ErrorKind::NotFound, "Invalid local path"))
            }
        })
        .map_err(|e| anyhow!("Failed to validate local path: {}", e))?;

    // Verify path is within user's home directory
    if !normalized.starts_with(&home_dir) {
        tracing::warn!(
            normalized_path = %normalized.display(),
            home_dir = %home_dir.display(),
            "Access denied: local path outside home directory"
        );
        return Err(anyhow!(
            "Access denied: local path must be within your home directory ({})",
            home_dir.display()
        ));
    }

    tracing::debug!(
        original_path = local_path,
        normalized_path = %normalized.display(),
        "Local path validated successfully"
    );

    Ok(normalized)
}

/// Create SSH session and authenticate
fn create_ssh_session(host: &str, port: u16, username: &str) -> Result<Session> {
    tracing::info!(
        host = host,
        port = port,
        username = username,
        "Creating SSH session for SFTP"
    );

    // Connect to the SSH server (via IAP tunnel on localhost)
    let tcp = TcpStream::connect(format!("{}:{}", host, port))
        .map_err(|e| anyhow!("Failed to connect to SSH server: {}", e))?;

    // Create SSH session
    let mut sess = Session::new()
        .map_err(|e| anyhow!("Failed to create SSH session: {}", e))?;

    sess.set_tcp_stream(tcp);
    sess.handshake()
        .map_err(|e| anyhow!("SSH handshake failed: {}", e))?;

    // Try multiple authentication methods and accumulate errors for better diagnostics
    let mut auth_errors = Vec::new();

    // Try SSH agent authentication first (most common for GCP)
    if let Err(e) = sess.userauth_agent(username) {
        let error_msg = format!("SSH agent: {}", e);
        tracing::warn!(error = %error_msg, "SSH agent authentication failed");
        auth_errors.push(error_msg);

        // Try default SSH key as fallback
        let home = dirs::home_dir()
            .ok_or_else(|| anyhow!("Could not determine home directory"))?;
        let key_path = home.join(".ssh").join("id_rsa");

        if !key_path.exists() {
            let error_msg = format!(
                "SSH key file not found at: {}. Set up SSH keys or start ssh-agent.",
                key_path.display()
            );
            auth_errors.push(error_msg.clone());

            return Err(anyhow!(
                "All SSH authentication methods failed:\n  • {}\n\n\
                Please either:\n\
                  1. Start ssh-agent and add your key: ssh-add ~/.ssh/id_rsa\n\
                  2. Create an SSH key pair: ssh-keygen -t rsa\n\
                  3. Ensure your public key is in the remote server's ~/.ssh/authorized_keys",
                auth_errors.join("\n  • ")
            ));
        }

        if let Err(e) = sess.userauth_pubkey_file(username, None, &key_path, None) {
            let error_msg = format!("SSH key file ({}): {}", key_path.display(), e);
            auth_errors.push(error_msg);

            return Err(anyhow!(
                "All SSH authentication methods failed:\n  • {}\n\n\
                Troubleshooting:\n\
                  • Check that your public key is in ~/.ssh/authorized_keys on the remote server\n\
                  • Verify key permissions: chmod 600 ~/.ssh/id_rsa\n\
                  • Try: ssh-add ~/.ssh/id_rsa",
                auth_errors.join("\n  • ")
            ));
        }
    }

    if !sess.authenticated() {
        auth_errors.push("Final authentication check failed".to_string());
        return Err(anyhow!(
            "SSH authentication failed despite successful auth call:\n  • {}",
            auth_errors.join("\n  • ")
        ));
    }

    tracing::info!("SSH session authenticated successfully");
    Ok(sess)
}

/// List directory contents via SFTP
pub fn sftp_list_directory(
    host: String,
    port: u16,
    username: String,
    remote_path: String,
) -> Result<Vec<RemoteFileEntry>> {
    // Security: Validate and normalize path to prevent traversal attacks
    let validated_path = validate_and_normalize_path(&remote_path, &username)?;

    tracing::info!(
        remote_path = %validated_path.display(),
        "Listing SFTP directory"
    );

    let sess = create_ssh_session(&host, port, &username)?;
    let sftp = sess.sftp()
        .map_err(|e| anyhow!("Failed to create SFTP session: {}", e))?;

    let entries = sftp.readdir(&validated_path)
        .map_err(|e| anyhow!("Failed to read directory '{}': {}", validated_path.display(), e))?;

    let mut result = Vec::new();
    for (entry_path, stat) in entries {
        let name = entry_path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("")
            .to_string();

        // Skip . and .. entries
        if name == "." || name == ".." {
            continue;
        }

        let is_directory = stat.is_dir();
        let size = stat.size.unwrap_or(0);
        let modified = stat.mtime.map(|t| t as i64);
        let permissions = stat.perm;

        result.push(RemoteFileEntry {
            name,
            path: entry_path.to_string_lossy().to_string(),
            is_directory,
            size,
            modified,
            permissions,
        });
    }

    // Sort: directories first, then by name
    result.sort_by(|a, b| {
        match (a.is_directory, b.is_directory) {
            (true, false) => std::cmp::Ordering::Less,
            (false, true) => std::cmp::Ordering::Greater,
            _ => a.name.to_lowercase().cmp(&b.name.to_lowercase()),
        }
    });

    tracing::info!(count = result.len(), "Directory listing completed");
    Ok(result)
}

/// Download a file from remote server
pub fn sftp_download_file(
    host: String,
    port: u16,
    username: String,
    remote_path: String,
    local_path: String,
) -> Result<u64> {
    // Security: Validate and normalize remote path to prevent traversal attacks
    let validated_remote_path = validate_and_normalize_path(&remote_path, &username)?;

    // Security: Validate local path to prevent writing to arbitrary locations
    let validated_local_path = validate_local_path(&local_path)?;

    tracing::info!(
        remote_path = %validated_remote_path.display(),
        local_path = %validated_local_path.display(),
        "Downloading file via SFTP"
    );

    let sess = create_ssh_session(&host, port, &username)?;
    let sftp = sess.sftp()
        .map_err(|e| anyhow!("Failed to create SFTP session: {}", e))?;

    // Open remote file
    let mut remote_file = sftp.open(&validated_remote_path)
        .map_err(|e| anyhow!("Failed to open remote file '{}': {}", validated_remote_path.display(), e))?;

    // Create local file
    let mut local_file = std::fs::File::create(&validated_local_path)
        .map_err(|e| anyhow!("Failed to create local file '{}': {}", validated_local_path.display(), e))?;

    // Copy data with size limit to prevent DoS
    let bytes_copied = copy_with_limit(&mut remote_file, &mut local_file, MAX_FILE_SIZE)?;

    tracing::info!(bytes = bytes_copied, "File downloaded successfully");
    Ok(bytes_copied)
}

/// Upload a file to remote server
pub fn sftp_upload_file(
    host: String,
    port: u16,
    username: String,
    local_path: String,
    remote_path: String,
) -> Result<u64> {
    // Security: Validate local path to prevent reading from arbitrary locations
    let validated_local_path = validate_local_path(&local_path)?;

    // Security: Validate and normalize remote path to prevent traversal attacks
    let validated_remote_path = validate_and_normalize_path(&remote_path, &username)?;

    tracing::info!(
        local_path = %validated_local_path.display(),
        remote_path = %validated_remote_path.display(),
        "Uploading file via SFTP"
    );

    let sess = create_ssh_session(&host, port, &username)?;
    let sftp = sess.sftp()
        .map_err(|e| anyhow!("Failed to create SFTP session: {}", e))?;

    // Open local file
    let mut local_file = std::fs::File::open(&validated_local_path)
        .map_err(|e| anyhow!("Failed to open local file '{}': {}", validated_local_path.display(), e))?;

    // Create remote file
    let mut remote_file = sftp.create(&validated_remote_path)
        .map_err(|e| anyhow!("Failed to create remote file '{}': {}", validated_remote_path.display(), e))?;

    // Copy data with size limit to prevent DoS
    let bytes_copied = copy_with_limit(&mut local_file, &mut remote_file, MAX_FILE_SIZE)?;

    tracing::info!(bytes = bytes_copied, "File uploaded successfully");
    Ok(bytes_copied)
}

/// Byte-level progress of an SFTP transfer, streamed to the UI.
#[derive(Debug, Clone)]
pub struct SftpProgress {
    pub transferred: u64,
    pub total: u64,
}

/// Upload a file, emitting byte-level progress to `sink` (throttled to ~10/sec)
/// so the UI can show a progress bar even for large files.
pub fn sftp_upload_file_streaming(
    host: String,
    port: u16,
    username: String,
    local_path: String,
    remote_path: String,
    sink: crate::frb_generated::StreamSink<SftpProgress>,
) -> Result<()> {
    let validated_local_path = validate_local_path(&local_path)?;
    let validated_remote_path = validate_and_normalize_path(&remote_path, &username)?;

    let total = std::fs::metadata(&validated_local_path)
        .map(|m| m.len())
        .unwrap_or(0);

    tracing::info!(
        local_path = %validated_local_path.display(),
        remote_path = %validated_remote_path.display(),
        total_bytes = total,
        "Uploading file via SFTP (streaming)"
    );

    let sess = create_ssh_session(&host, port, &username)?;
    let sftp = sess.sftp()
        .map_err(|e| anyhow!("Failed to create SFTP session: {}", e))?;

    let mut local_file = std::fs::File::open(&validated_local_path)
        .map_err(|e| anyhow!("Failed to open local file '{}': {}", validated_local_path.display(), e))?;
    let mut remote_file = sftp.create(&validated_remote_path)
        .map_err(|e| anyhow!("Failed to create remote file '{}': {}", validated_remote_path.display(), e))?;

    let mut buffer = vec![0u8; 128 * 1024];
    let mut transferred = 0u64;
    let mut last_emit = std::time::Instant::now();
    let _ = sink.add(SftpProgress { transferred: 0, total });

    loop {
        let n = local_file.read(&mut buffer)
            .map_err(|e| anyhow!("Read error during upload: {}", e))?;
        if n == 0 {
            break;
        }
        transferred += n as u64;
        if transferred > MAX_FILE_SIZE {
            return Err(anyhow!(
                "File size exceeds the {} GB limit",
                MAX_FILE_SIZE / (1024 * 1024 * 1024)
            ));
        }
        remote_file.write_all(&buffer[..n])
            .map_err(|e| anyhow!("Write error during upload: {}", e))?;

        // Throttle progress events to ~10/sec to avoid flooding the bridge.
        if last_emit.elapsed() >= std::time::Duration::from_millis(100) {
            let _ = sink.add(SftpProgress { transferred, total });
            last_emit = std::time::Instant::now();
        }
    }

    // Final 100% event.
    let _ = sink.add(SftpProgress { transferred, total });
    tracing::info!(bytes = transferred, "File uploaded successfully (streaming)");
    Ok(())
}

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

/// Create a directory on remote server
pub fn sftp_create_directory(
    host: String,
    port: u16,
    username: String,
    remote_path: String,
) -> Result<()> {
    // Security: Validate and normalize path to prevent traversal attacks
    let validated_path = validate_and_normalize_path(&remote_path, &username)?;

    tracing::info!(remote_path = %validated_path.display(), "Creating remote directory");

    let sess = create_ssh_session(&host, port, &username)?;
    let sftp = sess.sftp()
        .map_err(|e| anyhow!("Failed to create SFTP session: {}", e))?;

    sftp.mkdir(&validated_path, 0o755)
        .map_err(|e| anyhow!("Failed to create directory '{}': {}", validated_path.display(), e))?;

    tracing::info!("Directory created successfully");
    Ok(())
}

/// Delete a file or directory on remote server
pub fn sftp_delete(
    host: String,
    port: u16,
    username: String,
    remote_path: String,
    is_directory: bool,
) -> Result<()> {
    // Security: Validate and normalize path to prevent traversal attacks
    let validated_path = validate_and_normalize_path(&remote_path, &username)?;

    tracing::info!(
        remote_path = %validated_path.display(),
        is_directory = is_directory,
        "Deleting remote path"
    );

    let sess = create_ssh_session(&host, port, &username)?;
    let sftp = sess.sftp()
        .map_err(|e| anyhow!("Failed to create SFTP session: {}", e))?;

    if is_directory {
        sftp.rmdir(&validated_path)
            .map_err(|e| anyhow!("Failed to delete directory '{}': {}", validated_path.display(), e))?;
    } else {
        sftp.unlink(&validated_path)
            .map_err(|e| anyhow!("Failed to delete file '{}': {}", validated_path.display(), e))?;
    }

    tracing::info!("Path deleted successfully");
    Ok(())
}

/// Get current username from environment
pub fn get_current_username() -> Result<String> {
    std::env::var("USER")
        .or_else(|_| std::env::var("USERNAME"))
        .map_err(|_| anyhow!("Could not determine current username"))
}

#[cfg(test)]
mod tests {
    use super::*;

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

    #[test]
    fn allows_absolute_remote_paths_outside_home() {
        // A remote VM file browser must reach anywhere the SFTP server allows;
        // the server enforces the authenticated user's real permissions.
        assert_eq!(
            validate_and_normalize_path("/home", "jlopezre").unwrap(),
            PathBuf::from("/home")
        );
        assert_eq!(
            validate_and_normalize_path("/var/log", "jlopezre").unwrap(),
            PathBuf::from("/var/log")
        );
        assert_eq!(
            validate_and_normalize_path("/", "jlopezre").unwrap(),
            PathBuf::from("/")
        );
    }

    #[test]
    fn resolves_relative_paths_against_home() {
        assert_eq!(
            validate_and_normalize_path("docs", "jlopezre").unwrap(),
            PathBuf::from("/home/jlopezre/docs")
        );
    }

    #[test]
    fn still_allows_home_subpaths() {
        assert_eq!(
            validate_and_normalize_path("/home/jlopezre/logs", "jlopezre").unwrap(),
            PathBuf::from("/home/jlopezre/logs")
        );
    }

    #[test]
    fn still_rejects_parent_dir_components() {
        // `..` remains forbidden as an injection/traversal defense.
        assert!(validate_and_normalize_path("/etc/../etc/passwd", "jlopezre").is_err());
        assert!(validate_and_normalize_path("../../etc/passwd", "jlopezre").is_err());
    }

    #[test]
    fn still_rejects_invalid_username() {
        assert!(validate_and_normalize_path("/home", "bad;name").is_err());
    }
}
