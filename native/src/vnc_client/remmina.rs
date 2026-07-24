use super::utils::*;
use super::VncSettings;
use std::fs::File;
use std::io::Write;
use std::process::{Command, Stdio};
use anyhow::{Result, anyhow};
use tracing;

/// Check if Remmina is available (native or flatpak)
pub fn is_available() -> bool {
    command_exists("remmina") || flatpak_exists("org.remmina.Remmina")
}

/// Launch Remmina VNC client
pub fn launch(port: u16, instance_name: &str, settings: &VncSettings) -> Result<()> {
    tracing::info!(
        instance_name = instance_name,
        port = port,
        fullscreen = settings.fullscreen,
        view_only = settings.view_only,
        "Launching Remmina VNC client"
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
            return Ok(());
        } else if let Err(e) = flatpak {
             tracing::warn!(error = %e, "Flatpak file mode launch failed");
        }
    }

    // 3. Fallback: Flatpak URI (Bypasses file permission issues entirely)
    tracing::debug!("Falling back to Flatpak URI mode");
    let uri = build_vnc_uri(port);

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

/// Create Remmina config file with VNC settings
fn create_remmina_config(
    port: u16,
    instance_name: &str,
    settings: &VncSettings,
) -> Result<std::path::PathBuf> {
    let config_dir = get_config_dir()?;
    let file_path = config_dir.join(format!("iap_vnc_{}.remmina", instance_name));

    let quality = quality_to_remmina(settings.quality);
    let viewonly = if settings.view_only { "1" } else { "0" };

    let mut content = format!(
        "[remmina]\nname={} (IAP VNC)\nprotocol=VNC\nserver=127.0.0.1:{}\nquality={}\nviewonly={}\nenable-autostart=1\n",
        instance_name, port, quality, viewonly
    );

    // Add password if provided
    if let Some(p) = &settings.password {
        content.push_str(&format!("password={}\n", p));
    }

    // Add display settings
    if settings.fullscreen {
        content.push_str("viewmode=4\n"); // viewmode=4 is fullscreen in Remmina
    } else if let (Some(w), Some(h)) = (settings.width, settings.height) {
        content.push_str(&format!("resolution={}x{}\n", w, h));
        content.push_str("viewmode=1\n"); // viewmode=1 is scrolled window
    } else {
        content.push_str("window_maximize=1\n");
        content.push_str("viewmode=1\n");
    }

    let mut file = File::create(&file_path)?;
    file.write_all(content.as_bytes())?;
    set_secure_permissions(&file_path)?;

    tracing::debug!("Created Remmina VNC config file: {:?}", file_path);
    Ok(file_path)
}
