use super::utils::*;
use super::{DbConnectionSettings, DatabaseType};
use std::process::{Command, Stdio};
use anyhow::{Result, anyhow};
use tracing;

const NATIVE_CMD: &str = "redisinsight";
// Alternative names for RedisInsight
const NATIVE_CMD_ALT: &str = "RedisInsight";
const FLATPAK_ID: &str = "com.redis.RedisInsight";

/// Check if RedisInsight is available (native or flatpak)
pub fn is_available() -> bool {
    command_exists(NATIVE_CMD) || command_exists(NATIVE_CMD_ALT) || flatpak_exists(FLATPAK_ID)
}

/// Launch RedisInsight with connection settings
///
/// RedisInsight only supports Redis connections.
/// RedisInsight v2+ supports command line arguments for database connection.
pub fn launch(settings: &DbConnectionSettings) -> Result<()> {
    if settings.database_type != DatabaseType::Redis {
        return Err(anyhow!("RedisInsight only supports Redis connections"));
    }

    tracing::info!(
        instance_name = %settings.instance_name,
        port = settings.port,
        "Launching RedisInsight"
    );

    // RedisInsight doesn't have a standard CLI for pre-configuring connections,
    // but we can launch it and let the user add the connection.
    // The connection info will be displayed to the user.

    // Try native first (lowercase)
    if command_exists(NATIVE_CMD) {
        tracing::debug!("Attempting native RedisInsight (lowercase)");
        let native = Command::new(NATIVE_CMD)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();

        if native.is_ok() {
            tracing::info!(
                "RedisInsight launched. Add connection: {}:{}",
                settings.host,
                settings.port
            );
            return Ok(());
        }
    }

    // Try native (capitalized)
    if command_exists(NATIVE_CMD_ALT) {
        tracing::debug!("Attempting native RedisInsight (capitalized)");
        let native = Command::new(NATIVE_CMD_ALT)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();

        if native.is_ok() {
            tracing::info!(
                "RedisInsight launched. Add connection: {}:{}",
                settings.host,
                settings.port
            );
            return Ok(());
        }
    }

    // Try Flatpak
    if flatpak_exists(FLATPAK_ID) {
        tracing::debug!("Attempting Flatpak RedisInsight");
        let flatpak = Command::new("flatpak")
            .args(["run", FLATPAK_ID])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();

        if flatpak.is_ok() {
            tracing::info!(
                "Flatpak RedisInsight launched. Add connection: {}:{}",
                settings.host,
                settings.port
            );
            return Ok(());
        }
    }

    Err(anyhow!("Failed to launch RedisInsight"))
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
