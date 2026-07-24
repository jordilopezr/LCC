use super::utils::*;
use super::RdpSettings;
use std::process::{Command, Stdio};
use anyhow::{Result, anyhow};
use tracing;

/// Check if FreeRDP (xfreerdp) is available
pub fn is_available() -> bool {
    command_exists("xfreerdp") || command_exists("xfreerdp3")
}

/// Launch FreeRDP client
///
/// SECURITY NOTE: Passwords are NOT passed via CLI arguments to prevent exposure
/// in process listings (`ps aux`). FreeRDP will prompt for the password securely.
pub fn launch(port: u16, instance_name: &str, settings: &RdpSettings) -> Result<()> {
    tracing::info!(
        instance_name = instance_name,
        port = port,
        fullscreen = settings.fullscreen,
        "Launching FreeRDP client"
    );

    // Determine which xfreerdp version is available
    let cmd = if command_exists("xfreerdp3") {
        "xfreerdp3"
    } else if command_exists("xfreerdp") {
        "xfreerdp"
    } else {
        return Err(anyhow!("xfreerdp not found"));
    };

    let mut args = vec![
        format!("/v:127.0.0.1:{}", port),
        "/cert:ignore".to_string(), // Always ignore cert for IAP tunnels
    ];

    // Add credentials
    // SECURITY: We intentionally DO NOT pass the password via CLI arguments.
    // CLI arguments are visible to all users via `ps aux` (CWE-214: Process Invocation with Visible Credentials)
    // FreeRDP will prompt for the password securely via its own dialog.
    if let Some(user) = &settings.username {
        args.push(format!("/u:{}", user));
    }

    // Log security notice if password was provided but not passed to CLI
    if settings.password.is_some() {
        tracing::info!(
            "Password provided but not passed to FreeRDP CLI for security. \
             FreeRDP will prompt for password via secure dialog to prevent exposure in process list."
        );
    }

    if let Some(domain) = &settings.domain {
        args.push(format!("/d:{}", domain));
    }

    // Display settings
    if settings.fullscreen {
        args.push("/f".to_string()); // Fullscreen flag
    } else if let (Some(w), Some(h)) = (settings.width, settings.height) {
        args.push(format!("/size:{}x{}", w, h));
    } else {
        args.push("/smart-sizing".to_string());
    }

    // Additional quality settings for better performance
    args.push("/compression".to_string());
    args.push("/gfx:rfx".to_string()); // RemoteFX codec
    args.push("/gfx-h264:avc444".to_string()); // H.264 encoding

    tracing::debug!("FreeRDP command: {} {:?}", cmd, args);

    Command::new(cmd)
        .args(&args)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;

    tracing::info!("FreeRDP launched successfully");
    Ok(())
}
