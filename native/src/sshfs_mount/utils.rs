//! SSHFS Utilities
//!
//! Helper functions for SSHFS operations including:
//! - Binary detection (sshfs, fusermount / umount)
//! - Path validation and sanitization
//! - File manager detection and launching

use anyhow::{Result, anyhow};
use std::path::{Path, PathBuf};
use std::process::Command;
use tracing;

use super::{SshfsStatus, FileManagerInfo};

/// Check if sshfs is installed and get its status
pub fn get_sshfs_status() -> SshfsStatus {
    let mut status = SshfsStatus {
        installed: false,
        fuse_available: false,
        version: None,
        binary_path: None,
        issues: Vec::new(),
    };

    tracing::info!("Checking SSHFS status...");

    // Check for sshfs binary
    if let Some(path) = find_binary("sshfs") {
        status.installed = true;
        status.binary_path = Some(path.clone());
        tracing::info!("SSHFS found at: {}", path);

        // Get version (sshfs outputs version to stderr)
        if let Ok(output) = Command::new("sshfs").arg("--version").output() {
            let version_str = String::from_utf8_lossy(&output.stdout);
            let stderr_str = String::from_utf8_lossy(&output.stderr);
            let version = if !stderr_str.is_empty() {
                stderr_str.lines().next().map(|s| s.to_string())
            } else {
                version_str.lines().next().map(|s| s.to_string())
            };
            status.version = version;
        }
    } else {
        let install_msg = if cfg!(target_os = "macos") {
            "sshfs is not installed. Install with: brew install macfuse sshfs-mac"
        } else if cfg!(target_os = "linux") {
            "sshfs is not installed. Install with: sudo apt install sshfs (Debian/Ubuntu) or sudo dnf install fuse-sshfs (Fedora)"
        } else {
            "sshfs is not installed."
        };
        status.issues.push(install_msg.to_string());
    }

    // Check for FUSE device
    if Path::new("/dev/fuse").exists() {
        status.fuse_available = true;
    } else {
        let fuse_msg = if cfg!(target_os = "macos") {
            "FUSE is not available. Install macFUSE from https://osxfuse.github.io/"
        } else {
            "FUSE device not available. You may need to load the fuse module: sudo modprobe fuse"
        };
        status.issues.push(fuse_msg.to_string());
    }

    // Check for unmount tool
    let has_unmount_tool = if cfg!(target_os = "macos") {
        find_binary("umount").is_some()
    } else {
        find_binary("fusermount").is_some() || find_binary("fusermount3").is_some()
    };

    if !has_unmount_tool {
        status.issues.push("FUSE unmount tool not found. Install fuse utilities.".to_string());
    }

    // Linux-only: check user_allow_other in fuse.conf
    #[cfg(target_os = "linux")]
    if let Ok(content) = std::fs::read_to_string("/etc/fuse.conf") {
        if !content.lines().any(|line| {
            let trimmed = line.trim();
            trimmed == "user_allow_other" || trimmed.starts_with("user_allow_other")
        }) {
            tracing::debug!("user_allow_other not enabled in /etc/fuse.conf");
        }
    }

    status
}

/// Find a binary in PATH.
///
/// First tries `which`, then falls back to checking standard system paths.
/// Handles cases where the app is launched from a desktop environment
/// with a minimal PATH that might not include all standard directories.
pub fn find_binary(name: &str) -> Option<String> {
    // Try `which` first
    if let Some(path) = Command::new("which")
        .arg(name)
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|s| !s.is_empty())
    {
        return Some(path);
    }

    // Fallback: check standard paths directly
    let mut standard_dirs: Vec<&str> = vec![
        "/usr/bin",
        "/usr/local/bin",
        "/usr/sbin",
        "/sbin",
        "/bin",
    ];

    #[cfg(target_os = "linux")]
    standard_dirs.push("/snap/bin");

    #[cfg(target_os = "macos")]
    {
        standard_dirs.push("/opt/homebrew/bin");
        standard_dirs.push("/opt/homebrew/sbin");
    }

    for dir in &standard_dirs {
        let full_path = format!("{}/{}", dir, name);
        if Path::new(&full_path).exists() {
            tracing::info!("Found {} at {} (fallback path search)", name, full_path);
            return Some(full_path);
        }
    }

    None
}

/// Get the command used to unmount FUSE filesystems.
///
/// - Linux: `fusermount3` or `fusermount`
/// - macOS: `umount`
pub fn get_fusermount_command() -> Option<String> {
    if cfg!(target_os = "macos") {
        find_binary("umount")
    } else {
        find_binary("fusermount3").or_else(|| find_binary("fusermount"))
    }
}

/// Check if a path is a FUSE mount point.
///
/// - Linux: uses `findmnt --target`
/// - macOS: compares device IDs of the path and its parent
pub fn is_mount_point(path: &Path) -> bool {
    #[cfg(target_os = "macos")]
    {
        use std::os::unix::fs::MetadataExt;
        let path_dev = std::fs::metadata(path).map(|m| m.dev()).unwrap_or(0);
        let parent = path.parent().unwrap_or(path);
        let parent_dev = std::fs::metadata(parent).map(|m| m.dev()).unwrap_or(0);
        // A different device ID means it's a mount point
        path_dev != 0 && path_dev != parent_dev
    }
    #[cfg(not(target_os = "macos"))]
    {
        Command::new("findmnt")
            .arg("--target")
            .arg(path)
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false)
    }
}

/// Validate and sanitize a remote path.
///
/// Security: prevents path traversal attacks and ensures valid paths.
pub fn validate_remote_path(path: &str) -> Result<String> {
    if !path.starts_with('/') {
        return Err(anyhow!("Remote path must be absolute (start with /)"));
    }
    if path.contains("..") {
        return Err(anyhow!("Path traversal (..) is not allowed"));
    }
    if path.contains('\0') {
        return Err(anyhow!("Invalid characters in path"));
    }

    let normalized: String = path
        .split('/')
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join("/");

    Ok(format!("/{}", normalized))
}

/// Validate a local mount point.
///
/// Security: ensures the mount point is in a user-writable location.
pub fn validate_local_mount_point(path: &str) -> Result<PathBuf> {
    if path.contains('\0') {
        return Err(anyhow!("Invalid characters in mount point path"));
    }
    let path = PathBuf::from(path);

    if !path.is_absolute() {
        return Err(anyhow!("Mount point must be an absolute path"));
    }
    if path.to_string_lossy().contains("..") {
        return Err(anyhow!("Path traversal (..) is not allowed"));
    }

    // Forbidden system directories
    let forbidden = [
        "/", "/bin", "/sbin", "/usr", "/lib", "/lib64", "/lib32",
        "/etc", "/var", "/boot", "/dev", "/proc", "/sys", "/run",
        "/root", "/snap",
    ];

    let path_str = path.to_string_lossy();
    for forbidden_path in &forbidden {
        if path_str == *forbidden_path
            || path_str.starts_with(&format!("{}/", forbidden_path))
        {
            if path_str.starts_with("/var/run/user/") || path_str.starts_with("/run/user/") {
                continue;
            }
            return Err(anyhow!("Cannot mount to system directory: {}", forbidden_path));
        }
    }

    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());

    let mut allowed_prefixes: Vec<&str> = vec![home.as_str(), "/tmp"];

    #[cfg(target_os = "macos")]
    {
        allowed_prefixes.push("/Volumes");
        allowed_prefixes.push("/private/tmp");
    }

    #[cfg(not(target_os = "macos"))]
    {
        allowed_prefixes.push("/home");
        allowed_prefixes.push("/mnt");
        allowed_prefixes.push("/media");
    }

    let is_allowed = allowed_prefixes.iter().any(|prefix| path_str.starts_with(prefix));
    if !is_allowed {
        let locations = if cfg!(target_os = "macos") {
            "home directory, /tmp, or /Volumes"
        } else {
            "home directory, /tmp, /mnt, or /media"
        };
        return Err(anyhow!(
            "Mount point must be in a user-writable location ({})",
            locations
        ));
    }

    Ok(path)
}

/// Create a default mount point path for a VM.
pub fn get_default_mount_point(instance_name: &str, remote_path: &str) -> Result<PathBuf> {
    let home = std::env::var("HOME")
        .map_err(|_| anyhow!("HOME environment variable not set"))?;

    let safe_remote = remote_path
        .trim_start_matches('/')
        .replace('/', "_")
        .chars()
        .filter(|c| c.is_alphanumeric() || *c == '_' || *c == '-')
        .collect::<String>();

    let mount_dir = if safe_remote.is_empty() {
        format!("{}/gcp-mounts/{}", home, instance_name)
    } else {
        format!("{}/gcp-mounts/{}_{}", home, instance_name, safe_remote)
    };

    Ok(PathBuf::from(mount_dir))
}

/// Ensure a directory exists, creating it if necessary.
pub fn ensure_directory_exists(path: &Path) -> Result<()> {
    if !path.exists() {
        std::fs::create_dir_all(path)
            .map_err(|e| anyhow!("Failed to create directory {}: {}", path.display(), e))?;
        tracing::info!("Created mount point directory: {}", path.display());
    } else if !path.is_dir() {
        return Err(anyhow!("{} exists but is not a directory", path.display()));
    }
    Ok(())
}

/// Check if a directory is empty.
pub fn is_directory_empty(path: &Path) -> Result<bool> {
    let entries = std::fs::read_dir(path)
        .map_err(|e| anyhow!("Failed to read directory {}: {}", path.display(), e))?;
    Ok(entries.count() == 0)
}

/// Get list of available file managers on the current platform.
pub fn get_available_file_managers() -> Vec<FileManagerInfo> {
    #[cfg(target_os = "macos")]
    let file_managers: Vec<(&str, &str)> = vec![
        ("Finder", "open"),
    ];

    #[cfg(not(target_os = "macos"))]
    let file_managers: Vec<(&str, &str)> = vec![
        ("Nautilus (GNOME Files)", "nautilus"),
        ("Dolphin (KDE)", "dolphin"),
        ("Thunar (Xfce)", "thunar"),
        ("Nemo (Cinnamon)", "nemo"),
        ("PCManFM", "pcmanfm"),
        ("Caja (MATE)", "caja"),
        ("xdg-open", "xdg-open"),
    ];

    file_managers
        .into_iter()
        .map(|(name, cmd)| {
            let is_installed = find_binary(cmd).is_some();
            FileManagerInfo {
                name: name.to_string(),
                command: cmd.to_string(),
                is_installed,
            }
        })
        .collect()
}

/// Get the default file manager command.
pub fn get_default_file_manager() -> Option<String> {
    #[cfg(target_os = "macos")]
    {
        // `open` is always available on macOS
        return Some("open".to_string());
    }

    #[cfg(not(target_os = "macos"))]
    {
        let priority = ["nautilus", "dolphin", "thunar", "nemo", "pcmanfm", "caja", "xdg-open"];
        for cmd in priority {
            if find_binary(cmd).is_some() {
                return Some(cmd.to_string());
            }
        }
        None
    }
}

/// Open a directory in the file manager.
pub fn open_in_file_manager(path: &Path, file_manager: Option<&str>) -> Result<()> {
    let fm = match file_manager {
        Some(fm) => fm.to_string(),
        None => get_default_file_manager()
            .ok_or_else(|| anyhow!("No file manager found"))?,
    };

    tracing::info!("Opening {} in {}", path.display(), fm);

    Command::new(&fm)
        .arg(path)
        .spawn()
        .map_err(|e| anyhow!("Failed to open file manager {}: {}", fm, e))?;

    Ok(())
}

/// Generate a unique mount ID.
pub fn generate_mount_id(project_id: &str, instance_name: &str, remote_path: &str) -> String {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};

    let mut hasher = DefaultHasher::new();
    project_id.hash(&mut hasher);
    instance_name.hash(&mut hasher);
    remote_path.hash(&mut hasher);
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
        .hash(&mut hasher);

    format!("mount-{:016x}", hasher.finish())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_validate_remote_path_valid() {
        assert!(validate_remote_path("/home/user").is_ok());
        assert!(validate_remote_path("/").is_ok());
        assert!(validate_remote_path("/var/log/app").is_ok());
    }

    #[test]
    fn test_validate_remote_path_invalid() {
        assert!(validate_remote_path("home/user").is_err());
        assert!(validate_remote_path("/home/../etc").is_err());
        assert!(validate_remote_path("/home/user\0/file").is_err());
    }

    #[test]
    fn test_validate_local_mount_point_forbidden() {
        assert!(validate_local_mount_point("/etc").is_err());
        assert!(validate_local_mount_point("/usr/bin").is_err());
        assert!(validate_local_mount_point("/").is_err());
    }

    #[test]
    fn test_validate_local_mount_point_allowed() {
        assert!(validate_local_mount_point("/tmp/test").is_ok());
        #[cfg(not(target_os = "macos"))]
        {
            assert!(validate_local_mount_point("/mnt/sshfs").is_ok());
            assert!(validate_local_mount_point("/media/user/mount").is_ok());
        }
        #[cfg(target_os = "macos")]
        assert!(validate_local_mount_point("/Volumes/sshfs").is_ok());
    }

    #[test]
    fn test_generate_mount_id() {
        let id1 = generate_mount_id("project", "vm1", "/home");
        let id2 = generate_mount_id("project", "vm2", "/home");
        assert_ne!(id1, id2);
        assert!(id1.starts_with("mount-"));
    }

    #[test]
    fn test_get_default_mount_point() {
        // No mutar HOME: env::set_var es global al proceso y rompe los tests
        // que lanzan gcloud en paralelo. Las aserciones no dependen del valor.
        let path = get_default_mount_point("my-vm", "/home/user").unwrap();
        assert!(path.to_string_lossy().contains("my-vm"));
        assert!(path.to_string_lossy().contains("gcp-mounts"));
    }
}
