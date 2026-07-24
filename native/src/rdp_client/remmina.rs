use super::utils::*;
use super::RdpSettings;
use std::fs::File;
use std::io::Write;
use std::process::{Command, Stdio};
use anyhow::{Result, anyhow};
use tracing;

/// Check if Remmina is available (native or flatpak)
pub fn is_available() -> bool {
    command_exists("remmina") || flatpak_exists("org.remmina.Remmina")
}

/// Launch Remmina RDP client
pub fn launch(port: u16, instance_name: &str, settings: &RdpSettings) -> Result<()> {
    tracing::info!(
        instance_name = instance_name,
        port = port,
        fullscreen = settings.fullscreen,
        "Launching Remmina RDP client"
    );
    
    let config_path_opt = create_remmina_config(port, instance_name, settings).ok();

    // 1. Try Native
    if let Some(ref path) = config_path_opt {
        tracing::debug!("Attempting native Remmina with config file");
        let native = Command::new("remmina")
            .arg("-c")
            .arg(path)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();

        if native.is_ok() {
            tracing::info!("Native Remmina launched successfully");
            return Ok(());
        }
    }

    // 2. Try Flatpak with File Forwarding
    if let Some(ref path) = config_path_opt {
        tracing::debug!("Attempting Flatpak Remmina with file forwarding");
        // Note: inheriting stdio to debug why it fails
        let flatpak = Command::new("flatpak")
            .args(["run", "--file-forwarding", "org.remmina.Remmina"])
            .arg("-c")
            .arg("@@")
            .arg(path)
            .arg("@@")
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit())
            .spawn();

        if flatpak.is_ok() {
            tracing::info!("Flatpak Remmina launched (file mode)");
            // We return Ok here because spawn succeeded, but Remmina might fail later.
            // If it fails immediately, the logs will show it.
            // But let's add a tiny fallback: if spawn is ok, we assume success.
            // The user will report if it crashes.
            return Ok(());
        } else if let Err(e) = flatpak {
             tracing::warn!(error = %e, "Flatpak file mode launch failed");
        }
    }

    // 3. Fallback: Flatpak URI (Bypasses file permission issues entirely)
    tracing::debug!("Falling back to Flatpak URI mode");
    let uri = format!("rdp://127.0.0.1:{}", port);

    let flatpak_uri = Command::new("flatpak")
        .args(["run", "org.remmina.Remmina", "-c", &uri])
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .spawn();

    match flatpak_uri {
        Ok(_) => {
            tracing::info!("Flatpak Remmina launched (URI mode)");
            Ok(())
        },
        Err(e) => {
            tracing::error!(error = %e, "All Remmina launch attempts failed");
            Err(anyhow!("All launch attempts failed. Error: {}", e))
        }
    }
}

/// Create Remmina config file with RDP settings
fn create_remmina_config(
    port: u16,
    instance_name: &str,
    settings: &RdpSettings,
) -> Result<std::path::PathBuf> {
    let config_dir = get_config_dir()?;

    // Defense-in-depth: sanitize instance_name for use in filename
    // even though API-level validation should already reject invalid chars.
    let safe_name: String = instance_name
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
        .take(63) // GCP max instance name length
        .collect();

    if safe_name.is_empty() {
        return Err(anyhow!("Invalid instance name for config file"));
    }

    let file_path = config_dir.join(format!("iap_{}.remmina", safe_name));

    let ignore_cert = if settings.ignore_certificate { "1" } else { "0" };
    let mut content = format!(
        "[remmina]\nname={} (IAP)\nprotocol=RDP\nserver=127.0.0.1:{}\nignore-certificate={}\nenable-autostart=1\n",
        safe_name, port, ignore_cert
    );

    // Add credentials (username and domain only - password is never stored in config files)
    // SECURITY: Password is intentionally NOT written to the config file.
    // Remmina will prompt the user for the password at connection time.
    // This prevents plaintext credential storage on disk.
    if let Some(u) = &settings.username { content.push_str(&format!("username={}\n", u)); }
    if let Some(d) = &settings.domain { content.push_str(&format!("domain={}\n", d)); }

    // Log security notice if password was provided but not stored
    if settings.password.is_some() {
        tracing::info!(
            "Password provided but not stored in Remmina config for security. \
             Remmina will prompt for password at connection time."
        );
    }

    // Add display settings
    if settings.fullscreen {
        content.push_str("viewmode=4\n"); // viewmode=4 is fullscreen in Remmina
    } else if let (Some(w), Some(h)) = (settings.width, settings.height) {
        content.push_str(&format!("resolution={}x{}\n", w, h));
    } else {
        content.push_str("window_maximize=1\n");
    }

    let mut file = File::create(&file_path)?;
    file.write_all(content.as_bytes())?;
    set_secure_permissions(&file_path)?;

    Ok(file_path)
}
