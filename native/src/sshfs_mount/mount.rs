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
    let ssh_port = options.ssh_port.unwrap_or(tunnel_port);
    let mut cmd = Command::new("sshfs");
    cmd.args(sshfs_args(
        &source,
        &validated_local.to_string_lossy(),
        ssh_port,
        &options,
    ));

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

/// The full `sshfs` argument list. Pure, so the option combinations can be
/// asserted without mounting anything.
fn sshfs_args(
    source: &str,
    mount_point: &str,
    ssh_port: u16,
    options: &SshfsMountOptions,
) -> Vec<String> {
    let mut args: Vec<String> = vec![source.to_string(), mount_point.to_string()];
    let mut opt = |v: String| {
        args.push("-o".to_string());
        args.push(v);
    };

    // Security options for localhost/IAP tunnel.
    // StrictHostKeyChecking=no is safe here because we connect to localhost via IAP.
    opt("StrictHostKeyChecking=no".to_string());
    opt("UserKnownHostsFile=/dev/null".to_string());
    opt("LogLevel=ERROR".to_string());

    if let Some(identity) = &options.identity_file {
        opt(format!("IdentityFile={}", identity));
        // Without this, `ssh` offers every agent identity before ours and
        // `sshd` disconnects at MaxAuthTries (6 by default) — the key would be
        // authorised on the VM and never actually presented to it.
        opt("IdentitiesOnly=yes".to_string());
    }

    if options.read_only {
        opt("ro".to_string());
    }

    if options.cache {
        opt("cache=yes".to_string());
        opt("kernel_cache".to_string());
        opt("auto_cache".to_string());
    } else {
        opt("cache=no".to_string());
    }

    if options.compression {
        opt("Compression=yes".to_string());
    }

    if options.reconnect {
        opt("reconnect".to_string());
        opt(format!("ServerAliveInterval={}", options.server_alive_interval));
        opt("ServerAliveCountMax=3".to_string());
    }

    if options.allow_other {
        opt("allow_other".to_string());
    }

    if options.follow_symlinks {
        opt("follow_symlinks".to_string());
    }

    opt("default_permissions".to_string());
    opt("idmap=user".to_string());

    // The port flag is not an `-o` option.
    args.push("-p".to_string());
    args.push(ssh_port.to_string());
    args
}

#[cfg(test)]
mod tests {
    use super::*;

    fn opts() -> SshfsMountOptions {
        SshfsMountOptions {
            read_only: false,
            cache: true,
            compression: true,
            reconnect: true,
            server_alive_interval: 15,
            allow_other: false,
            follow_symlinks: true,
            ssh_port: None,
            identity_file: None,
        }
    }

    /// An identity file is useless to `sshfs` on its own: it shells out to the
    /// system `ssh`, which offers every agent identity FIRST. `sshd` disconnects
    /// after `MaxAuthTries` (6 by default), so a populated agent exhausts the
    /// budget before LCC's key is ever presented — the key would be authorised
    /// on the VM and never reach it. `IdentitiesOnly=yes` is what makes the
    /// `-o IdentityFile` actually decisive.
    #[test]
    fn an_identity_file_is_paired_with_identities_only() {
        let mut o = opts();
        o.identity_file = Some("/home/u/.local/share/lcc/ssh/lcc_ed25519".to_string());
        let args = sshfs_args("u@localhost:/home", "/mnt/x", 40000, &o);

        assert!(
            args.iter().any(|a| a == "IdentityFile=/home/u/.local/share/lcc/ssh/lcc_ed25519"),
            "falta el IdentityFile: {:?}",
            args
        );
        assert!(
            args.iter().any(|a| a == "IdentitiesOnly=yes"),
            "sin IdentitiesOnly el agente agota MaxAuthTries antes de ofrecer la clave: {:?}",
            args
        );
    }

    /// Without a key we must NOT pin identities: that would break every user
    /// who authenticates through their agent, which is the common case.
    #[test]
    fn without_an_identity_file_identities_are_not_pinned() {
        let args = sshfs_args("u@localhost:/home", "/mnt/x", 40000, &opts());
        assert!(
            !args.iter().any(|a| a == "IdentitiesOnly=yes"),
            "no debe fijar identidades sin clave propia: {:?}",
            args
        );
    }

    #[test]
    fn the_source_and_mount_point_come_first_and_the_port_is_passed() {
        let args = sshfs_args("u@localhost:/home", "/mnt/x", 40123, &opts());
        assert_eq!(args[0], "u@localhost:/home");
        assert_eq!(args[1], "/mnt/x");
        let p = args.iter().position(|a| a == "-p").expect("falta -p");
        assert_eq!(args[p + 1], "40123");
    }

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
