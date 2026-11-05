//! macOS Screen Sharing (Compartir pantalla) — the VNC viewer built into
//! every Mac, opened through a `vnc://` URL.

use super::utils::build_vnc_uri;
use super::VncSettings;
use anyhow::{anyhow, Result};
use std::process::{Command, Stdio};
use tracing;

pub fn is_available() -> bool {
    cfg!(target_os = "macos")
}

/// The password is not put in the URL: it would be visible in the process
/// list. Screen Sharing asks for it and can keep it in the Keychain.
pub fn launch(port: u16, instance_name: &str, settings: &VncSettings) -> Result<()> {
    tracing::info!(
        instance_name = instance_name,
        port = port,
        "Launching macOS Screen Sharing"
    );
    if settings.view_only || settings.fullscreen {
        tracing::debug!("Screen Sharing takes view-only/fullscreen from its own menu, not the URL");
    }

    let status = Command::new("/usr/bin/open")
        .arg(build_vnc_uri(port))
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()?;
    if !status.success() {
        return Err(anyhow!("`open` could not hand the vnc:// URL to Screen Sharing"));
    }
    Ok(())
}
