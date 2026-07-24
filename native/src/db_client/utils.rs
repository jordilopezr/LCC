use std::process::Command;
use anyhow::{Result, anyhow};
use tracing;

/// Check if a command exists in PATH
pub fn command_exists(cmd: &str) -> bool {
    Command::new("which")
        .arg(cmd)
        .output()
        .map(|output| output.status.success())
        .unwrap_or(false)
}

/// Check if a flatpak app is installed
pub fn flatpak_exists(app_id: &str) -> bool {
    Command::new("flatpak")
        .args(["list", "--app", "--columns=application"])
        .output()
        .map(|output| {
            String::from_utf8_lossy(&output.stdout)
                .lines()
                .any(|line| line.trim() == app_id)
        })
        .unwrap_or(false)
}

/// Build MySQL connection URI for DBeaver
/// Format: mysql://user@host:port/database
pub fn build_mysql_uri(host: &str, port: u16, database: Option<&str>, username: Option<&str>) -> String {
    let mut uri = String::from("mysql://");

    if let Some(user) = username {
        if !user.is_empty() {
            uri.push_str(user);
            uri.push('@');
        }
    }

    uri.push_str(host);
    uri.push(':');
    uri.push_str(&port.to_string());

    if let Some(db) = database {
        if !db.is_empty() {
            uri.push('/');
            uri.push_str(db);
        }
    }

    uri
}

/// Build PostgreSQL connection URI
/// Format: postgresql://user@host:port/database
pub fn build_postgresql_uri(host: &str, port: u16, database: Option<&str>, username: Option<&str>) -> String {
    let mut uri = String::from("postgresql://");

    if let Some(user) = username {
        if !user.is_empty() {
            uri.push_str(user);
            uri.push('@');
        }
    }

    uri.push_str(host);
    uri.push(':');
    uri.push_str(&port.to_string());

    if let Some(db) = database {
        if !db.is_empty() {
            uri.push('/');
            uri.push_str(db);
        }
    }

    uri
}

/// Build SQL Server connection URI for Azure Data Studio
/// Format: mssql://user@host:port/database
pub fn build_sqlserver_uri(host: &str, port: u16, database: Option<&str>, username: Option<&str>) -> String {
    let mut uri = String::from("mssql://");

    if let Some(user) = username {
        if !user.is_empty() {
            uri.push_str(user);
            uri.push('@');
        }
    }

    uri.push_str(host);
    uri.push(':');
    uri.push_str(&port.to_string());

    if let Some(db) = database {
        if !db.is_empty() {
            uri.push('/');
            uri.push_str(db);
        }
    }

    uri
}

/// Build Redis connection URI
/// Format: redis://host:port
pub fn build_redis_uri(host: &str, port: u16) -> String {
    format!("redis://{}:{}", host, port)
}

/// Build MongoDB connection URI
/// Format: mongodb://host:port/database
pub fn build_mongodb_uri(host: &str, port: u16, database: Option<&str>) -> String {
    let mut uri = format!("mongodb://{}:{}", host, port);

    if let Some(db) = database {
        if !db.is_empty() {
            uri.push('/');
            uri.push_str(db);
        }
    }

    uri
}

/// Create secure temp directory for config files
pub fn get_config_dir() -> Result<std::path::PathBuf> {
    let base = dirs::cache_dir()
        .ok_or_else(|| anyhow!("Could not determine cache directory"))?;
    let mut config_dir = crate::app_dirs::migrated_app_dir(base);
    config_dir.push("db_clients");

    if !config_dir.exists() {
        std::fs::create_dir_all(&config_dir)?;
    }

    Ok(config_dir)
}

/// Set file permissions to 0600 (owner read/write only) for security
#[cfg(unix)]
pub fn set_secure_permissions(path: &std::path::Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    tracing::debug!("Secure permissions (0600) set on file: {:?}", path);
    Ok(())
}

#[cfg(not(unix))]
pub fn set_secure_permissions(_path: &std::path::Path) -> Result<()> {
    Ok(())
}

/// Maximum age for temporary config files (in seconds)
const MAX_CONFIG_AGE_SECS: u64 = 3600; // 1 hour

/// Clean up old temporary configuration files for database clients
pub fn cleanup_old_config_files() -> Result<usize> {
    let config_dir = get_config_dir()?;

    if !config_dir.exists() {
        return Ok(0);
    }

    let entries = std::fs::read_dir(&config_dir)
        .map_err(|e| anyhow!("Failed to read config directory: {}", e))?;

    let now = std::time::SystemTime::now();
    let max_age = std::time::Duration::from_secs(MAX_CONFIG_AGE_SECS);
    let mut cleaned = 0;

    for entry in entries.flatten() {
        let path = entry.path();

        // Process JSON and connection files
        let ext = path.extension().and_then(|e| e.to_str());
        if ext != Some("json") && ext != Some("pgpass") {
            continue;
        }

        // Check file age
        if let Ok(metadata) = std::fs::metadata(&path) {
            if let Ok(modified) = metadata.modified() {
                if let Ok(age) = now.duration_since(modified) {
                    if age > max_age {
                        if let Err(e) = std::fs::remove_file(&path) {
                            tracing::warn!(
                                path = ?path,
                                error = %e,
                                "Failed to remove old config file"
                            );
                        } else {
                            tracing::debug!(
                                path = ?path,
                                age_secs = age.as_secs(),
                                "Cleaned up old config file"
                            );
                            cleaned += 1;
                        }
                    }
                }
            }
        }
    }

    if cleaned > 0 {
        tracing::info!(
            count = cleaned,
            "Cleaned up old database client configuration files"
        );
    }

    Ok(cleaned)
}

/// Sanitize a string for use in CLI arguments
/// Prevents command injection
pub fn sanitize_cli_arg(input: &str) -> String {
    // Remove potentially dangerous characters
    input
        .chars()
        .filter(|c| c.is_alphanumeric() || *c == '_' || *c == '-' || *c == '.' || *c == '@')
        .collect()
}

/// Validate port number
pub fn validate_port(port: u16) -> Result<()> {
    if port == 0 {
        return Err(anyhow!("Port cannot be 0"));
    }
    if port < 1024 {
        tracing::warn!(port = port, "Using privileged port (< 1024)");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_build_mysql_uri() {
        assert_eq!(
            build_mysql_uri("127.0.0.1", 3306, None, None),
            "mysql://127.0.0.1:3306"
        );
        assert_eq!(
            build_mysql_uri("127.0.0.1", 3306, Some("mydb"), Some("admin")),
            "mysql://admin@127.0.0.1:3306/mydb"
        );
    }

    #[test]
    fn test_build_postgresql_uri() {
        assert_eq!(
            build_postgresql_uri("127.0.0.1", 5432, None, None),
            "postgresql://127.0.0.1:5432"
        );
        assert_eq!(
            build_postgresql_uri("127.0.0.1", 5432, Some("postgres"), Some("user")),
            "postgresql://user@127.0.0.1:5432/postgres"
        );
    }

    #[test]
    fn test_sanitize_cli_arg() {
        assert_eq!(sanitize_cli_arg("normal_name"), "normal_name");
        assert_eq!(sanitize_cli_arg("name; rm -rf /"), "namerm-rf");
        assert_eq!(sanitize_cli_arg("user@domain.com"), "user@domain.com");
    }

    #[test]
    fn test_validate_port() {
        assert!(validate_port(3306).is_ok());
        assert!(validate_port(0).is_err());
    }
}
