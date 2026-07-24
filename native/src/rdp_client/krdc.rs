use super::utils::*;
use super::RdpSettings;
use std::process::{Command, Stdio};
use anyhow::{Result, anyhow};
use tracing;

/// Check if KRDC is available
pub fn is_available() -> bool {
    command_exists("krdc") || flatpak_exists("org.kde.krdc")
}

/// Launch KRDC client
pub fn launch(port: u16, instance_name: &str, settings: &RdpSettings) -> Result<()> {
    tracing::info!(
        instance_name = instance_name,
        port = port,
        fullscreen = settings.fullscreen,
        "Launching KRDC client"
    );

    // Build RDP URI with username if available
    let uri = build_rdp_uri(port, settings.username.as_deref());

    // Try native first
    if command_exists("krdc") {
        return try_native_launch(&uri, settings);
    }

    // Try flatpak
    if flatpak_exists("org.kde.krdc") {
        return try_flatpak_launch(&uri, settings);
    }

    Err(anyhow!("KRDC not found"))
}

fn try_native_launch(uri: &str, settings: &RdpSettings) -> Result<()> {
    tracing::debug!("Attempting native KRDC launch");

    let mut cmd = Command::new("krdc");
    cmd.arg(uri);

    // KRDC doesn't support many CLI args, relies on interactive prompts
    // We can only pass the URI and basic settings
    if settings.fullscreen {
        tracing::warn!("KRDC doesn't support fullscreen via CLI. User can press F11 once connected.");
    }

    cmd.stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;

    tracing::info!("Native KRDC launched");
    Ok(())
}

fn try_flatpak_launch(uri: &str, _settings: &RdpSettings) -> Result<()> {
    tracing::debug!("Attempting Flatpak KRDC launch");

    Command::new("flatpak")
        .args(["run", "org.kde.krdc", uri])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;

    tracing::info!("Flatpak KRDC launched");
    Ok(())
}
