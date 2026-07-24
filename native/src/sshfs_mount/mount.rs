//! SSHFS Mount Operations
//!
//! Core functionality for mounting and unmounting remote filesystems via SSHFS.

use anyhow::{Result, anyhow};
use std::collections::HashMap;
use std::path::Path;
use std::process::Command;
use std::sync::Mutex;
use lazy_static::lazy_static;
use tracing;

use super::{
    SshfsMount, SshfsMountOptions, MountResult, UnmountResult,
    utils::{
        validate_remote_path, validate_local_mount_point, ensure_directory_exists,
        is_mount_point, is_directory_empty, get_fusermount_command, generate_mount_id,
        get_sshfs_status, open_in_file_manager,
    },
};

lazy_static! {
    /// Global registry of active mounts
    static ref ACTIVE_MOUNTS: Mutex<HashMap<String, SshfsMount>> = Mutex::new(HashMap::new());
}

/// Mount a remote directory via SSHFS through an IAP tunnel
///
/// # Arguments
/// * `project_id` - GCP project ID
/// * `zone` - GCP zone
/// * `instance_name` - VM instance name
/// * `username` - SSH username
/// * `remote_path` - Remote directory to mount
/// * `local_mount_point` - Local directory to mount to
/// * `tunnel_port` - Local port of the IAP tunnel
/// * `options` - Mount options
///
/// # Security
/// - Validates paths to prevent traversal attacks
/// - Uses StrictHostKeyChecking=no for IAP tunnels (localhost)
/// - Binds only to localhost via tunnel
pub fn mount_sshfs(
    project_id: &str,
    zone: &str,
    instance_name: &str,
    username: &str,
    remote_path: &str,
    local_mount_point: &str,
    tunnel_port: u16,
    options: SshfsMountOptions,
) -> MountResult {
    // Check sshfs availability
    let status = get_sshfs_status();
    if !status.installed {
        let msg = if cfg!(target_os = "macos") {
            "sshfs is not installed. Install with: brew install macfuse sshfs-mac".to_string()
        } else {
            "sshfs is not installed. Install with: sudo apt install sshfs (Debian/Ubuntu) or sudo dnf install fuse-sshfs (Fedora)".to_string()
        };
        return MountResult {
            success: false,
            mount: None,
            error: Some(msg),
            mount_point: local_mount_point.to_string(),
        };
    }

    if !status.fuse_available {
        let msg = if cfg!(target_os = "macos") {
            "FUSE is not available. Install macFUSE from https://osxfuse.github.io/".to_string()
        } else {
            "FUSE is not available. Load module with: sudo modprobe fuse".to_string()
        };
        return MountResult {
            success: false,
            mount: None,
            error: Some(msg),
            mount_point: local_mount_point.to_string(),
        };
    }

    // Validate remote path
    let validated_remote = match validate_remote_path(remote_path) {
        Ok(p) => p,
        Err(e) => {
            return MountResult {
                success: false,
                mount: None,
                error: Some(format!("Invalid remote path: {}", e)),
                mount_point: local_mount_point.to_string(),
            };
        }
    };

    // Validate local mount point
    let validated_local = match validate_local_mount_point(local_mount_point) {
        Ok(p) => p,
        Err(e) => {
            return MountResult {
                success: false,
                mount: None,
                error: Some(format!("Invalid mount point: {}", e)),
                mount_point: local_mount_point.to_string(),
            };
        }
    };

    // Check if already mounted
    if is_mount_point(&validated_local) {
        return MountResult {
            success: false,
            mount: None,
            error: Some(format!("{} is already a mount point", local_mount_point)),
            mount_point: local_mount_point.to_string(),
        };
    }

    // Ensure mount point directory exists
    if let Err(e) = ensure_directory_exists(&validated_local) {
        return MountResult {
            success: false,
            mount: None,
            error: Some(format!("Failed to create mount point: {}", e)),
            mount_point: local_mount_point.to_string(),
        };
    }

    // Check if directory is empty (sshfs requires empty directory)
    match is_directory_empty(&validated_local) {
        Ok(false) => {
            return MountResult {
                success: false,
                mount: None,
                error: Some(format!("Mount point {} is not empty", local_mount_point)),
                mount_point: local_mount_point.to_string(),
            };
        }
        Err(e) => {
            return MountResult {
                success: false,
                mount: None,
                error: Some(format!("Failed to check mount point: {}", e)),
                mount_point: local_mount_point.to_string(),
            };
        }
        Ok(true) => {}
    }

    // Build sshfs command
    let source = format!("{}@localhost:{}", username, validated_remote);
    let mut cmd = Command::new("sshfs");

    cmd.arg(&source)
        .arg(&validated_local);

    // SSH options for IAP tunnel (localhost connection)
    let ssh_port = options.ssh_port.unwrap_or(tunnel_port);
    cmd.arg("-p").arg(ssh_port.to_string());

    // Security options for localhost/IAP tunnel
    // StrictHostKeyChecking=no is safe here because we're connecting to localhost via IAP
    cmd.arg("-o").arg("StrictHostKeyChecking=no");
    cmd.arg("-o").arg("UserKnownHostsFile=/dev/null");
    cmd.arg("-o").arg("LogLevel=ERROR");

    // Identity file if specified
    if let Some(ref identity) = options.identity_file {
        cmd.arg("-o").arg(format!("IdentityFile={}", identity));
    }

    // Mount options
    if options.read_only {
        cmd.arg("-o").arg("ro");
    }

    if options.cache {
        cmd.arg("-o").arg("cache=yes");
        cmd.arg("-o").arg("kernel_cache");
        cmd.arg("-o").arg("auto_cache");
    } else {
        cmd.arg("-o").arg("cache=no");
    }

    if options.compression {
        cmd.arg("-o").arg("Compression=yes");
    }

    if options.reconnect {
        cmd.arg("-o").arg("reconnect");
        cmd.arg("-o").arg(format!("ServerAliveInterval={}", options.server_alive_interval));
        cmd.arg("-o").arg("ServerAliveCountMax=3");
    }

    if options.allow_other {
        cmd.arg("-o").arg("allow_other");
    }

    if options.follow_symlinks {
        cmd.arg("-o").arg("follow_symlinks");
    }

    // Additional useful options
    cmd.arg("-o").arg("default_permissions");
    cmd.arg("-o").arg("idmap=user");

    tracing::info!(
        "Mounting SSHFS: {} -> {} (port {})",
        source,
        validated_local.display(),
        ssh_port
    );

    // Execute mount command
    let output = cmd.output();

    match output {
        Ok(output) => {
            if output.status.success() {
                let mount_id = generate_mount_id(project_id, instance_name, &validated_remote);
                let mount = SshfsMount {
                    id: mount_id.clone(),
                    project_id: project_id.to_string(),
                    zone: zone.to_string(),
                    instance_name: instance_name.to_string(),
                    remote_path: validated_remote,
                    local_mount_point: validated_local.to_string_lossy().to_string(),
                    username: username.to_string(),
                    tunnel_port,
                    options,
                    is_active: true,
                    created_at: std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_secs() as i64,
                };

                // Register mount
                if let Ok(mut mounts) = ACTIVE_MOUNTS.lock() {
                    mounts.insert(mount_id, mount.clone());
                }

                tracing::info!("Mount successful: {}", validated_local.display());

                MountResult {
                    success: true,
                    mount: Some(mount),
                    error: None,
                    mount_point: validated_local.to_string_lossy().to_string(),
                }
            } else {
                let stderr = String::from_utf8_lossy(&output.stderr);
                let error_msg = if stderr.is_empty() {
                    "Mount failed with unknown error".to_string()
                } else {
                    format!("Mount failed: {}", stderr.trim())
                };

                tracing::error!("{}", error_msg);

                MountResult {
                    success: false,
                    mount: None,
                    error: Some(error_msg),
                    mount_point: local_mount_point.to_string(),
                }
            }
        }
        Err(e) => {
            let error_msg = format!("Failed to execute sshfs: {}", e);
            tracing::error!("{}", error_msg);

            MountResult {
                success: false,
                mount: None,
                error: Some(error_msg),
                mount_point: local_mount_point.to_string(),
            }
        }
    }
}

/// Unmount an SSHFS mount point
///
/// Uses fusermount -u for clean unmounting
pub fn unmount_sshfs(mount_point: &str) -> UnmountResult {
    let path = Path::new(mount_point);

    // Check if it's actually a mount point
    if !is_mount_point(path) {
        return UnmountResult {
            success: false,
            error: Some(format!("{} is not a mount point", mount_point)),
            mount_point: mount_point.to_string(),
        };
    }

    // Get fusermount command
    let fusermount = match get_fusermount_command() {
        Some(cmd) => cmd,
        None => {
            return UnmountResult {
                success: false,
                error: Some("fusermount not found. Install fuse utilities.".to_string()),
                mount_point: mount_point.to_string(),
            };
        }
    };

    tracing::info!("Unmounting: {}", mount_point);

    // Linux: fusermount -u <path>
    // macOS: umount <path>
    #[cfg(target_os = "macos")]
    let output = Command::new(&fusermount).arg(mount_point).output();

    #[cfg(not(target_os = "macos"))]
    let output = Command::new(&fusermount).arg("-u").arg(mount_point).output();

    match output {
        Ok(output) => {
            if output.status.success() {
                // Remove from registry
                if let Ok(mut mounts) = ACTIVE_MOUNTS.lock() {
                    mounts.retain(|_, m| m.local_mount_point != mount_point);
                }

                tracing::info!("Unmount successful: {}", mount_point);

                UnmountResult {
                    success: true,
                    error: None,
                    mount_point: mount_point.to_string(),
                }
            } else {
                let stderr = String::from_utf8_lossy(&output.stderr);

                // If busy, try force/lazy unmount
                if stderr.contains("busy") || stderr.contains("device is busy") {
                    tracing::warn!("Mount busy, trying force unmount");

                    // Linux: fusermount -uz (lazy unmount)
                    // macOS: umount -f  (force unmount)
                    #[cfg(target_os = "macos")]
                    let lazy_output = Command::new(&fusermount)
                        .arg("-f")
                        .arg(mount_point)
                        .output();

                    #[cfg(not(target_os = "macos"))]
                    let lazy_output = Command::new(&fusermount)
                        .arg("-uz")
                        .arg(mount_point)
                        .output();

                    if let Ok(lazy_out) = lazy_output {
                        if lazy_out.status.success() {
                            if let Ok(mut mounts) = ACTIVE_MOUNTS.lock() {
                                mounts.retain(|_, m| m.local_mount_point != mount_point);
                            }
                            return UnmountResult {
                                success: true,
                                error: None,
                                mount_point: mount_point.to_string(),
                            };
                        }
                    }
                }

                let error_msg = if stderr.is_empty() {
                    "Unmount failed with unknown error".to_string()
                } else {
                    format!("Unmount failed: {}", stderr.trim())
                };

                tracing::error!("{}", error_msg);

                UnmountResult {
                    success: false,
                    error: Some(error_msg),
                    mount_point: mount_point.to_string(),
                }
            }
        }
        Err(e) => {
            let error_msg = format!("Failed to execute fusermount: {}", e);
            tracing::error!("{}", error_msg);

            UnmountResult {
                success: false,
                error: Some(error_msg),
                mount_point: mount_point.to_string(),
            }
        }
    }
}

/// Unmount by mount ID
pub fn unmount_by_id(mount_id: &str) -> UnmountResult {
    let mount_point = {
        let mounts = ACTIVE_MOUNTS.lock().unwrap();
        mounts.get(mount_id).map(|m| m.local_mount_point.clone())
    };

    match mount_point {
        Some(mp) => unmount_sshfs(&mp),
        None => UnmountResult {
            success: false,
            error: Some(format!("Mount ID {} not found", mount_id)),
            mount_point: String::new(),
        },
    }
}

/// Get all active mounts
pub fn get_active_mounts() -> Vec<SshfsMount> {
    let mounts = ACTIVE_MOUNTS.lock().unwrap();
    mounts.values().cloned().collect()
}

/// Get active mounts for a specific instance
pub fn get_mounts_for_instance(project_id: &str, instance_name: &str) -> Vec<SshfsMount> {
    let mounts = ACTIVE_MOUNTS.lock().unwrap();
    mounts
        .values()
        .filter(|m| m.project_id == project_id && m.instance_name == instance_name)
        .cloned()
        .collect()
}

/// Check if a mount is still active (verify it's still mounted)
pub fn verify_mount_active(mount_id: &str) -> bool {
    let mounts = ACTIVE_MOUNTS.lock().unwrap();
    if let Some(mount) = mounts.get(mount_id) {
        is_mount_point(Path::new(&mount.local_mount_point))
    } else {
        false
    }
}

/// Refresh mount status (check all mounts and update their status)
pub fn refresh_mount_status() -> Vec<SshfsMount> {
    let mut mounts = ACTIVE_MOUNTS.lock().unwrap();

    // Update is_active status for all mounts
    for mount in mounts.values_mut() {
        mount.is_active = is_mount_point(Path::new(&mount.local_mount_point));
    }

    // Remove inactive mounts from registry
    mounts.retain(|_, m| m.is_active);

    mounts.values().cloned().collect()
}

/// Unmount all active mounts (for cleanup)
pub fn unmount_all() -> Vec<UnmountResult> {
    let mount_points: Vec<String> = {
        let mounts = ACTIVE_MOUNTS.lock().unwrap();
        mounts.values().map(|m| m.local_mount_point.clone()).collect()
    };

    mount_points
        .iter()
        .map(|mp| unmount_sshfs(mp))
        .collect()
}

/// Open mount in file manager
pub fn open_mount_in_file_manager(mount_id: &str, file_manager: Option<&str>) -> Result<()> {
    let mount_point = {
        let mounts = ACTIVE_MOUNTS.lock().unwrap();
        mounts.get(mount_id).map(|m| m.local_mount_point.clone())
    };

    match mount_point {
        Some(mp) => open_in_file_manager(Path::new(&mp), file_manager),
        None => Err(anyhow!("Mount ID {} not found", mount_id)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_get_sshfs_status() {
        let status = get_sshfs_status();
        // Just check that it returns without panic
        // Actual values depend on system
        println!("SSHFS installed: {}", status.installed);
        println!("FUSE available: {}", status.fuse_available);
    }

    #[test]
    fn test_active_mounts_registry() {
        // Clear registry
        {
            let mut mounts = ACTIVE_MOUNTS.lock().unwrap();
            mounts.clear();
        }

        // Get active mounts (should be empty)
        let mounts = get_active_mounts();
        assert!(mounts.is_empty());
    }
}
