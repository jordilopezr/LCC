pub mod utils;
pub mod dbeaver;
pub mod mysql_workbench;
pub mod pgadmin;
pub mod azure_data_studio;
pub mod redis_insight;
pub mod mongodb_compass;

use anyhow::{Result, anyhow};
use tracing;

// Re-export cleanup utilities for use from API
pub use utils::cleanup_old_config_files;

/// Supported database types
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DatabaseType {
    MySQL,
    PostgreSQL,
    SQLServer,
    Redis,
    MongoDB,
}

impl DatabaseType {
    /// Get human-readable name
    pub fn display_name(&self) -> &'static str {
        match self {
            DatabaseType::MySQL => "MySQL",
            DatabaseType::PostgreSQL => "PostgreSQL",
            DatabaseType::SQLServer => "SQL Server",
            DatabaseType::Redis => "Redis",
            DatabaseType::MongoDB => "MongoDB",
        }
    }

    /// Get default port for this database type
    pub fn default_port(&self) -> u16 {
        match self {
            DatabaseType::MySQL => 3306,
            DatabaseType::PostgreSQL => 5432,
            DatabaseType::SQLServer => 1433,
            DatabaseType::Redis => 6379,
            DatabaseType::MongoDB => 27017,
        }
    }

    /// Get all supported database types
    pub fn all() -> Vec<DatabaseType> {
        vec![
            DatabaseType::MySQL,
            DatabaseType::PostgreSQL,
            DatabaseType::SQLServer,
            DatabaseType::Redis,
            DatabaseType::MongoDB,
        ]
    }
}

/// Database client types supported by the application
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DbClientType {
    DBeaver,
    MySQLWorkbench,
    PgAdmin,
    AzureDataStudio,
    RedisInsight,
    MongoDBCompass,
}

impl DbClientType {
    /// Get human-readable name
    pub fn display_name(&self) -> &'static str {
        match self {
            DbClientType::DBeaver => "DBeaver",
            DbClientType::MySQLWorkbench => "MySQL Workbench",
            DbClientType::PgAdmin => "pgAdmin 4",
            DbClientType::AzureDataStudio => "Azure Data Studio",
            DbClientType::RedisInsight => "RedisInsight",
            DbClientType::MongoDBCompass => "MongoDB Compass",
        }
    }

    /// Check if this client is available on the system
    pub fn is_available(&self) -> bool {
        match self {
            DbClientType::DBeaver => dbeaver::is_available(),
            DbClientType::MySQLWorkbench => mysql_workbench::is_available(),
            DbClientType::PgAdmin => pgadmin::is_available(),
            DbClientType::AzureDataStudio => azure_data_studio::is_available(),
            DbClientType::RedisInsight => redis_insight::is_available(),
            DbClientType::MongoDBCompass => mongodb_compass::is_available(),
        }
    }

    /// Get database types supported by this client
    pub fn supported_databases(&self) -> Vec<DatabaseType> {
        match self {
            DbClientType::DBeaver => vec![
                DatabaseType::MySQL,
                DatabaseType::PostgreSQL,
                DatabaseType::SQLServer,
            ],
            DbClientType::MySQLWorkbench => vec![DatabaseType::MySQL],
            DbClientType::PgAdmin => vec![DatabaseType::PostgreSQL],
            DbClientType::AzureDataStudio => vec![
                DatabaseType::PostgreSQL,
                DatabaseType::SQLServer,
            ],
            DbClientType::RedisInsight => vec![DatabaseType::Redis],
            DbClientType::MongoDBCompass => vec![DatabaseType::MongoDB],
        }
    }

    /// Check if this client supports a given database type
    pub fn supports_database(&self, db_type: DatabaseType) -> bool {
        self.supported_databases().contains(&db_type)
    }

    /// Get all client types
    pub fn all() -> Vec<DbClientType> {
        vec![
            DbClientType::DBeaver,
            DbClientType::MySQLWorkbench,
            DbClientType::PgAdmin,
            DbClientType::AzureDataStudio,
            DbClientType::RedisInsight,
            DbClientType::MongoDBCompass,
        ]
    }

    /// Get fallback priority order for a database type
    pub fn fallback_order_for(db_type: DatabaseType) -> Vec<DbClientType> {
        match db_type {
            DatabaseType::MySQL => vec![
                DbClientType::DBeaver,
                DbClientType::MySQLWorkbench,
            ],
            DatabaseType::PostgreSQL => vec![
                DbClientType::DBeaver,
                DbClientType::PgAdmin,
                DbClientType::AzureDataStudio,
            ],
            DatabaseType::SQLServer => vec![
                DbClientType::AzureDataStudio,
                DbClientType::DBeaver,
            ],
            DatabaseType::Redis => vec![DbClientType::RedisInsight],
            DatabaseType::MongoDB => vec![DbClientType::MongoDBCompass],
        }
    }
}

/// Database connection settings
#[derive(Debug, Clone)]
pub struct DbConnectionSettings {
    pub database_type: DatabaseType,
    pub host: String,           // "127.0.0.1" for tunnel connections
    pub port: u16,              // Local tunnel port
    pub database_name: Option<String>,
    pub username: Option<String>,
    pub instance_name: String,
    pub client_type: Option<DbClientType>,
}

impl Default for DbConnectionSettings {
    fn default() -> Self {
        Self {
            database_type: DatabaseType::MySQL,
            host: "127.0.0.1".to_string(),
            port: 3306,
            database_name: None,
            username: None,
            instance_name: String::new(),
            client_type: None,
        }
    }
}

/// Result of database client launch attempt
#[derive(Debug, Clone)]
pub struct DbLaunchResult {
    pub client_used: DbClientType,
    pub fallback_occurred: bool,
}

/// Main dispatcher - tries user's preferred client first, then falls back
pub fn launch_db_client(settings: DbConnectionSettings) -> Result<DbLaunchResult> {
    let db_type = settings.database_type;

    tracing::info!(
        instance_name = %settings.instance_name,
        database_type = ?db_type,
        host = %settings.host,
        port = settings.port,
        preferred_client = ?settings.client_type,
        "Launching database client"
    );

    // Get preferred client or use default fallback order
    let preferred = settings.client_type.unwrap_or_else(|| {
        DbClientType::fallback_order_for(db_type)
            .into_iter()
            .find(|c| c.is_available())
            .unwrap_or(DbClientType::DBeaver)
    });

    // Check if preferred client supports the database type
    if !preferred.supports_database(db_type) {
        tracing::warn!(
            client = ?preferred,
            database_type = ?db_type,
            "Preferred client does not support database type, trying fallbacks"
        );
    } else {
        // Try preferred client first
        if preferred.is_available() {
            match try_launch_client(preferred, &settings) {
                Ok(_) => {
                    tracing::info!(client = ?preferred, "Database client launched successfully");
                    return Ok(DbLaunchResult {
                        client_used: preferred,
                        fallback_occurred: false,
                    });
                }
                Err(e) => {
                    tracing::warn!(
                        client = ?preferred,
                        error = %e,
                        "Preferred client failed, trying fallbacks"
                    );
                }
            }
        } else {
            tracing::warn!(
                client = ?preferred,
                "Preferred client not available, trying fallbacks"
            );
        }
    }

    // Try fallback clients in priority order
    let fallbacks = DbClientType::fallback_order_for(db_type)
        .into_iter()
        .filter(|c| *c != preferred);

    for client in fallbacks {
        if !client.is_available() {
            tracing::debug!(client = ?client, "Client not available, skipping");
            continue;
        }

        match try_launch_client(client, &settings) {
            Ok(_) => {
                tracing::info!(
                    preferred = ?preferred,
                    fallback = ?client,
                    "Database client launched using fallback"
                );
                return Ok(DbLaunchResult {
                    client_used: client,
                    fallback_occurred: true,
                });
            }
            Err(e) => {
                tracing::warn!(client = ?client, error = %e, "Fallback client failed");
                continue;
            }
        }
    }

    // All attempts failed
    let supported_clients: Vec<&str> = DbClientType::fallback_order_for(db_type)
        .iter()
        .map(|c| c.display_name())
        .collect();

    Err(anyhow!(
        "No database clients available for {}. Please install one of: {}",
        db_type.display_name(),
        supported_clients.join(", ")
    ))
}

/// Try to launch a specific client
fn try_launch_client(client: DbClientType, settings: &DbConnectionSettings) -> Result<()> {
    match client {
        DbClientType::DBeaver => dbeaver::launch(settings),
        DbClientType::MySQLWorkbench => mysql_workbench::launch(settings),
        DbClientType::PgAdmin => pgadmin::launch(settings),
        DbClientType::AzureDataStudio => azure_data_studio::launch(settings),
        DbClientType::RedisInsight => redis_insight::launch(settings),
        DbClientType::MongoDBCompass => mongodb_compass::launch(settings),
    }
}

/// Get all available database clients on the system
pub fn get_available_db_clients() -> Vec<DbClientType> {
    DbClientType::all()
        .into_iter()
        .filter(|client| client.is_available())
        .collect()
}

/// Get available clients for a specific database type
pub fn get_available_clients_for_db(db_type: DatabaseType) -> Vec<DbClientType> {
    DbClientType::fallback_order_for(db_type)
        .into_iter()
        .filter(|client| client.is_available())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_database_type_default_ports() {
        assert_eq!(DatabaseType::MySQL.default_port(), 3306);
        assert_eq!(DatabaseType::PostgreSQL.default_port(), 5432);
        assert_eq!(DatabaseType::SQLServer.default_port(), 1433);
        assert_eq!(DatabaseType::Redis.default_port(), 6379);
        assert_eq!(DatabaseType::MongoDB.default_port(), 27017);
    }

    #[test]
    fn test_client_supports_database() {
        assert!(DbClientType::DBeaver.supports_database(DatabaseType::MySQL));
        assert!(DbClientType::DBeaver.supports_database(DatabaseType::PostgreSQL));
        assert!(!DbClientType::MySQLWorkbench.supports_database(DatabaseType::PostgreSQL));
        assert!(DbClientType::RedisInsight.supports_database(DatabaseType::Redis));
    }

    #[test]
    fn test_fallback_order_for_mysql() {
        let order = DbClientType::fallback_order_for(DatabaseType::MySQL);
        assert_eq!(order[0], DbClientType::DBeaver);
        assert_eq!(order[1], DbClientType::MySQLWorkbench);
    }

    #[test]
    fn test_db_connection_settings_default() {
        let settings = DbConnectionSettings::default();
        assert_eq!(settings.host, "127.0.0.1");
        assert_eq!(settings.database_type, DatabaseType::MySQL);
        assert_eq!(settings.port, 3306);
    }

    #[test]
    fn test_display_names() {
        assert_eq!(DatabaseType::MySQL.display_name(), "MySQL");
        assert_eq!(DbClientType::DBeaver.display_name(), "DBeaver");
    }
}
