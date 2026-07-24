use super::utils::*;
use super::VncSettings;
use std::process::{Command, Stdio};
use anyhow::{Result, anyhow};
use tracing;

/// Check if KRDC is available
pub fn is_available() -> bool {
    command_exists("krdc") || flatpak_exists("org.kde.krdc")
}

/// Launch KRDC VNC client
pub fn launch(port: u16, instance_name: &str, settings: &VncSettings) -> Result<()> {
    tracing::info!(
        instance_name = instance_name,
        port = port,
        fullscreen = settings.fullscreen,
        view_only = settings.view_only,
        "Launching KRDC VNC client"
    );

    // Build VNC URI
    let uri = build_vnc_uri(port);

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

fn try_native_launch(uri: &str, settings: &VncSettings) -> Result<()> {
    tracing::debug!("Attempting native KRDC launch");

    let mut cmd = Command::new("krdc");
    cmd.arg(uri);

    // KRDC doesn't support many CLI args, relies on interactive prompts
    // We can only pass the URI and basic settings
    if settings.fullscreen {
        tracing::warn!("KRDC doesn't support fullscreen via CLI. User can press F11 once connected.");
    }

    if settings.view_only {
        tracing::warn!("KRDC doesn't support view-only mode via CLI. User must configure interactively.");
    }

    cmd.stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;

    tracing::info!("Native KRDC VNC launched");
    Ok(())
}

fn try_flatpak_launch(uri: &str, settings: &VncSettings) -> Result<()> {
    tracing::debug!("Attempting Flatpak KRDC launch");

    if settings.fullscreen {
        tracing::warn!("KRDC doesn't support fullscreen via CLI. User can press F11 once connected.");
    }

    if settings.view_only {
        tracing::warn!("KRDC doesn't support view-only mode via CLI. User must configure interactively.");
    }

    Command::new("flatpak")
        .args(["run", "org.kde.krdc", uri])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;

    tracing::info!("Flatpak KRDC VNC launched");
    Ok(())
}
