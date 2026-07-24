use super::utils::*;
use super::VncSettings;
use std::fs::File;
use std::io::Write;
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

    // Handle password if provided
    // TigerVNC can use a password file for security
    let password_file_path = if let Some(ref password) = settings.password {
        match create_password_file(instance_name, password) {
            Ok(path) => {
                cmd.arg("-passwd");
                cmd.arg(&path);
                Some(path)
            },
            Err(e) => {
                tracing::warn!(error = %e, "Failed to create password file, password not set");
                None
            }
        }
    } else {
        None
    };

    // Add custom resolution if specified and not fullscreen
    if !settings.fullscreen {
        if let (Some(w), Some(h)) = (settings.width, settings.height) {
            cmd.arg(format!("-geometry={}x{}", w, h));
        }
    }

    // Launch the viewer
    cmd.stdout(Stdio::null())
        .stderr(Stdio::null());

    match cmd.spawn() {
        Ok(_) => {
            tracing::info!("TigerVNC launched successfully");

            // Clean up password file after a short delay (in a separate thread)
            // The viewer should have read it by then
            if let Some(path) = password_file_path {
                std::thread::spawn(move || {
                    std::thread::sleep(std::time::Duration::from_secs(2));
                    let _ = std::fs::remove_file(&path);
                    tracing::debug!("Cleaned up TigerVNC password file");
                });
            }

            Ok(())
        },
        Err(e) => {
            // Clean up password file on error
            if let Some(path) = password_file_path {
                let _ = std::fs::remove_file(&path);
            }
            tracing::error!(error = %e, "Failed to launch TigerVNC");
            Err(anyhow!("Failed to launch TigerVNC: {}", e))
        }
    }
}

/// Create a temporary password file for TigerVNC
/// TigerVNC expects password in a specific format
fn create_password_file(instance_name: &str, password: &str) -> Result<std::path::PathBuf> {
    let config_dir = get_config_dir()?;
    let file_path = config_dir.join(format!("vnc_passwd_{}.tmp", instance_name));

    // Write password to file (TigerVNC can handle plain text passwords via -passwd flag)
    let mut file = File::create(&file_path)?;
    file.write_all(password.as_bytes())?;

    // Set secure permissions (0600 - owner read/write only)
    set_secure_permissions(&file_path)?;

    tracing::debug!("Created TigerVNC password file: {:?}", file_path);
    Ok(file_path)
}
