use crate::engine_pref::{EngineSlot, EngineSource, Resolved};
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
/// Held in a `Mutex<Option<..>>`, not a `OnceLock`, because it has to be
/// *droppable*. The file writer is non-blocking: lines go to a background
/// worker, and the guard flushes that worker when it drops. Statics are never
/// dropped at process exit, so a line emitted moments before exiting can be
/// lost — which for [`log_shutdown`] would be fatal to its purpose. Its absence
/// is the evidence, so an absence that means "the queue never drained" and one
/// that means "the app crashed" must not look alike.
static LOGGER_GUARD: std::sync::Mutex<Option<WorkerGuard>> = std::sync::Mutex::new(None);

/// When this process's logging came up, for the uptime on the shutdown line.
static STARTED: OnceLock<std::time::Instant> = OnceLock::new();

/// The build this process is running, repeated on the shutdown line so a log
/// spanning an upgrade can be cut at the seam.
static APP_VERSION: OnceLock<String> = OnceLock::new();

/// Initialize the structured logging system
///
/// Creates log directory at ~/.local/share/lightweight_cloud_connector/logs/
/// Logs are rotated daily and limited to MAX_LOG_SIZE
/// Old logs are automatically cleaned up (keeps only MAX_LOG_FILES)
///
/// # Returns
/// - `Ok(())` if logging initialized successfully
/// - `Err(_)` if log directory cannot be created
pub fn init_logging(app_version: &str) -> Result<()> {
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

    // Store guard in a static to prevent the logger from being dropped early;
    // `log_shutdown` takes it back out to force the final flush.
    if let Ok(mut held) = LOGGER_GUARD.lock() {
        *held = Some(guard);
    }
    let _ = STARTED.set(std::time::Instant::now());
    let _ = APP_VERSION.set(app_version.to_string());

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

    // Which build, and which binary. Neither was recorded before, and every
    // diagnosis started by guessing: a tunnel failure was once blamed on new
    // code when the log came from a month-old build installed under /usr/lib.
    // `app_version` is what Settings shows; `binary` is what is actually
    // running, and they disagree exactly when it matters.
    let binary = std::env::current_exe()
        .map(|p| p.display().to_string())
        .unwrap_or_else(|_| "unknown".to_string());

    tracing::info!(
        app_version,
        binary,
        log_dir = ?log_dir,
        max_size_mb = MAX_LOG_SIZE / (1024 * 1024),
        max_files = MAX_LOG_FILES,
        "Logging system initialized"
    );

    // Which engines, and why. Without this a tunnel failure in a log could not
    // be pinned on the native engine or on gcloud, and a forgotten environment
    // variable overriding Settings left no trace anywhere. A line of its own:
    // the one above identifies the process and never changes, while engines
    // can switch at runtime — later changes are logged by `set_stored`.
    let engines: Vec<_> = EngineSlot::ALL
        .into_iter()
        .map(|slot| (slot, crate::engine_pref::engine_with_source(slot)))
        .collect();
    tracing::info!(engines = ?engines_label(&engines), "Engines in force at startup");

    Ok(())
}

/// The engines line: `slot=engine[origin]` per slot, the origin named by what
/// you would go and change. Names only — never a value read from the
/// environment, never a path.
fn engines_label(engines: &[(EngineSlot, Resolved)]) -> String {
    engines
        .iter()
        .map(|(slot, resolved)| {
            let source = match resolved.source {
                EngineSource::Env => format!("env {}", slot.env_var()),
                EngineSource::File => crate::engine_pref::PREF_FILE.to_string(),
                EngineSource::Default => "default".to_string(),
            };
            let ignored = if resolved.env_ignored {
                format!("; {} set but not understood", slot.env_var())
            } else {
                String::new()
            };
            format!("{}={}[{}{}]", slot.key(), resolved.engine.as_str(), source, ignored)
        })
        .collect::<Vec<_>>()
        .join(" ")
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
/// How long the process has been up, worded for someone reading the log later.
fn uptime_label(started: Option<std::time::Instant>, now: std::time::Instant) -> String {
    let Some(started) = started else {
        return "unknown".to_string();
    };
    let secs = now.saturating_duration_since(started).as_secs();
    match secs {
        s if s < 60 => format!("{}s", s),
        s if s < 3600 => format!("{}m {}s", s / 60, s % 60),
        s => format!("{}h {}m {}s", s / 3600, (s % 3600) / 60, s % 60),
    }
}

/// Record that this process is ending on purpose, and flush the log.
///
/// A crash cannot be logged: SIGKILL and SIGSEGV give no chance to write
/// anything. So this line is not really about the exits it records — it is
/// about the ones it doesn't. A log that ends without it did not end by the
/// user closing the window, and that distinction is the one a whole debugging
/// session went without: the app "fell over" and the log looked exactly like a
/// normal quit, because nothing was ever written on either path.
///
/// For the same reason this drops the writer's guard afterwards. Nothing else
/// should be logged past this point, and an unflushed queue would forge the
/// very absence the line exists to make meaningful.
pub fn log_shutdown(reason: &str) {
    tracing::info!(
        reason,
        uptime = %uptime_label(STARTED.get().copied(), std::time::Instant::now()),
        app_version = APP_VERSION.get().map(String::as_str).unwrap_or("unknown"),
        "Shutting down"
    );
    // Dropping the guard flushes the background writer.
    if let Ok(mut held) = LOGGER_GUARD.lock() {
        held.take();
    }
}

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
    all_logs.push_str("=== Lightweight Cloud Connector - Log Export ===\n");
    all_logs.push_str(&format!("Generated: {}\n", chrono::Local::now()));
    all_logs.push_str("==================================\n\n");

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
            all_logs.push('\n');
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
    use crate::engine_pref::Engine;

    #[test]
    fn test_log_directory_path() {
        let log_dir = get_log_directory().unwrap();
        assert!(log_dir.to_string_lossy().contains("lightweight_cloud_connector"));
        assert!(log_dir.to_string_lossy().contains("logs"));
    }

    /// The shutdown line's whole job is to be readable a week later by whoever
    /// is asking "did the app crash or did I close it?". Raw seconds make that
    /// person do arithmetic; these don't.
    #[test]
    fn uptime_reads_as_time_not_as_a_number_of_seconds() {
        let start = std::time::Instant::now();
        let at = |secs: u64| start + std::time::Duration::from_secs(secs);

        assert_eq!(uptime_label(Some(start), at(0)), "0s");
        assert_eq!(uptime_label(Some(start), at(42)), "42s");
        assert_eq!(uptime_label(Some(start), at(65)), "1m 5s");
        assert_eq!(uptime_label(Some(start), at(3600)), "1h 0m 0s");
        assert_eq!(uptime_label(Some(start), at(7325)), "2h 2m 5s");
    }

    /// A shutdown asked for before logging ever came up is itself a finding, so
    /// it says so instead of claiming an uptime of zero — which would read as a
    /// crash on startup.
    #[test]
    fn an_uninitialized_start_says_so_rather_than_claiming_zero() {
        assert_eq!(uptime_label(None, std::time::Instant::now()), "unknown");
    }

    /// Clocks are not required to move backwards, but `Instant` arithmetic on a
    /// suspended machine has surprised better code than this. Never panic on
    /// the exit path: a panic here would replace the diagnostic line with a
    /// crash, which is precisely the confusion it exists to remove.
    #[test]
    fn a_now_before_the_start_does_not_panic() {
        let start = std::time::Instant::now();
        assert_eq!(uptime_label(Some(start + std::time::Duration::from_secs(5)), start), "0s");
    }

    fn resolved(engine: Engine, source: EngineSource, env_ignored: bool) -> Resolved {
        Resolved { engine, source, env_ignored }
    }

    /// Cada origen se nombra por lo que habría que ir a cambiar, y el de
    /// entorno nombra la variable de SU ranura: con la de otra, el lector
    /// iría a quitar una variable que no está puesta.
    #[test]
    fn the_engines_line_names_each_engine_and_where_it_came_from() {
        let label = engines_label(&[
            (EngineSlot::Auth, resolved(Engine::Native, EngineSource::Default, false)),
            (EngineSlot::Tunnel, resolved(Engine::Gcloud, EngineSource::Env, false)),
            (EngineSlot::SshForward, resolved(Engine::Native, EngineSource::File, false)),
        ]);
        assert_eq!(
            label,
            "auth=native[default] tunnel=gcloud[env LCC_TUNNEL_ENGINE] ssh_forward=native[engine.json]"
        );
    }

    /// Una variable que no se entiende no mueve el motor, pero tiene que
    /// verse: quien la puso cree haberlo forzado. Se nombra la variable,
    /// nunca su valor.
    #[test]
    fn an_ignored_environment_variable_is_named_beside_the_real_source() {
        let label = engines_label(&[
            (EngineSlot::SshForward, resolved(Engine::Gcloud, EngineSource::File, true)),
        ]);
        assert_eq!(
            label,
            "ssh_forward=gcloud[engine.json; LCC_SSH_FORWARD_ENGINE set but not understood]"
        );
    }
}
