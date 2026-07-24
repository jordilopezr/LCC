use super::utils::*;
use super::{DbConnectionSettings, DatabaseType};
use std::fs::File;
use std::io::Write;
use std::process::{Command, Stdio};
use anyhow::{Result, anyhow};
use tracing;

const NATIVE_CMD: &str = "pgadmin4";
const FLATPAK_ID: &str = "org.pgadmin.pgadmin4";

/// Check if pgAdmin is available (native or flatpak)
pub fn is_available() -> bool {
    command_exists(NATIVE_CMD) || flatpak_exists(FLATPAK_ID)
}

/// Launch pgAdmin 4 with connection settings
///
/// pgAdmin 4 only supports PostgreSQL connections.
/// Since pgAdmin doesn't have a direct CLI connection method,
/// we launch it and let the user create the connection manually,
/// or create a servers.json file that pgAdmin can import.
pub fn launch(settings: &DbConnectionSettings) -> Result<()> {
    if settings.database_type != DatabaseType::PostgreSQL {
        return Err(anyhow!("pgAdmin only supports PostgreSQL connections"));
    }

    tracing::info!(
        instance_name = %settings.instance_name,
        port = settings.port,
        "Launching pgAdmin 4"
    );

    // Create a connection info file that user can reference
    let _ = create_connection_info(settings);

    // Try native first
    if command_exists(NATIVE_CMD) {
        tracing::debug!("Attempting native pgAdmin 4");
        let native = Command::new(NATIVE_CMD)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();

        if native.is_ok() {
            tracing::info!("Native pgAdmin 4 launched successfully");
            return Ok(());
        }
    }

    // Try Flatpak
    if flatpak_exists(FLATPAK_ID) {
        tracing::debug!("Attempting Flatpak pgAdmin 4");
        let flatpak = Command::new("flatpak")
            .args(["run", FLATPAK_ID])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();

        if flatpak.is_ok() {
            tracing::info!("Flatpak pgAdmin 4 launched successfully");
            return Ok(());
        }
    }

    Err(anyhow!("Failed to launch pgAdmin 4"))
}

/// Create a connection info JSON file that can be imported into pgAdmin
///
/// Note: pgAdmin 4 uses a servers.json format for importing servers.
/// We create this file so users can easily import the connection.
fn create_connection_info(settings: &DbConnectionSettings) -> Result<std::path::PathBuf> {
    let config_dir = get_config_dir()?;
    let file_path = config_dir.join(format!("pgadmin_iap_{}.json", sanitize_cli_arg(&settings.instance_name)));

    let db_name = settings.database_name.as_deref().unwrap_or("postgres");
    let username = settings.username.as_deref().unwrap_or("postgres");

    // pgAdmin servers.json format
    let content = format!(
        r#"{{
  "Servers": {{
    "1": {{
      "Name": "IAP-{}",
      "Group": "IAP Tunnels",
      "Host": "{}",
      "Port": {},
      "MaintenanceDB": "{}",
      "Username": "{}",
      "SSLMode": "prefer",
      "Comment": "Connection via IAP tunnel to {}"
    }}
  }}
}}"#,
        sanitize_cli_arg(&settings.instance_name),
        settings.host,
        settings.port,
        db_name,
        username,
        settings.instance_name
    );

    let mut file = File::create(&file_path)?;
    file.write_all(content.as_bytes())?;
    set_secure_permissions(&file_path)?;

    tracing::info!(
        path = ?file_path,
        "Created pgAdmin connection info file. Import it via File > Import Servers"
    );

    Ok(file_path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_launch_wrong_db_type() {
        let settings = DbConnectionSettings {
            database_type: DatabaseType::MySQL,
            host: "127.0.0.1".to_string(),
            port: 3306,
            database_name: None,
            username: None,
            instance_name: "test".to_string(),
            client_type: None,
        };

        assert!(launch(&settings).is_err());
    }
}
