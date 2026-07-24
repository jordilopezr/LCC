use std::process::Command;
use anyhow::{Result, anyhow};
use tracing;

/// Check if a command exists in PATH (native or flatpak)
pub fn command_exists(cmd: &str) -> bool {
    Command::new("which")
        .arg(cmd)
        .output()
        .map(|output| output.status.success())
        .unwrap_or(false)
}

/// Check if a flatpak app is installed
pub fn flatpak_exists(app_id: &str) -> bool {
    Command::new("flatpak")
        .args(["list", "--app", "--columns=application"])
        .output()
        .map(|output| {
            String::from_utf8_lossy(&output.stdout)
                .lines()
                .any(|line| line.trim() == app_id)
        })
        .unwrap_or(false)
}

/// Build RDP URI (rdp://[user@]host:port)
pub fn build_rdp_uri(port: u16, username: Option<&str>) -> String {
    match username {
        Some(user) if !user.is_empty() => format!("rdp://{}@127.0.0.1:{}", user, port),
        _ => format!("rdp://127.0.0.1:{}", port),
    }
}

/// Create secure temp directory for config files
pub fn get_config_dir() -> Result<std::path::PathBuf> {
    let base = dirs::cache_dir()
        .ok_or_else(|| anyhow!("Could not determine cache directory"))?;
    let config_dir = crate::app_dirs::migrated_app_dir(base);

    if !config_dir.exists() {
        std::fs::create_dir_all(&config_dir)?;
    }

    Ok(config_dir)
}

/// Set file permissions to 0600 (owner read/write only) for security
#[cfg(unix)]
pub fn set_secure_permissions(path: &std::path::Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    tracing::debug!("Secure permissions (0600) set on file: {:?}", path);
    Ok(())
}

#[cfg(not(unix))]
pub fn set_secure_permissions(_path: &std::path::Path) -> Result<()> {
    Ok(())
}

/// Maximum age for temporary config files (in seconds)
/// Files older than this will be cleaned up automatically
const MAX_CONFIG_AGE_SECS: u64 = 3600; // 1 hour

/// Clean up old temporary configuration files
///
/// This function removes Remmina config files (.remmina) that are older than
/// MAX_CONFIG_AGE_SECS to prevent accumulation of sensitive configuration data
/// on disk.
///
/// # Security
/// This is a security measure to minimize the window during which temporary
/// credentials or configuration data could be exposed on disk.
///
/// # Returns
/// - `Ok(count)` - Number of files cleaned up
/// - `Err(_)` - If the config directory cannot be accessed
pub fn cleanup_old_config_files() -> Result<usize> {
    let config_dir = get_config_dir()?;

    if !config_dir.exists() {
        return Ok(0);
    }

    let entries = std::fs::read_dir(&config_dir)
        .map_err(|e| anyhow!("Failed to read config directory: {}", e))?;

    let now = std::time::SystemTime::now();
    let max_age = std::time::Duration::from_secs(MAX_CONFIG_AGE_SECS);
    let mut cleaned = 0;

    for entry in entries.flatten() {
        let path = entry.path();

        // Only process .remmina files (our temporary configs)
        if path.extension().and_then(|e| e.to_str()) != Some("remmina") {
            continue;
        }

        // Check file age
        if let Ok(metadata) = std::fs::metadata(&path) {
            if let Ok(modified) = metadata.modified() {
                if let Ok(age) = now.duration_since(modified) {
                    if age > max_age {
                        // File is old enough to clean up
                        if let Err(e) = std::fs::remove_file(&path) {
                            tracing::warn!(
                                path = ?path,
                                error = %e,
                                "Failed to remove old config file"
                            );
                        } else {
                            tracing::debug!(
                                path = ?path,
                                age_secs = age.as_secs(),
                                "Cleaned up old config file"
                            );
                            cleaned += 1;
                        }
                    }
                }
            }
        }
    }

    if cleaned > 0 {
        tracing::info!(
            count = cleaned,
            "Cleaned up old RDP configuration files"
        );
    }

    Ok(cleaned)
}

/// Remove a specific config file by instance name
///
/// This function is called when a connection is closed to remove the
/// temporary configuration file immediately rather than waiting for cleanup.
///
/// # Arguments
/// * `instance_name` - The name of the instance whose config should be removed
pub fn remove_config_file(instance_name: &str) -> Result<()> {
    let config_dir = get_config_dir()?;
    let file_path = config_dir.join(format!("iap_{}.remmina", instance_name));

    if file_path.exists() {
        std::fs::remove_file(&file_path)
            .map_err(|e| anyhow!("Failed to remove config file: {}", e))?;
        tracing::debug!(
            instance_name = instance_name,
            "Removed temporary config file"
        );
    }

    Ok(())
}
