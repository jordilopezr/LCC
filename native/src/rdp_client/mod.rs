pub mod remmina;
pub mod freerdp;
pub mod krdc;
pub mod gnome_connections;
pub mod mstsc;
pub mod utils;

use anyhow::{Result, anyhow};
use tracing;

// Re-export cleanup utilities for use from API
pub use utils::{cleanup_old_config_files, remove_config_file};

/// RDP Client Type - Auto-synced to Dart via Flutter Rust Bridge
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RdpClientType {
    Remmina,
    FreeRdp,
    Krdc,
    GnomeConnections,
    Mstsc,
}

impl RdpClientType {
    /// Get human-readable name
    pub fn display_name(&self) -> &'static str {
        match self {
            RdpClientType::Remmina => "Remmina",
            RdpClientType::FreeRdp => "FreeRDP (xfreerdp)",
            RdpClientType::Krdc => "KRDC",
            RdpClientType::GnomeConnections => "GNOME Connections",
            RdpClientType::Mstsc => "Microsoft Remote Desktop (mstsc)",
        }
    }

    /// Get default fallback priority order
    pub fn fallback_order() -> Vec<RdpClientType> {
        #[cfg(target_os = "windows")]
        {
            vec![
                RdpClientType::Mstsc,        // Windows native
            ]
        }
        #[cfg(not(target_os = "windows"))]
        {
            vec![
                RdpClientType::Remmina,      // Most feature-complete
                RdpClientType::FreeRdp,      // Widely available, CLI-based
                RdpClientType::Krdc,         // KDE default
                RdpClientType::GnomeConnections, // GNOME default
            ]
        }
    }

    /// Check if this client is available on the system
    pub fn is_available(&self) -> bool {
        match self {
            RdpClientType::Remmina => remmina::is_available(),
            RdpClientType::FreeRdp => freerdp::is_available(),
            RdpClientType::Krdc => krdc::is_available(),
            RdpClientType::GnomeConnections => gnome_connections::is_available(),
            RdpClientType::Mstsc => mstsc::is_available(),
        }
    }
}

/// Extended RDP settings with client selection
#[derive(Debug, Clone)]
pub struct RdpSettings {
    pub username: Option<String>,
    pub password: Option<String>,
    pub domain: Option<String>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub fullscreen: bool,
    /// Whether to ignore certificate validation errors
    /// Default: false (validate certificates for security)
    /// Set to true only if connecting to trusted hosts with self-signed certs
    pub ignore_certificate: bool,
    /// User's preferred RDP client
    pub client_type: RdpClientType,
}

impl Default for RdpSettings {
    fn default() -> Self {
        Self {
            username: None,
            password: None,
            domain: None,
            width: None,
            height: None,
            fullscreen: false,
            // SECURITY: Default to validating certificates
            ignore_certificate: false,
            // Default to Mstsc on Windows, Remmina elsewhere
            client_type: if cfg!(target_os = "windows") {
                RdpClientType::Mstsc
            } else {
                RdpClientType::Remmina
            },
        }
    }
}

/// Result of RDP launch attempt
#[derive(Debug, Clone)]
pub struct RdpLaunchResult {
    pub client_used: RdpClientType,
    pub fallback_occurred: bool,
}

/// Main dispatcher - tries user's preferred client first, then falls back
pub fn launch_rdp_client(
    port: u16,
    instance_name: &str,
    settings: RdpSettings,
) -> Result<RdpLaunchResult> {
    let preferred = settings.client_type;

    tracing::info!(
        instance_name = instance_name,
        port = port,
        preferred_client = ?preferred,
        "Launching RDP client"
    );

    // Try preferred client first
    if preferred.is_available() {
        match try_launch_client(preferred, port, instance_name, &settings) {
            Ok(_) => {
                tracing::info!(client = ?preferred, "RDP client launched successfully");
                return Ok(RdpLaunchResult {
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
    let fallbacks = RdpClientType::fallback_order()
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
                    "RDP client launched using fallback"
                );
                return Ok(RdpLaunchResult {
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
        "No RDP clients available. Please install one of: Remmina, FreeRDP, KRDC, or GNOME Connections"
    ))
}

/// Try to launch a specific client
fn try_launch_client(
    client: RdpClientType,
    port: u16,
    instance_name: &str,
    settings: &RdpSettings,
) -> Result<()> {
    match client {
        RdpClientType::Remmina => remmina::launch(port, instance_name, settings),
        RdpClientType::FreeRdp => freerdp::launch(port, instance_name, settings),
        RdpClientType::Krdc => krdc::launch(port, instance_name, settings),
        RdpClientType::GnomeConnections => gnome_connections::launch(port, instance_name, settings),
        RdpClientType::Mstsc => mstsc::launch(port, instance_name, settings),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_fallback_order() {
        let order = RdpClientType::fallback_order();
        #[cfg(target_os = "windows")]
        {
            assert_eq!(order[0], RdpClientType::Mstsc);
            assert_eq!(order.len(), 1);
        }
        #[cfg(not(target_os = "windows"))]
        {
            assert_eq!(order[0], RdpClientType::Remmina);
            assert_eq!(order.len(), 4);
        }
    }

    #[test]
    fn test_rdp_settings_default() {
        let settings = RdpSettings::default();
        #[cfg(target_os = "windows")]
        assert_eq!(settings.client_type, RdpClientType::Mstsc);
        #[cfg(not(target_os = "windows"))]
        assert_eq!(settings.client_type, RdpClientType::Remmina);
        
        assert_eq!(settings.fullscreen, false);
        assert_eq!(settings.ignore_certificate, false);
    }

    #[test]
    fn test_client_display_names() {
        assert_eq!(RdpClientType::Remmina.display_name(), "Remmina");
        assert_eq!(RdpClientType::FreeRdp.display_name(), "FreeRDP (xfreerdp)");
        assert_eq!(RdpClientType::Krdc.display_name(), "KRDC");
        assert_eq!(RdpClientType::GnomeConnections.display_name(), "GNOME Connections");
    }
}
