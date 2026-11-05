//! Microsoft "Windows App" (formerly Microsoft Remote Desktop) — the RDP
//! client on macOS. Free from the Mac App Store.
//!
//! It has no CLI: it is driven by opening a `.rdp` file with `open -a`.

use super::utils::*;
use super::RdpSettings;
use anyhow::{anyhow, Result};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use tracing;

/// Bundle names the app has shipped under: renamed to "Windows App" in 2024.
const APP_NAMES: [&str; 2] = ["Windows App", "Microsoft Remote Desktop"];

/// The installed app's bundle path, if any.
fn find_app() -> Option<PathBuf> {
    let mut roots = vec![PathBuf::from("/Applications")];
    if let Some(home) = dirs::home_dir() {
        roots.push(home.join("Applications"));
    }
    for name in APP_NAMES {
        for root in &roots {
            let path = root.join(format!("{}.app", name));
            if path.exists() {
                return Some(path);
            }
        }
    }
    None
}

pub fn is_available() -> bool {
    cfg!(target_os = "macos") && find_app().is_some()
}

/// The `.rdp` file contents. The password is never written: Windows App
/// ignores it in a file and asks for it in its own dialog (and keeps it in the
/// macOS Keychain if the user chooses to).
fn rdp_file_contents(port: u16, settings: &RdpSettings) -> String {
    let mut lines = vec![
        format!("full address:s:127.0.0.1:{}", port),
        "prompt for credentials:i:1".to_string(),
        // The IAP tunnel already authenticates and encrypts the hop; the
        // VM's certificate is self-signed and names the VM, not 127.0.0.1.
        format!(
            "authentication level:i:{}",
            if settings.ignore_certificate { 0 } else { 2 }
        ),
    ];
    if let Some(user) = settings.username.as_deref().filter(|u| !u.is_empty()) {
        let user = match settings.domain.as_deref().filter(|d| !d.is_empty()) {
            Some(domain) => format!("{}\\{}", domain, user),
            None => user.to_string(),
        };
        lines.push(format!("username:s:{}", user));
    }
    if settings.fullscreen {
        lines.push("screen mode id:i:2".to_string());
    } else {
        lines.push("screen mode id:i:1".to_string());
        if let (Some(w), Some(h)) = (settings.width, settings.height) {
            lines.push(format!("desktopwidth:i:{}", w));
            lines.push(format!("desktopheight:i:{}", h));
        }
        lines.push("smart sizing:i:1".to_string());
    }
    lines.join("\r\n") + "\r\n"
}

pub fn launch(port: u16, instance_name: &str, settings: &RdpSettings) -> Result<()> {
    let app = find_app().ok_or_else(|| anyhow!("Windows App is not installed"))?;

    tracing::info!(
        instance_name = instance_name,
        port = port,
        app = ?app,
        "Launching Windows App"
    );

    if settings.password.is_some() {
        tracing::info!("Password not written to the .rdp file; Windows App will prompt for it");
    }

    // Same name as Remmina's temporary config so remove_config_file and the
    // hourly cleanup find it too.
    let path = get_config_dir()?.join(format!("iap_{}.rdp", instance_name));
    std::fs::write(&path, rdp_file_contents(port, settings))?;
    set_secure_permissions(&path)?;

    // `open` returns as soon as the app has the file; nothing to reap beyond it.
    let status = Command::new("/usr/bin/open")
        .arg("-a")
        .arg(&app)
        .arg(&path)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()?;
    if !status.success() {
        return Err(anyhow!("`open` could not hand the .rdp file to Windows App"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rdp_file_has_address_and_user_but_never_the_password() {
        let settings = RdpSettings {
            username: Some("admin".into()),
            password: Some("hunter2".into()),
            domain: Some("CORP".into()),
            ..RdpSettings::default()
        };
        let text = rdp_file_contents(3389, &settings);
        assert!(text.contains("full address:s:127.0.0.1:3389"));
        assert!(text.contains("username:s:CORP\\admin"));
        assert!(!text.contains("hunter2"));
    }
}
