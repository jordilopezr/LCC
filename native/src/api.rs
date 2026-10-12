// Re-export all public functions and types from other modules
// This module is scanned by flutter_rust_bridge_codegen

// Sprint 10.5: License types removed

pub use crate::gcloud::*;
pub use crate::rdp_client::{RdpClientType, RdpSettings, RdpLaunchResult};
pub use crate::vnc_client::{VncClientType, VncSettings, VncLaunchResult, VncQuality};
pub use crate::db_client::{DatabaseType, DbClientType, DbConnectionSettings, DbLaunchResult};
pub use crate::sshfs_mount::{SshfsMountOptions, SshfsMount, MountResult, UnmountResult, SshfsStatus, FileManagerInfo};
pub use crate::sftp::*;
pub use crate::tunnel::*;
pub use crate::logging::*;

// Re-export types from gcp_rest_client
pub use crate::gcp_rest_client::{GcpProjectClientLib, GcpInstanceClientLib};

// Wrapper functions for gcp_rest_client (flutter_rust_bridge needs explicit functions in api module)
pub async fn test_gcp_authentication() -> anyhow::Result<String> {
    crate::gcp_rest_client::test_authentication_async().await
}

pub async fn list_projects_client_lib() -> anyhow::Result<Vec<GcpProjectClientLib>> {
    crate::gcp_rest_client::list_projects_simple_async().await
}

pub async fn benchmark_projects_listing() -> anyhow::Result<String> {
    crate::gcp_rest_client::benchmark_list_projects_async().await
}

pub async fn list_instances_client_lib(project_id: String) -> anyhow::Result<Vec<GcpInstanceClientLib>> {
    crate::gcp_rest_client::list_instances_client_lib(&project_id).await
}

pub async fn start_instance_client_lib(project_id: String, zone: String, instance_name: String) -> anyhow::Result<()> {
    crate::gcp_rest_client::start_instance_client_lib(&project_id, &zone, &instance_name).await
}

pub async fn stop_instance_client_lib(project_id: String, zone: String, instance_name: String) -> anyhow::Result<()> {
    crate::gcp_rest_client::stop_instance_client_lib(&project_id, &zone, &instance_name).await
}

pub async fn reset_instance_client_lib(project_id: String, zone: String, instance_name: String) -> anyhow::Result<()> {
    crate::gcp_rest_client::reset_instance_client_lib(&project_id, &zone, &instance_name).await
}

pub async fn suspend_instance_client_lib(project_id: String, zone: String, instance_name: String) -> anyhow::Result<()> {
    crate::gcp_rest_client::suspend_instance_client_lib(&project_id, &zone, &instance_name).await
}

pub async fn resume_instance_client_lib(project_id: String, zone: String, instance_name: String) -> anyhow::Result<()> {
    crate::gcp_rest_client::resume_instance_client_lib(&project_id, &zone, &instance_name).await
}

/// Get a single instance by project, zone, and name.
/// Uses compute.instances.get permission (doesn't require compute.instances.list).
pub async fn get_instance_client_lib(project_id: String, zone: String, instance_name: String) -> anyhow::Result<GcpInstanceClientLib> {
    crate::gcp_rest_client::get_instance_client_lib(&project_id, &zone, &instance_name).await
}

/// Get a single instance using gcloud CLI (fallback when REST API fails due to auth).
/// Uses gcloud compute instances describe which uses different authentication.
pub async fn get_instance_gcloud(project_id: String, zone: String, instance_name: String) -> anyhow::Result<crate::gcloud::GcpInstance> {
    crate::gcloud::get_instance_async(&project_id, &zone, &instance_name).await
}

// Wrapper functions for gcloud module (CLI-based functions)
pub fn check_gcloud_installed() -> bool {
    crate::gcloud::is_gcloud_installed()
}

pub fn check_gcloud_auth() -> bool {
    crate::gcloud::is_gcloud_authenticated()
}

/// Get the email of the currently active GCP account.
pub async fn get_gcloud_account_email() -> anyhow::Result<String> {
    crate::accounts::active_email().await
}

pub async fn list_projects() -> anyhow::Result<Vec<crate::gcloud::GcpProject>> {
    let projects = crate::gcp_rest_client::list_projects_simple_async().await?;
    Ok(projects.into_iter().map(|p| crate::gcloud::GcpProject {
        project_id: p.project_id,
        name: p.name,
    }).collect())
}

pub async fn list_instances(project_id: String) -> anyhow::Result<Vec<crate::gcloud::GcpInstance>> {
    let instances = crate::gcp_rest_client::list_instances_client_lib(&project_id).await?;
    Ok(instances.into_iter().map(|i| crate::gcloud::GcpInstance {
        name: i.name,
        status: i.status,
        zone: i.zone,
        machine_type: i.machine_type,
        cpu_count: i.cpu_count,
        memory_mb: i.memory_mb,
        disk_gb: i.disk_gb,
        labels: i.labels,
        os_login_enabled: i.os_login_enabled,
        is_windows: i.is_windows,
        internal_ip: i.internal_ip,
        external_ip: i.external_ip,
    }).collect())
}

// ==========================================
// Multi-Account Management (Sprint 8)
// ==========================================

/// List all authenticated accounts
pub async fn list_gcloud_accounts() -> anyhow::Result<Vec<crate::gcloud::GcloudAccount>> {
    crate::accounts::list().await
}

/// Switch the active account
pub async fn switch_gcloud_account(email: String) -> anyhow::Result<()> {
    crate::accounts::switch(&email).await
}

/// Add a new account (opens browser)
pub async fn add_gcloud_account() -> anyhow::Result<()> {
    crate::accounts::add().await
}

/// Remove an account: revoked at Google, then forgotten locally
pub async fn remove_gcloud_account(email: String) -> anyhow::Result<()> {
    crate::accounts::remove(&email).await
}

/// Log out every stored account: revoked at Google, then forgotten locally.
pub async fn log_out_all() -> anyhow::Result<()> {
    crate::accounts::log_out_all().await
}

/// List projects for a specific account (without changing global config)
pub async fn list_projects_for_account(email: String) -> anyhow::Result<Vec<crate::gcloud::GcpProject>> {
    crate::accounts::projects_for(&email).await
}

/// Whether gcloud is present, and whether there is a usable session.
///
/// One call rather than two, because under the native engine "is there a
/// session" must not be gated on gcloud being installed — and that decision
/// belongs where the engine flag lives.
pub async fn check_auth_status() -> crate::accounts::AuthStatus {
    crate::accounts::auth_status().await
}

pub async fn start_instance(project_id: String, zone: String, instance_name: String) -> anyhow::Result<()> {
    crate::gcp_rest_client::start_instance_client_lib(&project_id, &zone, &instance_name).await
}

pub async fn stop_instance(project_id: String, zone: String, instance_name: String) -> anyhow::Result<()> {
    crate::gcp_rest_client::stop_instance_client_lib(&project_id, &zone, &instance_name).await
}

pub async fn reset_instance(project_id: String, zone: String, instance_name: String) -> anyhow::Result<()> {
    crate::gcp_rest_client::reset_instance_client_lib(&project_id, &zone, &instance_name).await
}

pub async fn suspend_instance(project_id: String, zone: String, instance_name: String) -> anyhow::Result<()> {
    crate::gcp_rest_client::suspend_instance_client_lib(&project_id, &zone, &instance_name).await
}

pub async fn resume_instance(project_id: String, zone: String, instance_name: String) -> anyhow::Result<()> {
    crate::gcp_rest_client::resume_instance_client_lib(&project_id, &zone, &instance_name).await
}

/// Check if a machine type supports the suspend operation
pub fn check_suspend_support(machine_type: String) -> bool {
    crate::gcloud::machine_type_supports_suspend(&machine_type)
}

/// Convert GCP email to OS Login username format
pub fn email_to_oslogin_username(email: String) -> String {
    crate::gcloud::email_to_oslogin_username(&email)
}

pub fn launch_ssh(project_id: String, zone: String, instance_name: String) -> anyhow::Result<()> {
    crate::gcloud::launch_ssh(&project_id, &zone, &instance_name)
}

pub fn launch_sftp(port: u16, username: Option<String>) -> anyhow::Result<()> {
    crate::gcloud::launch_sftp_browser(port, username)
}

// Add other missing functions
pub fn greet() -> String {
    "Hello from Lightweight Cloud Connector!".to_string()
}

// Wrapper functions for tunnel module

/// Error crossing the bridge: a stable code plus untranslated diagnostic detail.
pub struct TunnelFailure {
    pub code: String,
    pub detail: Option<String>,
    /// The engine that failed ("native" or "gcloud"), or None when the start
    /// failed before any engine ran.
    pub engine: Option<String>,
}

/// Carry a tunnel failure across the bridge with its code intact.
///
/// `protocol_error` is the fallback for a failure that carries no type — it
/// renders as "the IAP relay answered unexpectedly", which is a claim about
/// Google's side of the wire. Applying it to *every* failure, as the SSH
/// forward used to, sends a user whose own machine is holding the local port
/// to go and investigate the relay.
fn tunnel_failure(err: anyhow::Error) -> TunnelFailure {
    match err.downcast_ref::<crate::iap_tunnel::TunnelError>() {
        Some(tunnel_error) => TunnelFailure {
            code: tunnel_error.code().to_string(),
            detail: tunnel_error.detail(),
            engine: None,
        },
        None => TunnelFailure {
            code: "protocol_error".to_string(),
            detail: Some(err.to_string()),
            engine: None,
        },
    }
}

/// A failed start across the bridge: [`tunnel_failure`]'s code and detail,
/// plus the engine that was trying, so the tunnel manager can name it on the
/// errored row.
fn start_failure(failure: crate::tunnel::StartFailure) -> TunnelFailure {
    TunnelFailure {
        engine: failure.engine.map(|engine| engine.as_str().to_string()),
        ..tunnel_failure(failure.error)
    }
}

/// A tunnel or forward that is up, and the engine holding it: "native" or
/// "gcloud". The engine is the entry's own — including when an existing entry
/// is reused — so the tunnel manager can say which engine to look at even
/// after the selected engine has changed.
pub struct StartedConnection {
    pub local_port: u16,
    pub engine: String,
}

fn started_connection(started: crate::tunnel::Started) -> StartedConnection {
    StartedConnection { local_port: started.local_port, engine: started.engine.as_str().to_string() }
}

pub fn start_connection(
    project_id: String,
    zone: String,
    instance_name: String,
    remote_port: u16,
    local_port: Option<u16>,
) -> Result<StartedConnection, TunnelFailure> {
    crate::tunnel::start_tunnel(&project_id, &zone, &instance_name, remote_port, local_port)
        .map(started_connection)
        .map_err(start_failure)
}

pub fn stop_connection(instance_name: String, remote_port: u16) -> anyhow::Result<()> {
    crate::tunnel::stop_tunnel(&instance_name, remote_port)
}

/// `identity_file` is the key file already proven to work for `username` on
/// this VM, as reported by `probe_ssh_access`/`provision_ssh_access`. `None`
/// means the SSH agent authenticated, and the candidate ladder is right.
pub fn start_ssh_forward(
    project_id: String,
    zone: String,
    instance_name: String,
    remote_port: u16,
    local_port: Option<u16>,
    username: String,
    identity_file: Option<String>,
) -> Result<StartedConnection, TunnelFailure> {
    crate::tunnel::start_ssh_forward(&project_id, &zone, &instance_name, remote_port, local_port, &username, identity_file.as_deref())
        .map(started_connection)
        .map_err(start_failure)
}

pub fn stop_ssh_forward(instance_name: String, remote_port: u16) -> anyhow::Result<()> {
    crate::tunnel::stop_ssh_forward(&instance_name, remote_port)
}

pub fn check_connection_health(instance_name: String, remote_port: u16) -> anyhow::Result<bool> {
    crate::tunnel::check_tunnel_health(&instance_name, remote_port)
}

// ==========================================
// Sprint 9: Tunnel Manager & Network Resilience
// ==========================================

/// Measure tunnel latency via TCP connect RTT to local port.
/// Returns latency in milliseconds.
pub fn measure_connection_latency(instance_name: String, remote_port: u16) -> anyhow::Result<u64> {
    crate::tunnel::measure_tunnel_latency(&instance_name, remote_port)
}

/// Clean up dead tunnel processes. Returns list of cleaned-up tunnel keys.
pub fn cleanup_dead_connections() -> anyhow::Result<Vec<String>> {
    crate::tunnel::cleanup_dead_tunnels()
}

/// Refresh a tunnel's idle timer by its local port. Used by UIs (e.g. the SFTP
/// browser) that hold a tunnel open but may have no active TCP connection
/// between stateless operations, so the idle reaper doesn't close it from
/// under them.
pub fn touch_tunnel(local_port: u16) {
    crate::tunnel::touch_tunnel_by_local_port(local_port);
}

// Wrapper functions for rdp_client module
pub fn launch_rdp(port: u16, instance_name: String, settings: crate::rdp_client::RdpSettings) -> anyhow::Result<crate::rdp_client::RdpLaunchResult> {
    crate::rdp_client::launch_rdp_client(port, &instance_name, settings)
}

pub fn get_available_rdp_clients() -> Vec<crate::rdp_client::RdpClientType> {
    use crate::rdp_client::RdpClientType;

    RdpClientType::fallback_order()
        .into_iter()
        .filter(|client| client.is_available())
        .collect()
}

/// Clean up old temporary RDP configuration files
///
/// This function should be called at application startup to remove
/// old config files that may contain sensitive data (usernames, domains).
/// Files older than 1 hour are automatically removed.
///
/// # Returns
/// - Number of files cleaned up
pub fn cleanup_rdp_config_files() -> anyhow::Result<u32> {
    let count = crate::rdp_client::cleanup_old_config_files()?;
    Ok(count as u32)
}

/// Remove a specific RDP config file by instance name
///
/// Call this when closing an RDP connection to immediately clean up
/// the temporary configuration file.
pub fn remove_rdp_config_file(instance_name: String) -> anyhow::Result<()> {
    crate::rdp_client::remove_config_file(&instance_name)
}

// Wrapper functions for vnc_client module
pub fn launch_vnc(port: u16, instance_name: String, settings: crate::vnc_client::VncSettings) -> anyhow::Result<crate::vnc_client::VncLaunchResult> {
    crate::vnc_client::launch_vnc_client(port, &instance_name, settings)
}

pub fn get_available_vnc_clients() -> Vec<crate::vnc_client::VncClientType> {
    use crate::vnc_client::VncClientType;

    VncClientType::fallback_order()
        .into_iter()
        .filter(|client| client.is_available())
        .collect()
}

// Wrapper functions for logging module
pub fn init_logging_system(app_version: String) -> anyhow::Result<()> {
    crate::logging::init_logging(&app_version)
}

/// Record a deliberate exit. `reason` names which path asked for it, so the
/// three window-close branches stay distinguishable in the log.
///
/// Called on every clean exit precisely so that its absence means something.
pub fn log_shutdown(reason: String) {
    crate::logging::log_shutdown(&reason);
}

pub fn export_logs_to_file() -> anyhow::Result<String> {
    let path = crate::logging::export_logs()?;
    Ok(path.to_string_lossy().to_string())
}

pub fn get_log_file_path() -> anyhow::Result<String> {
    let path = crate::logging::get_current_log_path()?;
    Ok(path.to_string_lossy().to_string())
}

// Wrapper functions for SFTP module
pub fn sftp_list_dir(host: String, port: u16, username: String, identity_file: Option<String>, remote_path: String) -> anyhow::Result<Vec<crate::sftp::RemoteFileEntry>> {
    crate::sftp::sftp_list_directory(host, port, username, identity_file, remote_path)
}

pub fn sftp_download(host: String, port: u16, username: String, identity_file: Option<String>, remote_path: String, local_path: String, transfer_id: u32) -> anyhow::Result<u64> {
    crate::sftp::sftp_download_file(host, port, username, identity_file, remote_path, local_path, transfer_id)
}

pub fn sftp_upload(host: String, port: u16, username: String, identity_file: Option<String>, local_path: String, remote_path: String) -> anyhow::Result<u64> {
    crate::sftp::sftp_upload_file(host, port, username, identity_file, local_path, remote_path)
}

/// Streaming upload: emits byte-level progress so the UI can show a progress bar.
pub fn sftp_upload_streaming(
    host: String,
    port: u16,
    username: String,
    identity_file: Option<String>,
    local_path: String,
    remote_path: String,
    transfer_id: u32,
    sink: crate::frb_generated::StreamSink<crate::sftp::SftpProgress>,
) -> anyhow::Result<()> {
    crate::sftp::sftp_upload_file_streaming(host, port, username, identity_file, local_path, remote_path, transfer_id, sink)
}

/// Parallel upload: K SSH connections write ranges; emits aggregate progress.
pub fn sftp_upload_parallel(
    host: String,
    port: u16,
    username: String,
    identity_file: Option<String>,
    local_path: String,
    remote_path: String,
    concurrency: Option<u8>,
    transfer_id: u32,
    sink: crate::frb_generated::StreamSink<crate::sftp::SftpProgress>,
) -> anyhow::Result<()> {
    crate::sftp::sftp_upload_file_parallel(
        host, port, username, identity_file, local_path, remote_path, concurrency, transfer_id, sink,
    )
}

/// Parallel download: K SSH connections read ranges; emits aggregate progress.
pub fn sftp_download_parallel(
    host: String,
    port: u16,
    username: String,
    identity_file: Option<String>,
    remote_path: String,
    local_path: String,
    concurrency: Option<u8>,
    transfer_id: u32,
    sink: crate::frb_generated::StreamSink<crate::sftp::SftpProgress>,
) -> anyhow::Result<()> {
    crate::sftp::sftp_download_file_parallel(
        host, port, username, identity_file, remote_path, local_path, concurrency, transfer_id, sink,
    )
}

pub fn sftp_cancel_transfer(transfer_id: u32) {
    crate::sftp::sftp_cancel_transfer(transfer_id);
}

pub fn sftp_mkdir(host: String, port: u16, username: String, identity_file: Option<String>, remote_path: String) -> anyhow::Result<()> {
    crate::sftp::sftp_create_directory(host, port, username, identity_file, remote_path)
}

pub fn sftp_delete(host: String, port: u16, username: String, identity_file: Option<String>, remote_path: String, is_directory: bool) -> anyhow::Result<()> {
    crate::sftp::sftp_delete(host, port, username, identity_file, remote_path, is_directory)
}

pub fn get_username() -> anyhow::Result<String> {
    crate::sftp::get_current_username()
}

// Re-export types from diagnostics module (Sprint 3)
pub use crate::diagnostics::{
    SerialPortOutput, SerialPortNumber,
    VmDiagnostics, GuestAgentStatus, NetworkInterface, DiskStatus,
    AuditLogEntry, AuditLogFilter
};

// Wrapper functions for diagnostics module (Sprint 3)

/// Get serial port output from a VM instance
///
/// # Arguments
/// * `project_id` - Project ID
/// * `zone` - Zone name (e.g., "us-central1-a")
/// * `instance_name` - Instance name
/// * `port` - Serial port number (1-4, default 1)
/// * `start` - Optional start position for incremental fetch
pub async fn get_serial_output(
    project_id: String,
    zone: String,
    instance_name: String,
    port: u8,
    start: Option<i64>,
) -> anyhow::Result<SerialPortOutput> {
    crate::diagnostics::get_serial_port_output(project_id, zone, instance_name, port, start).await
}

/// Get detailed VM diagnostics including network, disk, and guest agent status
pub async fn get_instance_diagnostics(
    project_id: String,
    zone: String,
    instance_name: String,
) -> anyhow::Result<VmDiagnostics> {
    crate::diagnostics::get_vm_diagnostics(project_id, zone, instance_name).await
}

/// Get audit logs for a project, optionally filtered by instance
///
/// # Arguments
/// * `project_id` - Project ID
/// * `instance_name` - Optional instance name to filter by
/// * `max_entries` - Maximum number of entries (default 100)
/// * `hours_ago` - Hours to look back (default 24)
pub async fn get_instance_audit_logs(
    project_id: String,
    instance_name: Option<String>,
    max_entries: Option<u32>,
    hours_ago: Option<u32>,
) -> anyhow::Result<Vec<AuditLogEntry>> {
    crate::diagnostics::get_audit_logs(project_id, instance_name, max_entries, hours_ago).await
}

// ==========================================
// Database Client Wrappers (Sprint 4)
// ==========================================

/// Launch a database client with the specified connection settings
///
/// This function creates an IAP tunnel to the remote database and launches
/// the appropriate SQL client with the connection pre-configured.
///
/// # Arguments
/// * `settings` - Database connection settings including type, host, port, etc.
///
/// # Returns
/// * `DbLaunchResult` - Information about which client was launched
pub fn launch_db(settings: DbConnectionSettings) -> anyhow::Result<DbLaunchResult> {
    crate::db_client::launch_db_client(settings)
}

/// Get all database clients available on the system
///
/// Scans for installed database clients (native and Flatpak).
///
/// # Returns
/// * List of available `DbClientType` values
pub fn get_available_db_clients() -> Vec<DbClientType> {
    crate::db_client::get_available_db_clients()
}

/// Get available clients for a specific database type
///
/// # Arguments
/// * `db_type` - The database type to get clients for
///
/// # Returns
/// * List of available `DbClientType` values that support the given database type
pub fn get_available_clients_for_db_type(db_type: DatabaseType) -> Vec<DbClientType> {
    crate::db_client::get_available_clients_for_db(db_type)
}

/// Get the default port for a database type
///
/// # Arguments
/// * `db_type` - The database type
///
/// # Returns
/// * Default port number (e.g., 3306 for MySQL, 5432 for PostgreSQL)
pub fn get_default_db_port(db_type: DatabaseType) -> u16 {
    db_type.default_port()
}

/// Get all supported database types
///
/// # Returns
/// * List of all `DatabaseType` values
pub fn get_all_database_types() -> Vec<DatabaseType> {
    DatabaseType::all()
}

/// Clean up old database client configuration files
///
/// Files older than 1 hour are automatically removed.
///
/// # Returns
/// * Number of files cleaned up
pub fn cleanup_db_config_files() -> anyhow::Result<u32> {
    let count = crate::db_client::cleanup_old_config_files()?;
    Ok(count as u32)
}

// ==========================================
// Windows Credentials Wrappers (Sprint 5)
// ==========================================

// Re-export types from windows_credentials module
pub use crate::windows_credentials::WindowsCredential;

/// Generate a new Windows password for a VM instance
///
/// This function:
/// 1. Generates an RSA key pair
/// 2. Sends the public key to the VM's metadata
/// 3. Waits for the Windows guest agent to generate the password
/// 4. Decrypts the password
/// 5. Stores the credential securely in the system keyring
///
/// # Arguments
/// * `project_id` - GCP project ID
/// * `zone` - Compute Engine zone (e.g., "us-central1-a")
/// * `instance_name` - Name of the Windows VM instance
/// * `username` - Windows username to generate password for
/// * `email` - Email address (for GCP tracking)
///
/// # Returns
/// * `WindowsCredential` containing the username and generated password
pub async fn generate_windows_password(
    project_id: String,
    zone: String,
    instance_name: String,
    username: String,
    email: String,
) -> anyhow::Result<WindowsCredential> {
    crate::windows_credentials::generate_windows_password(
        &project_id,
        &zone,
        &instance_name,
        &username,
        &email,
    ).await
}

/// Reset an existing Windows password for a VM instance
///
/// Same as generate_windows_password but deletes any existing stored credential first.
pub async fn reset_windows_password(
    project_id: String,
    zone: String,
    instance_name: String,
    username: String,
    email: String,
) -> anyhow::Result<WindowsCredential> {
    crate::windows_credentials::reset_windows_password(
        &project_id,
        &zone,
        &instance_name,
        &username,
        &email,
    ).await
}

/// Get a stored Windows credential for an instance
///
/// # Arguments
/// * `project_id` - GCP project ID
/// * `zone` - Compute Engine zone
/// * `instance_name` - Name of the VM instance
///
/// # Returns
/// * `Some(WindowsCredential)` if found, `None` otherwise
pub fn get_stored_windows_credential(
    project_id: String,
    zone: String,
    instance_name: String,
) -> Option<WindowsCredential> {
    crate::windows_credentials::get_stored_credential(&project_id, &zone, &instance_name)
}

/// Get all stored Windows credentials
///
/// # Returns
/// * List of all stored WindowsCredential objects
pub fn get_all_windows_credentials() -> Vec<WindowsCredential> {
    crate::windows_credentials::get_all_stored_credentials()
}

/// Delete a stored Windows credential
///
/// # Arguments
/// * `project_id` - GCP project ID
/// * `zone` - Compute Engine zone
/// * `instance_name` - Name of the VM instance
pub fn delete_windows_credential(
    project_id: String,
    zone: String,
    instance_name: String,
) -> anyhow::Result<()> {
    crate::windows_credentials::delete_stored_credential(&project_id, &zone, &instance_name)
}

/// Clear all stored Windows credentials
///
/// # Returns
/// * Number of credentials deleted
pub fn clear_all_windows_credentials() -> anyhow::Result<u32> {
    crate::windows_credentials::clear_all_credentials()
}

/// Check if an instance is a Windows VM
///
/// # Arguments
/// * `project_id` - GCP project ID
/// * `zone` - Compute Engine zone
/// * `instance_name` - Name of the VM instance
///
/// # Returns
/// * `true` if the instance is a Windows VM, `false` otherwise
pub async fn is_windows_instance(
    project_id: String,
    zone: String,
    instance_name: String,
) -> anyhow::Result<bool> {
    crate::windows_credentials::check_is_windows_instance(&project_id, &zone, &instance_name).await
}

// ============================================================================
// Sprint 6: SSHFS Mount Functions
// ============================================================================

/// Check SSHFS installation status
///
/// Returns information about sshfs availability, FUSE support,
/// and any issues detected.
pub fn get_sshfs_status() -> SshfsStatus {
    crate::sshfs_mount::get_sshfs_status()
}

/// Mount a remote directory via SSHFS through an IAP tunnel
///
/// # Arguments
/// * `project_id` - GCP project ID
/// * `zone` - GCP zone
/// * `instance_name` - VM instance name
/// * `username` - SSH username
/// * `remote_path` - Remote directory to mount (e.g., "/home/user")
/// * `local_mount_point` - Local directory to mount to
/// * `tunnel_port` - Local port of the IAP tunnel
/// * `options` - Mount options
///
/// # Returns
/// * `MountResult` with success status and mount info
pub fn sshfs_mount(
    project_id: String,
    zone: String,
    instance_name: String,
    username: String,
    remote_path: String,
    local_mount_point: String,
    tunnel_port: u16,
    options: SshfsMountOptions,
) -> MountResult {
    crate::sshfs_mount::mount_sshfs(
        &project_id,
        &zone,
        &instance_name,
        &username,
        &remote_path,
        &local_mount_point,
        tunnel_port,
        options,
    )
}

/// Unmount an SSHFS mount point
///
/// # Arguments
/// * `mount_point` - Local mount point path to unmount
///
/// # Returns
/// * `UnmountResult` with success status
pub fn sshfs_unmount(mount_point: String) -> UnmountResult {
    crate::sshfs_mount::unmount_sshfs(&mount_point)
}

/// Unmount by mount ID
///
/// # Arguments
/// * `mount_id` - The unique mount ID
///
/// # Returns
/// * `UnmountResult` with success status
pub fn sshfs_unmount_by_id(mount_id: String) -> UnmountResult {
    crate::sshfs_mount::unmount_by_id(&mount_id)
}

/// Get all active SSHFS mounts
///
/// # Returns
/// * List of active `SshfsMount` objects
pub fn get_active_sshfs_mounts() -> Vec<SshfsMount> {
    crate::sshfs_mount::get_active_mounts()
}

/// Get active mounts for a specific instance
///
/// # Arguments
/// * `project_id` - GCP project ID
/// * `instance_name` - VM instance name
///
/// # Returns
/// * List of `SshfsMount` objects for the instance
pub fn get_sshfs_mounts_for_instance(project_id: String, instance_name: String) -> Vec<SshfsMount> {
    crate::sshfs_mount::get_mounts_for_instance(&project_id, &instance_name)
}

/// Verify if a mount is still active
///
/// # Arguments
/// * `mount_id` - The unique mount ID
///
/// # Returns
/// * `true` if mount is active, `false` otherwise
pub fn verify_sshfs_mount_active(mount_id: String) -> bool {
    crate::sshfs_mount::verify_mount_active(&mount_id)
}

/// Refresh status of all mounts
///
/// Checks all registered mounts and updates their status,
/// removing any that are no longer mounted.
///
/// # Returns
/// * List of currently active `SshfsMount` objects
pub fn refresh_sshfs_mount_status() -> Vec<SshfsMount> {
    crate::sshfs_mount::refresh_mount_status()
}

/// Unmount all active SSHFS mounts
///
/// Used for cleanup when closing the application.
///
/// # Returns
/// * List of `UnmountResult` for each mount
pub fn sshfs_unmount_all() -> Vec<UnmountResult> {
    crate::sshfs_mount::unmount_all()
}

/// Open a mount in the file manager
///
/// # Arguments
/// * `mount_id` - The unique mount ID
/// * `file_manager` - Optional file manager command (uses default if None)
pub fn open_sshfs_mount_in_file_manager(mount_id: String, file_manager: Option<String>) -> anyhow::Result<()> {
    crate::sshfs_mount::open_mount_in_file_manager(&mount_id, file_manager.as_deref())
}

/// Get available file managers
///
/// # Returns
/// * List of `FileManagerInfo` with installed status
pub fn get_available_file_managers() -> Vec<FileManagerInfo> {
    crate::sshfs_mount::get_available_file_managers()
}

/// Get default mount point for a VM
///
/// Creates a path like ~/gcp-mounts/{instance_name}_{remote_path}
///
/// # Arguments
/// * `instance_name` - VM instance name
/// * `remote_path` - Remote directory path
///
/// # Returns
/// * Suggested mount point path
pub fn get_default_sshfs_mount_point(instance_name: String, remote_path: String) -> anyhow::Result<String> {
    let path = crate::sshfs_mount::get_default_mount_point(&instance_name, &remote_path)?;
    Ok(path.to_string_lossy().to_string())
}

/// Validate a remote path
///
/// Checks for path traversal attempts and normalizes the path.
///
/// # Arguments
/// * `path` - Remote path to validate
///
/// # Returns
/// * Normalized path or error
pub fn validate_sshfs_remote_path(path: String) -> anyhow::Result<String> {
    crate::sshfs_mount::validate_remote_path(&path)
}

/// Validate a local mount point
///
/// Ensures the path is safe and in a user-writable location.
///
/// # Arguments
/// * `path` - Local path to validate
///
/// # Returns
/// * Validated path or error
pub fn validate_sshfs_local_path(path: String) -> anyhow::Result<String> {
    let validated = crate::sshfs_mount::validate_local_mount_point(&path)?;
    Ok(validated.to_string_lossy().to_string())
}

// ============================================================================
// Sprint 7: Connectivity Doctor
// ============================================================================

// Re-export types from doctor module
pub use crate::doctor::{
    DoctorCheckStatus, DoctorCheckCategory,
    DoctorCheckResult, DoctorReport,
};

/// Run all connectivity doctor checks for a VM instance
///
/// Executes 10 diagnostic checks grouped in 5 categories:
/// Authentication, Project/Permissions, IAP/Network, VM Status, Local Environment.
///
/// # Arguments
/// * `project_id` - GCP project ID
/// * `zone` - Compute Engine zone
/// * `instance_name` - VM instance name
///
/// # Returns
/// * `DoctorReport` with all check results and summary
pub async fn run_doctor(
    project_id: String,
    zone: String,
    instance_name: String,
) -> anyhow::Result<DoctorReport> {
    crate::doctor::run_doctor(project_id, zone, instance_name).await
}

/// Generate a Markdown report from doctor results
///
/// # Arguments
/// * `report` - The doctor report to format
///
/// # Returns
/// * Markdown string with formatted report
pub fn generate_doctor_report(report: DoctorReport) -> String {
    crate::doctor::generate_doctor_report(report)
}

/// Execute a doctor fix action
///
/// # Arguments
/// * `fix_action_id` - The fix action to execute (e.g., "re_authenticate", "start_vm")
/// * `project_id` - GCP project ID
/// * `zone` - Compute Engine zone
/// * `instance_name` - VM instance name
///
/// # Returns
/// * Success message string
pub async fn execute_doctor_fix(
    fix_action_id: String,
    project_id: String,
    zone: String,
    instance_name: String,
) -> anyhow::Result<String> {
    crate::doctor::execute_fix(fix_action_id, project_id, zone, instance_name).await
}

/// Open the browser to refresh an expired session. Surfaced by the in-app
/// "Re-authenticate" banner.
///
/// Which sign-in runs depends on the auth engine, so the choice lives in
/// `accounts`, with the rest of the dispatch. This used to call
/// `gcloud auth login` unconditionally, which writes gcloud's credentials and
/// never the native token store: under the native engine the button could not
/// do the one thing its label promises.
pub async fn reauthenticate() -> anyhow::Result<()> {
    crate::accounts::reauthenticate().await
}

// Sprint 10.5: License Verification removed

// ============================================================================
// Sprint 16: VM Snapshot Manager
// ============================================================================

// Re-export GcpSnapshot type for the bridge
pub use crate::snapshots::GcpSnapshot;

/// Get the boot disk name for a VM instance by querying gcloud.
pub async fn get_boot_disk_name(
    project_id: String,
    zone: String,
    instance_name: String,
) -> anyhow::Result<String> {
    crate::snapshots::get_boot_disk_name_async(&project_id, &zone, &instance_name).await
}

/// List all snapshots for the boot disk of a VM instance.
pub async fn list_snapshots(
    project_id: String,
    zone: String,
    instance_name: String,
) -> anyhow::Result<Vec<GcpSnapshot>> {
    crate::snapshots::list_snapshots_async(&project_id, &zone, &instance_name).await
}

/// Create a snapshot of the boot disk for a VM instance.
pub async fn create_snapshot(
    project_id: String,
    zone: String,
    instance_name: String,
    snapshot_name: String,
    description: String,
) -> anyhow::Result<()> {
    crate::snapshots::create_snapshot_async(&project_id, &zone, &instance_name, &snapshot_name, &description).await
}

/// Delete a snapshot by name.
pub async fn delete_snapshot(
    project_id: String,
    snapshot_name: String,
) -> anyhow::Result<()> {
    crate::snapshots::delete_snapshot_async(&project_id, &snapshot_name).await
}

/// Create a new disk from an existing snapshot (restore operation).
pub async fn create_disk_from_snapshot(
    project_id: String,
    zone: String,
    snapshot_name: String,
    new_disk_name: String,
) -> anyhow::Result<()> {
    crate::snapshots::create_disk_from_snapshot_async(&project_id, &zone, &snapshot_name, &new_disk_name).await
}

/// The SSH username for this VM, resolved without probing or provisioning.
///
/// Cheap enough to fill a form field on dialog open — one REST call, no tunnel.
pub async fn ssh_username_for(project_id: String, zone: String, instance_name: String)
    -> anyhow::Result<String> {
    crate::ssh_access::ssh_username_for(project_id, zone, instance_name).await
}

/// Whether SSH access to this VM already works, and as which user.
pub async fn probe_ssh_access(project_id: String, zone: String, instance_name: String)
    -> anyhow::Result<crate::ssh_access::SshAccessState> {
    crate::ssh_access::probe_ssh_access(project_id, zone, instance_name).await
}

/// Authorise LCC's key on this VM. Only call after the user has consented.
pub async fn provision_ssh_access(project_id: String, zone: String, instance_name: String)
    -> anyhow::Result<crate::ssh_access::SshCredential> {
    crate::ssh_access::provision_ssh_access(project_id, zone, instance_name).await
}

/// Parse a slot name from Dart, or fail loudly. A typo must not resolve to a
/// default slot: that would read one preference and write another.
fn slot_from_key(slot: &str) -> anyhow::Result<crate::engine_pref::EngineSlot> {
    crate::engine_pref::EngineSlot::from_key(slot)
        .ok_or_else(|| anyhow::anyhow!("Unknown engine slot: {}", slot))
}

/// The bridge speaks the same words as the environment variable, the
/// `engine.json` file and the log line — one mapping, in `engine_pref`. A
/// second copy here could drift from it, and then the string Settings writes
/// would stop matching the string the resolver reads.
fn engine_name(engine: crate::engine_pref::Engine) -> String {
    engine.as_str().to_string()
}

/// The engine actually in force for this slot, with the environment override
/// already applied.
pub fn engine_for(slot: String) -> anyhow::Result<String> {
    Ok(engine_name(crate::engine_pref::engine_for(slot_from_key(&slot)?)))
}

/// The user's explicit choice for this slot, or None when they have never
/// made one.
pub fn stored_engine(slot: String) -> anyhow::Result<Option<String>> {
    Ok(crate::engine_pref::stored(slot_from_key(&slot)?))
}

/// The engine this slot's environment variable is forcing, or None when the
/// environment is not overriding.
pub fn engine_override(slot: String) -> anyhow::Result<Option<String>> {
    Ok(crate::engine_pref::env_override(slot_from_key(&slot)?).map(engine_name))
}

/// The environment variable that outranks the stored choice for this slot.
pub fn engine_env_var(slot: String) -> anyhow::Result<String> {
    Ok(slot_from_key(&slot)?.env_var().to_string())
}

/// Persist the user's choice for one slot.
pub async fn set_engine(slot: String, engine: String) -> anyhow::Result<()> {
    let slot = slot_from_key(&slot)?;
    crate::engine_pref::set_stored(slot, &engine)?;
    // Only the auth slot changes which credentials serve tokens. Invalidating
    // on a tunnel-engine change would be noise pretending to be care.
    if slot == crate::engine_pref::EngineSlot::Auth {
        crate::gcp_rest_client::invalidate_cached_access_token().await;
    }
    Ok(())
}

#[cfg(test)]
mod tunnel_failure_tests {
    use super::*;

    /// The half that was broken: a typed failure keeps its own code, so the UI
    /// can name the port instead of blaming the relay.
    #[test]
    fn a_typed_failure_keeps_its_code_and_detail() {
        let failure = tunnel_failure(anyhow::Error::new(
            crate::iap_tunnel::TunnelError::LocalPortUnavailable { port: 8443 },
        ));
        assert_eq!(failure.code, "local_port_unavailable");
        assert_eq!(failure.detail, Some("8443".to_string()));
    }

    /// And the other half: `protocol_error` still exists, but only for a
    /// failure that genuinely arrived with no type at all.
    #[test]
    fn only_an_untyped_failure_falls_back_to_protocol_error() {
        let failure = tunnel_failure(anyhow::anyhow!("gcloud exited before listening"));
        assert_eq!(failure.code, "protocol_error");
        assert_eq!(failure.detail, Some("gcloud exited before listening".to_string()));
    }

    /// Both bridge entry points share one mapper. Nothing here can prove the
    /// two `map_err(tunnel_failure)` call sites stay wired — that is read, not
    /// tested — but a second hand-rolled mapping would have to be written
    /// deliberately rather than inherited by copy-paste, which is how the
    /// SSH-forward path acquired its blanket `protocol_error`.
    #[test]
    fn the_relay_error_is_reserved_for_the_relay() {
        let relay = tunnel_failure(anyhow::Error::new(
            crate::iap_tunnel::TunnelError::RelayUnreachable,
        ));
        assert_eq!(relay.code, "relay_unreachable");
        assert_ne!(relay.code, "protocol_error");
    }
}

#[cfg(test)]
mod start_failure_tests {
    use super::*;
    use crate::tunnel::{StartFailure, TunnelEngine};

    /// A failed start says which engine failed, in the shared vocabulary, and
    /// keeps the code and detail `tunnel_failure` already produces.
    #[test]
    fn a_failed_start_carries_the_engine_that_failed() {
        let failure = start_failure(StartFailure {
            engine: Some(TunnelEngine::Gcloud),
            error: anyhow::Error::new(crate::iap_tunnel::TunnelError::LocalPortUnavailable { port: 8443 }),
        });
        assert_eq!(failure.engine.as_deref(), Some("gcloud"));
        assert_eq!(failure.code, "local_port_unavailable");
        assert_eq!(failure.detail, Some("8443".to_string()));

        let native = start_failure(StartFailure {
            engine: Some(TunnelEngine::Native),
            error: anyhow::anyhow!("relay said no"),
        });
        assert_eq!(native.engine.as_deref(), Some("native"));
    }

    /// No engine ran, so none is named.
    #[test]
    fn a_failure_before_any_engine_names_none() {
        let failure = start_failure(StartFailure { engine: None, error: anyhow::anyhow!("invalid project") });
        assert_eq!(failure.engine, None);
        assert_eq!(failure.code, "protocol_error");
    }
}

#[cfg(test)]
mod started_connection_tests {
    use super::*;
    use crate::tunnel::{Started, TunnelEngine};

    /// What crosses to Dart is the entry's port and its engine, spelled as the
    /// log and the environment variables spell it. Dart matches on these exact
    /// strings to pick the tag; anything else shows no tag at all.
    #[test]
    fn the_start_result_carries_the_port_and_the_engine_name() {
        let native = started_connection(Started { local_port: 40001, engine: TunnelEngine::Native });
        assert_eq!((native.local_port, native.engine.as_str()), (40001, "native"));
        let gcloud = started_connection(Started { local_port: 40002, engine: TunnelEngine::Gcloud });
        assert_eq!((gcloud.local_port, gcloud.engine.as_str()), (40002, "gcloud"));
    }
}
