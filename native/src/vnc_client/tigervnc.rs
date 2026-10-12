use super::utils::*;
use crate::child_reaper::SpawnReaped;
use super::VncSettings;
use std::process::{Command, Stdio};
use anyhow::{Result, anyhow};
use tracing;

/// Check if TigerVNC is available
pub fn is_available() -> bool {
    if command_exists("vncviewer") || command_exists("tigervnc") {
        return true;
    }
    
    #[cfg(target_os = "windows")]
    {
        // Check standard installation paths on Windows
        let paths = [
            r#"C:\Program Files\TigerVNC\vncviewer.exe"#,
            r#"C:\Program Files\RealVNC\VNC Viewer\vncviewer.exe"#,
        ];
        return paths.iter().any(|p| std::path::Path::new(p).exists());
    }
    
    #[cfg(not(target_os = "windows"))]
    false
}

/// Launch TigerVNC client (vncviewer)
pub fn launch(port: u16, instance_name: &str, settings: &VncSettings) -> Result<()> {
    tracing::info!(
        instance_name = instance_name,
        port = port,
        fullscreen = settings.fullscreen,
        view_only = settings.view_only,
        "Launching TigerVNC client"
    );

    // VNC display number is port - 5900
    // Example: port 5900 = display :0, port 5901 = display :1
    let display_num = if port >= 5900 {
        port - 5900
    } else {
        // If port is less than 5900, use it directly as display number
        port
    };

    let vnc_address = format!("127.0.0.1:{}", display_num);

    #[cfg(target_os = "windows")]
    let mut cmd = if command_exists("vncviewer") {
        Command::new("vncviewer")
    } else if std::path::Path::new(r#"C:\Program Files\TigerVNC\vncviewer.exe"#).exists() {
        Command::new(r#"C:\Program Files\TigerVNC\vncviewer.exe"#)
    } else if std::path::Path::new(r#"C:\Program Files\RealVNC\VNC Viewer\vncviewer.exe"#).exists() {
        Command::new(r#"C:\Program Files\RealVNC\VNC Viewer\vncviewer.exe"#)
    } else {
        Command::new("vncviewer")
    };

    #[cfg(not(target_os = "windows"))]
    let mut cmd = Command::new("vncviewer");
    cmd.arg(&vnc_address);

    // Add fullscreen flag
    if settings.fullscreen {
        cmd.arg("-FullScreen");
    }

    // Add view-only flag
    if settings.view_only {
        cmd.arg("-ViewOnly");
    }

    // Add quality level
    let quality = quality_to_tigervnc(settings.quality);
    cmd.arg(format!("-QualityLevel={}", quality));

    // SECURITY: we intentionally do NOT persist the VNC password to disk.
    // A `-passwd` file leaves a recoverable credential in a temp file (even at
    // 0600, and beyond a crash before cleanup); instead TigerVNC prompts for
    // the password at connection time.
    if settings.password.is_some() {
        tracing::info!(
            "Password provided but not written to disk for TigerVNC; the viewer \
             will prompt for it at connection time."
        );
    }

    // Add custom resolution if specified and not fullscreen
    if !settings.fullscreen {
        if let (Some(w), Some(h)) = (settings.width, settings.height) {
            cmd.arg(format!("-geometry={}x{}", w, h));
        }
    }

    // Launch the viewer
    cmd.stdout(Stdio::null())
        .stderr(Stdio::null());

    match cmd.spawn_reaped() {
        Ok(_) => {
            tracing::info!("TigerVNC launched successfully");
            Ok(())
        },
        Err(e) => {
            tracing::error!(error = %e, "Failed to launch TigerVNC");
            Err(anyhow!("Failed to launch TigerVNC: {}", e))
        }
    }
}
