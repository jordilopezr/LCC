use anyhow::{anyhow, Result};
use crate::rdp_client::RdpSettings;

pub fn is_available() -> bool {
    #[cfg(target_os = "windows")]
    {
        true // mstsc is always available on Windows
    }
    #[cfg(not(target_os = "windows"))]
    {
        false
    }
}

pub fn launch(port: u16, instance_name: &str, settings: &RdpSettings) -> Result<()> {
    #[cfg(not(target_os = "windows"))]
    {
        let _ = (port, instance_name, settings); // suppress unused warnings
        return Err(anyhow!("Microsoft Remote Desktop (mstsc) is only supported on Windows"));
    }

    #[cfg(target_os = "windows")]
    {
        let mut cmd = Command::new("mstsc");
        
        let mut rdp_content = String::new();
        rdp_content.push_str(&format!("full address:s:127.0.0.1:{}\n", port));
        
        if let Some(user) = &settings.username {
            rdp_content.push_str(&format!("username:s:{}\n", user));
        }
        
        if settings.fullscreen {
            rdp_content.push_str("screen mode id:i:2\n");
        } else {
            rdp_content.push_str("screen mode id:i:1\n");
            if let Some(w) = settings.width {
                rdp_content.push_str(&format!("desktopwidth:i:{}\n", w));
            }
            if let Some(h) = settings.height {
                rdp_content.push_str(&format!("desktopheight:i:{}\n", h));
            }
        }
        
        if settings.ignore_certificate {
            rdp_content.push_str("authentication level:i:2\n"); // 2 means ignore cert errors
        }

        let temp_dir = std::env::temp_dir();
        let rdp_file_path = temp_dir.join(format!("{}.rdp", instance_name));
        
        let mut file = std::fs::File::create(&rdp_file_path)?;
        file.write_all(rdp_content.as_bytes())?;

        cmd.arg(rdp_file_path.to_str().unwrap());

        tracing::info!("Launching mstsc with RDP file: {:?}", rdp_file_path);

        cmd.spawn().map_err(|e| anyhow!("Failed to spawn mstsc: {}", e))?;
        
        Ok(())
    }
}
