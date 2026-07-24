use super::utils::*;
use super::{DbConnectionSettings, DatabaseType};
use std::process::{Command, Stdio};
use anyhow::{Result, anyhow};
use tracing;

const NATIVE_CMD: &str = "mysql-workbench";
const FLATPAK_ID: &str = "com.mysql.Workbench";

/// Check if MySQL Workbench is available (native or flatpak)
pub fn is_available() -> bool {
    command_exists(NATIVE_CMD) || flatpak_exists(FLATPAK_ID)
}

/// Launch MySQL Workbench with connection settings
///
/// MySQL Workbench only supports MySQL connections.
/// We use the command line with a MySQL URI format.
pub fn launch(settings: &DbConnectionSettings) -> Result<()> {
    if settings.database_type != DatabaseType::MySQL {
        return Err(anyhow!("MySQL Workbench only supports MySQL connections"));
    }

    tracing::info!(
        instance_name = %settings.instance_name,
        port = settings.port,
        "Launching MySQL Workbench"
    );

    // Build MySQL connection URI
    let uri = build_mysql_uri(
        &settings.host,
        settings.port,
        settings.database_name.as_deref(),
        settings.username.as_deref(),
    );

    // Try native first
    if command_exists(NATIVE_CMD) {
        tracing::debug!("Attempting native MySQL Workbench");
        let native = Command::new(NATIVE_CMD)
            .arg("--uri")
            .arg(&uri)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();

        if native.is_ok() {
            tracing::info!("Native MySQL Workbench launched successfully");
            return Ok(());
        }
    }

    // Try Flatpak
    if flatpak_exists(FLATPAK_ID) {
        tracing::debug!("Attempting Flatpak MySQL Workbench");
        let flatpak = Command::new("flatpak")
            .args(["run", FLATPAK_ID])
            .arg("--uri")
            .arg(&uri)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();

        if flatpak.is_ok() {
            tracing::info!("Flatpak MySQL Workbench launched successfully");
            return Ok(());
        }
    }

    Err(anyhow!("Failed to launch MySQL Workbench"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_launch_wrong_db_type() {
        let settings = DbConnectionSettings {
            database_type: DatabaseType::PostgreSQL,
            host: "127.0.0.1".to_string(),
            port: 5432,
            database_name: None,
            username: None,
            instance_name: "test".to_string(),
            client_type: None,
        };

        assert!(launch(&settings).is_err());
    }
}
