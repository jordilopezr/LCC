use anyhow::{Context, Result};
use std::fs;
use std::path::PathBuf;
use std::sync::OnceLock;
use tracing_appender::non_blocking::WorkerGuard;
use tracing_appender::rolling::{RollingFileAppender, Rotation};
use tracing_subscriber::{fmt, layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

// Re-export redact utilities for convenient access throughout the codebase
pub use crate::redact::{redact_sensitive, redact_value, contains_sensitive};

/// Maximum log file size in bytes (10 MB)
const MAX_LOG_SIZE: u64 = 10 * 1024 * 1024;

/// Maximum number of rotated log files to keep
const MAX_LOG_FILES: usize = 5;

/// Guard that keeps the non-blocking logger alive
/// Must be stored somewhere that lives for the duration of the program
/// Using OnceLock for thread-safe initialization without unsafe code
static LOGGER_GUARD: OnceLock<WorkerGuard> = OnceLock::new();

/// Initialize the structured logging system
///
/// Creates log directory at ~/.local/share/lightweight_cloud_connector/logs/
/// Logs are rotated daily and limited to MAX_LOG_SIZE
/// Old logs are automatically cleaned up (keeps only MAX_LOG_FILES)
///
/// # Returns
/// - `Ok(())` if logging initialized successfully
/// - `Err(_)` if log directory cannot be created
pub fn init_logging() -> Result<()> {
    let log_dir = get_log_directory()?;

    // Create log directory if it doesn't exist
    fs::create_dir_all(&log_dir)
        .with_context(|| format!("Failed to create log directory: {:?}", log_dir))?;

    // Clean up old log files
    cleanup_old_logs(&log_dir)?;

    // Create rolling file appender (rotates daily)
    let file_appender = RollingFileAppender::new(
        Rotation::DAILY,
        &log_dir,
        "app.log",
    );

    // Create non-blocking writer (prevents I/O from blocking the main thread)
    let (non_blocking, guard) = tracing_appender::non_blocking(file_appender);

    // Store guard in static to prevent logger from being dropped
    // Using OnceLock for thread-safe initialization
    let _ = LOGGER_GUARD.set(guard);

    // Configure log filter
    // Default: INFO level
    // Can be overridden with RUST_LOG environment variable
    // Example: RUST_LOG=debug ./lightweight_cloud_connector
    let env_filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("info"));

    // Create subscriber with both console and file output
    tracing_subscriber::registry()
        .with(env_filter)
        .with(
            fmt::layer()
                .with_writer(std::io::stdout)
                .with_target(false)
                .compact()
        )
        .with(
            fmt::layer()
                .with_writer(non_blocking)
                .with_ansi(false) // No ANSI colors in log files
                .with_target(true)
                .with_file(true)
                .with_line_number(true)
        )
        .init();

    tracing::info!(
        log_dir = ?log_dir,
        max_size_mb = MAX_LOG_SIZE / (1024 * 1024),
        max_files = MAX_LOG_FILES,
        "Logging system initialized"
    );

    Ok(())
}

/// Get the log directory path
///
/// Returns: ~/.local/share/lightweight_cloud_connector/logs/
fn get_log_directory() -> Result<PathBuf> {
    let data_dir = dirs::data_local_dir()
        .context("Could not determine local data directory")?;

    Ok(crate::app_dirs::migrated_app_dir(data_dir).join("logs"))
}

/// Clean up old log files to prevent disk space issues
///
/// Strategy:
/// 1. Delete files larger than MAX_LOG_SIZE
/// 2. Keep only the newest MAX_LOG_FILES files
fn cleanup_old_logs(log_dir: &PathBuf) -> Result<()> {
    let entries = match fs::read_dir(log_dir) {
        Ok(entries) => entries,
        Err(_) => return Ok(()), // Directory doesn't exist yet, nothing to clean
    };

    let mut log_files: Vec<_> = entries
        .filter_map(|entry| entry.ok())
        .filter(|entry| {
            entry.path().extension()
                .and_then(|ext| ext.to_str())
                .map(|ext| ext == "log")
                .unwrap_or(false)
        })
        .collect();

    // Sort by modification time (newest first)
    log_files.sort_by_key(|entry| {
        entry.metadata()
            .and_then(|m| m.modified())
            .ok()
            .map(std::cmp::Reverse)
    });

    let mut kept_files = 0;

    for entry in log_files {
        let path = entry.path();

        // Check file size
        if let Ok(metadata) = fs::metadata(&path) {
            if metadata.len() > MAX_LOG_SIZE {
                tracing::warn!(
                    file = ?path,
                    size_mb = metadata.len() / (1024 * 1024),
                    "Deleting oversized log file"
                );
                let _ = fs::remove_file(&path);
                continue;
            }
        }

        // Keep only MAX_LOG_FILES newest files
        if kept_files >= MAX_LOG_FILES {
            tracing::info!(
                file = ?path,
                "Deleting old log file (exceeds maximum count)"
            );
            let _ = fs::remove_file(&path);
        } else {
            kept_files += 1;
        }
    }

    Ok(())
}

/// Get the path to the current log file
///
/// Returns: Full path to app.log
pub fn get_current_log_path() -> Result<PathBuf> {
    let log_dir = get_log_directory()?;
    Ok(log_dir.join("app.log"))
}

/// Export all logs to a single file for troubleshooting
///
/// Combines all log files into a single timestamped export file
///
/// # Returns
/// - `Ok(PathBuf)` - Path to the exported log file
/// - `Err(_)` if export fails
pub fn export_logs() -> Result<PathBuf> {
    let log_dir = get_log_directory()?;
    let timestamp = chrono::Local::now().format("%Y%m%d_%H%M%S");
    let export_path = log_dir.join(format!("export_{}.log", timestamp));

    let entries = fs::read_dir(&log_dir)
        .context("Failed to read log directory")?;

    let mut all_logs = String::new();
    all_logs.push_str(&format!("=== Lightweight Cloud Connector - Log Export ===\n"));
    all_logs.push_str(&format!("Generated: {}\n", chrono::Local::now()));
    all_logs.push_str(&format!("==================================\n\n"));

    let mut log_files: Vec<_> = entries
        .filter_map(|entry| entry.ok())
        .filter(|entry| {
            let path = entry.path();
            path.extension()
                .and_then(|ext| ext.to_str())
                .map(|ext| ext == "log")
                .unwrap_or(false)
                && !path.file_name()
                    .and_then(|name| name.to_str())
                    .map(|name| name.starts_with("export_"))
                    .unwrap_or(false)
        })
        .collect();

    // Sort by modification time (oldest first)
    log_files.sort_by_key(|entry| {
        entry.metadata()
            .and_then(|m| m.modified())
            .ok()
    });

    for entry in log_files {
        let path = entry.path();
        if let Ok(content) = fs::read_to_string(&path) {
            all_logs.push_str(&format!("\n=== {} ===\n", path.display()));
            all_logs.push_str(&content);
            all_logs.push_str("\n");
        }
    }

    fs::write(&export_path, all_logs)
        .context("Failed to write export file")?;

    tracing::info!(
        export_path = ?export_path,
        "Logs exported successfully"
    );

    Ok(export_path)
}

/// Shared multi-threaded runtime for async work called from sync FFI entry points.
static RUNTIME: std::sync::OnceLock<tokio::runtime::Runtime> = std::sync::OnceLock::new();

/// Run a future to completion on the shared runtime.
pub fn block_on<F: std::future::Future>(future: F) -> F::Output {
    RUNTIME
        .get_or_init(|| {
            tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .build()
                .expect("failed to build shared tokio runtime")
        })
        .block_on(future)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_log_directory_path() {
        let log_dir = get_log_directory().unwrap();
        assert!(log_dir.to_string_lossy().contains("lightweight_cloud_connector"));
        assert!(log_dir.to_string_lossy().contains("logs"));
    }
}
