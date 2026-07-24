pub mod remmina;
pub mod tigervnc;
pub mod krdc;
pub mod vinagre;
pub mod utils;

use anyhow::{Result, anyhow};
use tracing;

/// VNC Client Type - Auto-synced to Dart via Flutter Rust Bridge
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VncClientType {
    Remmina,
    TigerVnc,
    Krdc,
    Vinagre,
}

impl VncClientType {
    /// Get human-readable name
    pub fn display_name(&self) -> &'static str {
        match self {
            VncClientType::Remmina => "Remmina",
            VncClientType::TigerVnc => "TigerVNC (vncviewer)",
            VncClientType::Krdc => "KRDC",
            VncClientType::Vinagre => "Vinagre",
        }
    }

    /// Get default fallback priority order
    pub fn fallback_order() -> Vec<VncClientType> {
        #[cfg(target_os = "windows")]
        {
            vec![
                VncClientType::TigerVnc,     // Lightweight, popular
            ]
        }
        #[cfg(not(target_os = "windows"))]
        {
            vec![
                VncClientType::Remmina,      // Most feature-complete
                VncClientType::TigerVnc,     // Lightweight, popular
                VncClientType::Krdc,         // KDE default
                VncClientType::Vinagre,      // GNOME default
            ]
        }
    }

    /// Check if this client is available on the system
    pub fn is_available(&self) -> bool {
        match self {
            VncClientType::Remmina => remmina::is_available(),
            VncClientType::TigerVnc => tigervnc::is_available(),
            VncClientType::Krdc => krdc::is_available(),
            VncClientType::Vinagre => vinagre::is_available(),
        }
    }
}

/// VNC Quality Settings
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum VncQuality {
    High,      // Minimal compression, best quality
    #[default]
    Medium,    // Balanced
    Low,       // Maximum compression, lower quality
    Auto,      // Let client decide
}

/// VNC connection settings
#[derive(Debug, Clone)]
pub struct VncSettings {
    pub password: Option<String>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub fullscreen: bool,
    /// View-only mode (read-only access, no keyboard/mouse input)
    pub view_only: bool,
    /// Quality/compression level
    pub quality: VncQuality,
    /// User's preferred VNC client
    pub client_type: VncClientType,
}

impl Default for VncSettings {
    fn default() -> Self {
        Self {
            password: None,
            width: None,
            height: None,
            fullscreen: false,
            view_only: false,
            quality: VncQuality::Medium,
            // Default to TigerVnc on Windows, Remmina elsewhere
            client_type: if cfg!(target_os = "windows") {
                VncClientType::TigerVnc
            } else {
                VncClientType::Remmina
            },
        }
    }
}

/// Result of VNC launch attempt
#[derive(Debug, Clone)]
pub struct VncLaunchResult {
    pub client_used: VncClientType,
    pub fallback_occurred: bool,
}

/// Main dispatcher - tries user's preferred client first, then falls back
pub fn launch_vnc_client(
    port: u16,
    instance_name: &str,
    settings: VncSettings,
) -> Result<VncLaunchResult> {
    let preferred = settings.client_type;

    tracing::info!(
        instance_name = instance_name,
        port = port,
        preferred_client = ?preferred,
        "Launching VNC client"
    );

    // Try preferred client first
    if preferred.is_available() {
        match try_launch_client(preferred, port, instance_name, &settings) {
            Ok(_) => {
                tracing::info!(client = ?preferred, "VNC client launched successfully");
                return Ok(VncLaunchResult {
                    client_used: preferred,
                    fallback_occurred: false,
                });
            }
            Err(e) => {
                tracing::warn!(
                    client = ?preferred,
                    error = %e,
                    "Preferred client failed, trying fallbacks"
                );
            }
        }
    } else {
        tracing::warn!(
            client = ?preferred,
            "Preferred client not available, trying fallbacks"
        );
    }

    // Try fallback clients in priority order
    let fallbacks = VncClientType::fallback_order()
        .into_iter()
        .filter(|c| *c != preferred); // Skip the one we already tried

    for client in fallbacks {
        if !client.is_available() {
            tracing::debug!(client = ?client, "Client not available, skipping");
            continue;
        }

        match try_launch_client(client, port, instance_name, &settings) {
            Ok(_) => {
                tracing::info!(
                    preferred = ?preferred,
                    fallback = ?client,
                    "VNC client launched using fallback"
                );
                return Ok(VncLaunchResult {
                    client_used: client,
                    fallback_occurred: true,
                });
            }
            Err(e) => {
                tracing::warn!(client = ?client, error = %e, "Fallback client failed");
                continue;
            }
        }
    }

    // All attempts failed
    Err(anyhow!(
        "No VNC clients available. Please install one of: Remmina, TigerVNC, KRDC, or Vinagre"
    ))
}

/// Try to launch a specific client
fn try_launch_client(
    client: VncClientType,
    port: u16,
    instance_name: &str,
    settings: &VncSettings,
) -> Result<()> {
    match client {
        VncClientType::Remmina => remmina::launch(port, instance_name, settings),
        VncClientType::TigerVnc => tigervnc::launch(port, instance_name, settings),
        VncClientType::Krdc => krdc::launch(port, instance_name, settings),
        VncClientType::Vinagre => vinagre::launch(port, instance_name, settings),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_fallback_order() {
        let order = VncClientType::fallback_order();
        #[cfg(target_os = "windows")]
        {
            assert_eq!(order[0], VncClientType::TigerVnc);
            assert_eq!(order.len(), 1);
        }
        #[cfg(not(target_os = "windows"))]
        {
            assert_eq!(order[0], VncClientType::Remmina);
            assert_eq!(order.len(), 4);
        }
    }

    #[test]
    fn test_vnc_settings_default() {
        let settings = VncSettings::default();
        #[cfg(target_os = "windows")]
        assert_eq!(settings.client_type, VncClientType::TigerVnc);
        #[cfg(not(target_os = "windows"))]
        assert_eq!(settings.client_type, VncClientType::Remmina);
        assert_eq!(settings.fullscreen, false);
        assert_eq!(settings.view_only, false);
        assert_eq!(settings.quality, VncQuality::Medium);
    }

    #[test]
    fn test_client_display_names() {
        assert_eq!(VncClientType::Remmina.display_name(), "Remmina");
        assert_eq!(VncClientType::TigerVnc.display_name(), "TigerVNC (vncviewer)");
        assert_eq!(VncClientType::Krdc.display_name(), "KRDC");
        assert_eq!(VncClientType::Vinagre.display_name(), "Vinagre");
    }

    #[test]
    fn test_quality_default() {
        let quality = VncQuality::default();
        assert_eq!(quality, VncQuality::Medium);
    }
}
