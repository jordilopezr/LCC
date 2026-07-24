//! SSHFS Mount Module - Sprint 6
//!
//! Provides functionality to mount remote filesystems via SSHFS through IAP tunnels.
//!
//! Features:
//! - Detect sshfs installation (native and fuse)
//! - Mount remote directories to local mount points
//! - Manage multiple simultaneous mounts
//! - Clean unmount with fusermount
//! - Auto-reconnect options

mod mount;
mod utils;

pub use mount::*;
pub use utils::*;

use serde::{Deserialize, Serialize};

/// Mount options for SSHFS
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SshfsMountOptions {
    /// Read-only mount
    pub read_only: bool,
    /// Enable caching (improves performance but may show stale data)
    pub cache: bool,
    /// Enable compression (useful for slow connections)
    pub compression: bool,
    /// Auto-reconnect on connection loss
    pub reconnect: bool,
    /// Server alive interval in seconds (for reconnect)
    pub server_alive_interval: u32,
    /// Allow other users to access the mount (requires user_allow_other in /etc/fuse.conf)
    pub allow_other: bool,
    /// Follow symlinks on the server
    pub follow_symlinks: bool,
    /// Custom SSH port (default: 22)
    pub ssh_port: Option<u16>,
    /// SSH identity file path
    pub identity_file: Option<String>,
}

impl SshfsMountOptions {
    /// Create default options optimized for IAP tunnels
    pub fn default_for_iap() -> Self {
        Self {
            read_only: false,
            cache: true,
            compression: true,
            reconnect: true,
            server_alive_interval: 15,
            allow_other: false,
            follow_symlinks: true,
            ssh_port: None, // Will use tunnel port
            identity_file: None,
        }
    }
}

/// Represents an active SSHFS mount
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SshfsMount {
    /// Unique identifier for this mount
    pub id: String,
    /// GCP project ID
    pub project_id: String,
    /// GCP zone
    pub zone: String,
    /// VM instance name
    pub instance_name: String,
    /// Remote directory path (e.g., /home/user)
    pub remote_path: String,
    /// Local mount point (e.g., /home/localuser/mounts/vm-name)
    pub local_mount_point: String,
    /// SSH username for the connection
    pub username: String,
    /// Local tunnel port being used
    pub tunnel_port: u16,
    /// Mount options used
    pub options: SshfsMountOptions,
    /// Whether the mount is currently active
    pub is_active: bool,
    /// Timestamp when mount was created (Unix timestamp)
    pub created_at: i64,
}

/// Result of a mount operation
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MountResult {
    /// Whether the operation succeeded
    pub success: bool,
    /// The mount information (if successful)
    pub mount: Option<SshfsMount>,
    /// Error message (if failed)
    pub error: Option<String>,
    /// Mount point path
    pub mount_point: String,
}

/// Result of an unmount operation
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UnmountResult {
    /// Whether the operation succeeded
    pub success: bool,
    /// Error message (if failed)
    pub error: Option<String>,
    /// Mount point that was unmounted
    pub mount_point: String,
}

/// SSHFS installation status
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SshfsStatus {
    /// Whether sshfs is installed
    pub installed: bool,
    /// Whether FUSE is available
    pub fuse_available: bool,
    /// sshfs version string (if installed)
    pub version: Option<String>,
    /// Path to sshfs binary
    pub binary_path: Option<String>,
    /// Any issues detected
    pub issues: Vec<String>,
}

/// Information about available file managers
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileManagerInfo {
    pub name: String,
    pub command: String,
    pub is_installed: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_mount_options() {
        let opts = SshfsMountOptions::default();
        assert!(!opts.read_only);
        assert!(!opts.cache);
        assert!(!opts.compression);
    }

    #[test]
    fn test_iap_mount_options() {
        let opts = SshfsMountOptions::default_for_iap();
        assert!(opts.cache);
        assert!(opts.compression);
        assert!(opts.reconnect);
        assert_eq!(opts.server_alive_interval, 15);
    }

    #[test]
    fn test_sshfs_mount_serialization() {
        let mount = SshfsMount {
            id: "test-id".to_string(),
            project_id: "my-project".to_string(),
            zone: "us-central1-a".to_string(),
            instance_name: "my-vm".to_string(),
            remote_path: "/home/user".to_string(),
            local_mount_point: "/tmp/mounts/my-vm".to_string(),
            username: "testuser".to_string(),
            tunnel_port: 2222,
            options: SshfsMountOptions::default_for_iap(),
            is_active: true,
            created_at: 1234567890,
        };

        let json = serde_json::to_string(&mount).unwrap();
        let deserialized: SshfsMount = serde_json::from_str(&json).unwrap();

        assert_eq!(deserialized.instance_name, "my-vm");
        assert_eq!(deserialized.tunnel_port, 2222);
        assert!(deserialized.is_active);
    }
}
