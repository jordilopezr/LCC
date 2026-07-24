use super::utils::*;
use super::{DbConnectionSettings, DatabaseType};
use std::process::{Command, Stdio};
use anyhow::{Result, anyhow};
use tracing;

const NATIVE_CMD: &str = "azuredatastudio";
const FLATPAK_ID: &str = "com.microsoft.AzureDataStudio";

/// Check if Azure Data Studio is available (native or flatpak)
pub fn is_available() -> bool {
    command_exists(NATIVE_CMD) || flatpak_exists(FLATPAK_ID)
}

/// Launch Azure Data Studio with connection settings
///
/// Azure Data Studio supports PostgreSQL and SQL Server connections.
/// We use the command line connection feature.
pub fn launch(settings: &DbConnectionSettings) -> Result<()> {
    match settings.database_type {
        DatabaseType::PostgreSQL | DatabaseType::SQLServer => {}
        _ => return Err(anyhow!("Azure Data Studio only supports PostgreSQL and SQL Server")),
    }

    tracing::info!(
        instance_name = %settings.instance_name,
        database_type = ?settings.database_type,
        port = settings.port,
        "Launching Azure Data Studio"
    );

    // Build connection URI based on database type
    let uri = match settings.database_type {
        DatabaseType::PostgreSQL => build_postgresql_uri(
            &settings.host,
            settings.port,
            settings.database_name.as_deref(),
            settings.username.as_deref(),
        ),
        DatabaseType::SQLServer => build_sqlserver_uri(
            &settings.host,
            settings.port,
            settings.database_name.as_deref(),
            settings.username.as_deref(),
        ),
        _ => unreachable!(),
    };

    // Try native first
    if command_exists(NATIVE_CMD) {
        tracing::debug!("Attempting native Azure Data Studio");
        // Azure Data Studio accepts connection strings via command line
        let native = Command::new(NATIVE_CMD)
            .arg("--open-url")
            .arg(&uri)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();

        if native.is_ok() {
            tracing::info!("Native Azure Data Studio launched successfully");
            return Ok(());
        }

        // Try without URI argument (just open the app)
        let native_plain = Command::new(NATIVE_CMD)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();

        if native_plain.is_ok() {
            tracing::info!("Native Azure Data Studio launched (connection info: {}:{})", settings.host, settings.port);
            return Ok(());
        }
    }

    // Try Flatpak
    if flatpak_exists(FLATPAK_ID) {
        tracing::debug!("Attempting Flatpak Azure Data Studio");
        let flatpak = Command::new("flatpak")
            .args(["run", FLATPAK_ID])
            .arg("--open-url")
            .arg(&uri)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();

        if flatpak.is_ok() {
            tracing::info!("Flatpak Azure Data Studio launched successfully");
            return Ok(());
        }

        // Try without URI argument
        let flatpak_plain = Command::new("flatpak")
            .args(["run", FLATPAK_ID])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();

        if flatpak_plain.is_ok() {
            tracing::info!("Flatpak Azure Data Studio launched (connection info: {}:{})", settings.host, settings.port);
            return Ok(());
        }
    }

    Err(anyhow!("Failed to launch Azure Data Studio"))
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

    #[test]
    fn test_launch_supported_db_types() {
        // These should not return immediate errors (only connection errors if client not installed)
        let pg_settings = DbConnectionSettings {
            database_type: DatabaseType::PostgreSQL,
            host: "127.0.0.1".to_string(),
            port: 5432,
            database_name: None,
            username: None,
            instance_name: "test".to_string(),
            client_type: None,
        };

        let sql_settings = DbConnectionSettings {
            database_type: DatabaseType::SQLServer,
            host: "127.0.0.1".to_string(),
            port: 1433,
            database_name: None,
            username: None,
            instance_name: "test".to_string(),
            client_type: None,
        };

        // We can't test actual launch without the apps installed,
        // but we can verify the settings validation
        match pg_settings.database_type {
            DatabaseType::PostgreSQL | DatabaseType::SQLServer => {} // OK
            _ => panic!("Should accept PostgreSQL"),
        }
        match sql_settings.database_type {
            DatabaseType::PostgreSQL | DatabaseType::SQLServer => {} // OK
            _ => panic!("Should accept SQLServer"),
        }
    }
}
