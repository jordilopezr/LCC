use super::utils::*;
use super::RdpSettings;
use std::process::{Command, Stdio};
use anyhow::{Result, anyhow};
use tracing;

/// Check if GNOME Connections is available
pub fn is_available() -> bool {
    command_exists("gnome-connections") || flatpak_exists("org.gnome.Connections")
}

/// Launch GNOME Connections client
pub fn launch(port: u16, instance_name: &str, settings: &RdpSettings) -> Result<()> {
    tracing::info!(
        instance_name = instance_name,
        port = port,
        fullscreen = settings.fullscreen,
        "Launching GNOME Connections client"
    );

    // Build RDP URI
    let uri = build_rdp_uri(port, settings.username.as_deref());

    // Try native first
    if command_exists("gnome-connections") {
        return try_native_launch(&uri, settings);
    }

    // Try flatpak
    if flatpak_exists("org.gnome.Connections") {
        return try_flatpak_launch(&uri, settings);
    }

    Err(anyhow!("GNOME Connections not found"))
}

fn try_native_launch(uri: &str, settings: &RdpSettings) -> Result<()> {
    tracing::debug!("Attempting native GNOME Connections launch");

    let mut cmd = Command::new("gnome-connections");
    cmd.arg(uri);

    // GNOME Connections has minimal CLI args, uses interactive setup
    // It may support RDP scaling and fullscreen via gsettings or UI
    if settings.fullscreen {
        tracing::warn!("GNOME Connections fullscreen must be toggled via UI (F11 key)");
    }

    cmd.stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;

    tracing::info!("Native GNOME Connections launched");
    Ok(())
}

fn try_flatpak_launch(uri: &str, _settings: &RdpSettings) -> Result<()> {
    tracing::debug!("Attempting Flatpak GNOME Connections launch");

    Command::new("flatpak")
        .args(["run", "org.gnome.Connections", uri])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;

    tracing::info!("Flatpak GNOME Connections launched");
    Ok(())
}
