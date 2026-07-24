use super::utils::*;
use super::VncSettings;
use std::process::{Command, Stdio};
use anyhow::{Result, anyhow};
use tracing;

/// Check if Vinagre is available
pub fn is_available() -> bool {
    command_exists("vinagre") || flatpak_exists("org.gnome.Vinagre")
}

/// Launch Vinagre VNC client
pub fn launch(port: u16, instance_name: &str, settings: &VncSettings) -> Result<()> {
    tracing::info!(
        instance_name = instance_name,
        port = port,
        fullscreen = settings.fullscreen,
        view_only = settings.view_only,
        "Launching Vinagre VNC client"
    );

    // Vinagre can accept direct hostname:port format or display number
    // Using hostname:port format is more reliable
    let vnc_address = format!("127.0.0.1:{}", port);

    // Try native first
    if command_exists("vinagre") {
        return try_native_launch(&vnc_address, settings);
    }

    // Try flatpak
    if flatpak_exists("org.gnome.Vinagre") {
        return try_flatpak_launch(&vnc_address, settings);
    }

    Err(anyhow!("Vinagre not found"))
}

fn try_native_launch(address: &str, settings: &VncSettings) -> Result<()> {
    tracing::debug!("Attempting native Vinagre launch");

    let mut cmd = Command::new("vinagre");
    cmd.arg(address);

    // Add fullscreen flag if requested
    if settings.fullscreen {
        cmd.arg("--fullscreen");
    }

    // Vinagre supports scaling
    cmd.arg("--vnc-scale");

    // Note: Vinagre doesn't have a view-only CLI flag
    // Quality/compression settings are also not available via CLI
    if settings.view_only {
        tracing::warn!("Vinagre doesn't support view-only mode via CLI. User must configure interactively.");
    }

    cmd.stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;

    tracing::info!("Native Vinagre VNC launched");
    Ok(())
}

fn try_flatpak_launch(address: &str, settings: &VncSettings) -> Result<()> {
    tracing::debug!("Attempting Flatpak Vinagre launch");

    let mut args = vec!["run", "org.gnome.Vinagre"];

    // Add fullscreen flag
    if settings.fullscreen {
        args.push("--fullscreen");
    }

    // Add scaling
    args.push("--vnc-scale");

    // Add address last
    args.push(address);

    if settings.view_only {
        tracing::warn!("Vinagre doesn't support view-only mode via CLI. User must configure interactively.");
    }

    Command::new("flatpak")
        .args(&args)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;

    tracing::info!("Flatpak Vinagre VNC launched");
    Ok(())
}
