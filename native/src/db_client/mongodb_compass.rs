use super::utils::*;
use super::{DbConnectionSettings, DatabaseType};
use std::process::{Command, Stdio};
use anyhow::{Result, anyhow};
use tracing;

const NATIVE_CMD: &str = "mongodb-compass";
const FLATPAK_ID: &str = "com.mongodb.Compass";

/// Check if MongoDB Compass is available (native or flatpak)
pub fn is_available() -> bool {
    command_exists(NATIVE_CMD) || flatpak_exists(FLATPAK_ID)
}

/// Launch MongoDB Compass with connection settings
///
/// MongoDB Compass only supports MongoDB connections.
/// We can pass a connection URI directly to Compass via command line.
pub fn launch(settings: &DbConnectionSettings) -> Result<()> {
    if settings.database_type != DatabaseType::MongoDB {
        return Err(anyhow!("MongoDB Compass only supports MongoDB connections"));
    }

    tracing::info!(
        instance_name = %settings.instance_name,
        port = settings.port,
        "Launching MongoDB Compass"
    );

    // Build MongoDB connection URI
    let uri = build_mongodb_uri(
        &settings.host,
        settings.port,
        settings.database_name.as_deref(),
    );

    // Try native first
    if command_exists(NATIVE_CMD) {
        tracing::debug!("Attempting native MongoDB Compass");
        // MongoDB Compass accepts connection URI as a positional argument
        let native = Command::new(NATIVE_CMD)
            .arg(&uri)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();

        if native.is_ok() {
            tracing::info!("Native MongoDB Compass launched successfully");
            return Ok(());
        }

        // Try without URI (just open the app)
        let native_plain = Command::new(NATIVE_CMD)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();

        if native_plain.is_ok() {
            tracing::info!(
                "MongoDB Compass launched. Connect to: {}",
                uri
            );
            return Ok(());
        }
    }

    // Try Flatpak
    if flatpak_exists(FLATPAK_ID) {
        tracing::debug!("Attempting Flatpak MongoDB Compass");
        let flatpak = Command::new("flatpak")
            .args(["run", FLATPAK_ID])
            .arg(&uri)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();

        if flatpak.is_ok() {
            tracing::info!("Flatpak MongoDB Compass launched successfully");
            return Ok(());
        }

        // Try without URI
        let flatpak_plain = Command::new("flatpak")
            .args(["run", FLATPAK_ID])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();

        if flatpak_plain.is_ok() {
            tracing::info!(
                "Flatpak MongoDB Compass launched. Connect to: {}",
                uri
            );
            return Ok(());
        }
    }

    Err(anyhow!("Failed to launch MongoDB Compass"))
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
    fn test_mongodb_uri_building() {
        let uri = build_mongodb_uri("127.0.0.1", 27017, Some("testdb"));
        assert_eq!(uri, "mongodb://127.0.0.1:27017/testdb");

        let uri_no_db = build_mongodb_uri("127.0.0.1", 27017, None);
        assert_eq!(uri_no_db, "mongodb://127.0.0.1:27017");
    }
}
