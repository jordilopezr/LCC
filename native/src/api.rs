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

/// Get the email of the currently active GCP account
///
/// Uses `gcloud config get-value account` to retrieve the email address
/// of the authenticated user. Returns the full email (e.g., "user@domain.com").
pub fn get_gcloud_account_email() -> anyhow::Result<String> {
    crate::gcloud::get_gcloud_account()
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
    }).collect())
}

pub fn gcloud_login() -> anyhow::Result<()> {
    crate::gcloud::execute_login()
}

pub fn gcloud_logout() -> anyhow::Result<()> {
    crate::gcloud::execute_logout()
}

// ==========================================
// Multi-Account Management (Sprint 8)
// ==========================================

/// List all authenticated gcloud accounts
pub async fn list_gcloud_accounts() -> anyhow::Result<Vec<crate::gcloud::GcloudAccount>> {
    crate::gcloud::list_gcloud_accounts_async().await
}

/// Switch the active gcloud account
pub async fn switch_gcloud_account(email: String) -> anyhow::Result<()> {
    crate::gcloud::switch_gcloud_account_async(&email).await
}

/// Add a new gcloud account (opens browser)
pub fn add_gcloud_account() -> anyhow::Result<()> {
    crate::gcloud::add_gcloud_account()
}

/// Remove (revoke) a gcloud account
pub async fn remove_gcloud_account(email: String) -> anyhow::Result<()> {
    crate::gcloud::remove_gcloud_account_async(&email).await
}

/// List projects for a specific account (without changing global config)
pub async fn list_projects_for_account(email: String) -> anyhow::Result<Vec<crate::gcloud::GcpProject>> {
    crate::gcloud::get_projects_for_account_async(&email).await
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
}

pub fn start_connection(
    project_id: String,
    zone: String,
    instance_name: String,
    remote_port: u16,
) -> Result<u16, TunnelFailure> {
    crate::tunnel::start_tunnel(&project_id, &zone, &instance_name, remote_port).map_err(|err| {
        match err.downcast_ref::<crate::iap_tunnel::TunnelError>() {
            Some(tunnel_error) => TunnelFailure {
                code: tunnel_error.code().to_string(),
                detail: tunnel_error.detail(),
            },
            None => TunnelFailure {
                code: "protocol_error".to_string(),
                detail: Some(err.to_string()),
            },
        }
    })
}

pub fn stop_connection(instance_name: String, remote_port: u16) -> anyhow::Result<()> {
    crate::tunnel::stop_tunnel(&instance_name, remote_port)
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

/// Get status snapshot of all active tunnels for the global panel.
pub fn get_all_connections_status() -> anyhow::Result<Vec<crate::tunnel::TunnelInfo>> {
    crate::tunnel::get_all_tunnels_status()
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
pub fn init_logging_system() -> anyhow::Result<()> {
    crate::logging::init_logging()
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
pub fn sftp_list_dir(host: String, port: u16, username: String, remote_path: String) -> anyhow::Result<Vec<crate::sftp::RemoteFileEntry>> {
    crate::sftp::sftp_list_directory(host, port, username, remote_path)
}

pub fn sftp_download(host: String, port: u16, username: String, remote_path: String, local_path: String) -> anyhow::Result<u64> {
    crate::sftp::sftp_download_file(host, port, username, remote_path, local_path)
}

pub fn sftp_upload(host: String, port: u16, username: String, local_path: String, remote_path: String) -> anyhow::Result<u64> {
    crate::sftp::sftp_upload_file(host, port, username, local_path, remote_path)
}

pub fn sftp_mkdir(host: String, port: u16, username: String, remote_path: String) -> anyhow::Result<()> {
    crate::sftp::sftp_create_directory(host, port, username, remote_path)
}

pub fn sftp_delete(host: String, port: u16, username: String, remote_path: String, is_directory: bool) -> anyhow::Result<()> {
    crate::sftp::sftp_delete(host, port, username, remote_path, is_directory)
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
