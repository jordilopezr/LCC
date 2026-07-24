use std::process::Command;
use anyhow::{Result, anyhow};
use tracing;
use super::VncQuality;

/// Check if a command exists in PATH (native or flatpak)
pub fn command_exists(cmd: &str) -> bool {
    #[cfg(target_os = "windows")]
    let program = "where";
    #[cfg(not(target_os = "windows"))]
    let program = "which";

    Command::new(program)
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

/// Build VNC URI (vnc://host:port)
pub fn build_vnc_uri(port: u16) -> String {
    format!("vnc://127.0.0.1:{}", port)
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

/// Convert VncQuality to Remmina quality level (0-2)
/// Remmina quality mapping: 0=poor, 1=medium, 2=good
pub fn quality_to_remmina(quality: VncQuality) -> &'static str {
    match quality {
        VncQuality::High => "2",    // Good
        VncQuality::Medium => "1",  // Medium
        VncQuality::Low => "0",     // Poor
        VncQuality::Auto => "1",    // Default to medium
    }
}

/// Convert VncQuality to TigerVNC quality level (0-9)
/// Higher values mean better quality
pub fn quality_to_tigervnc(quality: VncQuality) -> &'static str {
    match quality {
        VncQuality::High => "8",    // High quality (low compression)
        VncQuality::Medium => "5",  // Medium quality/compression
        VncQuality::Low => "2",     // Low quality (high compression, fast)
        VncQuality::Auto => "5",    // Default to medium
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_build_vnc_uri() {
        assert_eq!(build_vnc_uri(5900), "vnc://127.0.0.1:5900");
        assert_eq!(build_vnc_uri(5901), "vnc://127.0.0.1:5901");
    }

    #[test]
    fn test_quality_to_remmina() {
        assert_eq!(quality_to_remmina(VncQuality::High), "2");
        assert_eq!(quality_to_remmina(VncQuality::Medium), "1");
        assert_eq!(quality_to_remmina(VncQuality::Low), "0");
        assert_eq!(quality_to_remmina(VncQuality::Auto), "1");
    }

    #[test]
    fn test_quality_to_tigervnc() {
        assert_eq!(quality_to_tigervnc(VncQuality::High), "8");
        assert_eq!(quality_to_tigervnc(VncQuality::Medium), "5");
        assert_eq!(quality_to_tigervnc(VncQuality::Low), "2");
        assert_eq!(quality_to_tigervnc(VncQuality::Auto), "5");
    }
}
