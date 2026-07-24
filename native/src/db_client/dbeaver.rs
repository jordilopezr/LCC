use super::utils::*;
use super::{DbConnectionSettings, DatabaseType};
use std::process::{Command, Stdio};
use anyhow::{Result, anyhow};
use tracing;

const NATIVE_CMD: &str = "dbeaver";
const FLATPAK_ID: &str = "io.dbeaver.DBeaverCommunity";

/// Check if DBeaver is available (native or flatpak)
pub fn is_available() -> bool {
    command_exists(NATIVE_CMD) || flatpak_exists(FLATPAK_ID)
}

/// Launch DBeaver with connection settings
///
/// DBeaver supports MySQL, PostgreSQL, and SQL Server connections.
/// We use the command line connection feature with driver-specific parameters.
pub fn launch(settings: &DbConnectionSettings) -> Result<()> {
    tracing::info!(
        instance_name = %settings.instance_name,
        database_type = ?settings.database_type,
        port = settings.port,
        "Launching DBeaver"
    );

    // Build connection arguments based on database type
    let con_arg = build_connection_arg(settings)?;

    // Try native first
    if command_exists(NATIVE_CMD) {
        tracing::debug!("Attempting native DBeaver");
        let native = Command::new(NATIVE_CMD)
            .arg("-con")
            .arg(&con_arg)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();

        if native.is_ok() {
            tracing::info!("Native DBeaver launched successfully");
            return Ok(());
        }
    }

    // Try Flatpak
    if flatpak_exists(FLATPAK_ID) {
        tracing::debug!("Attempting Flatpak DBeaver");
        let flatpak = Command::new("flatpak")
            .args(["run", FLATPAK_ID])
            .arg("-con")
            .arg(&con_arg)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();

        if flatpak.is_ok() {
            tracing::info!("Flatpak DBeaver launched successfully");
            return Ok(());
        }
    }

    Err(anyhow!("Failed to launch DBeaver"))
}

/// Build DBeaver connection argument string
///
/// Format: driver=mysql|postgresql|sqlserver|host=HOST|port=PORT|database=DB|user=USER|name=CONNECTION_NAME
fn build_connection_arg(settings: &DbConnectionSettings) -> Result<String> {
    let driver = match settings.database_type {
        DatabaseType::MySQL => "mysql",
        DatabaseType::PostgreSQL => "postgresql",
        DatabaseType::SQLServer => "sqlserver",
        _ => return Err(anyhow!("DBeaver does not support {:?}", settings.database_type)),
    };

    let mut parts = vec![
        format!("driver={}", driver),
        format!("host={}", settings.host),
        format!("port={}", settings.port),
        format!("name=IAP-{}", sanitize_cli_arg(&settings.instance_name)),
    ];

    if let Some(ref db) = settings.database_name {
        if !db.is_empty() {
            parts.push(format!("database={}", sanitize_cli_arg(db)));
        }
    }

    if let Some(ref user) = settings.username {
        if !user.is_empty() {
            parts.push(format!("user={}", sanitize_cli_arg(user)));
        }
    }

    Ok(parts.join("|"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_build_connection_arg_mysql() {
        let settings = DbConnectionSettings {
            database_type: DatabaseType::MySQL,
            host: "127.0.0.1".to_string(),
            port: 3306,
            database_name: Some("testdb".to_string()),
            username: Some("admin".to_string()),
            instance_name: "my-vm".to_string(),
            client_type: None,
        };

        let arg = build_connection_arg(&settings).unwrap();
        assert!(arg.contains("driver=mysql"));
        assert!(arg.contains("host=127.0.0.1"));
        assert!(arg.contains("port=3306"));
        assert!(arg.contains("database=testdb"));
        assert!(arg.contains("user=admin"));
    }

    #[test]
    fn test_build_connection_arg_postgresql() {
        let settings = DbConnectionSettings {
            database_type: DatabaseType::PostgreSQL,
            host: "127.0.0.1".to_string(),
            port: 5432,
            database_name: None,
            username: None,
            instance_name: "pg-vm".to_string(),
            client_type: None,
        };

        let arg = build_connection_arg(&settings).unwrap();
        assert!(arg.contains("driver=postgresql"));
        assert!(arg.contains("port=5432"));
    }

    #[test]
    fn test_build_connection_arg_unsupported() {
        let settings = DbConnectionSettings {
            database_type: DatabaseType::Redis,
            host: "127.0.0.1".to_string(),
            port: 6379,
            database_name: None,
            username: None,
            instance_name: "redis-vm".to_string(),
            client_type: None,
        };

        assert!(build_connection_arg(&settings).is_err());
    }
}
