pub mod api;
pub mod app_dirs;
// pub mod license; removed
pub mod gcloud;
pub mod gcp_rest_client;
pub mod tunnel;
pub mod rdp_client;
pub mod vnc_client;
pub mod db_client;  // Sprint 4: Database Client Integration
pub mod windows_credentials;  // Sprint 5: Windows Auto-Credentials
pub mod sshfs_mount;  // Sprint 6: SSHFS Mount Support
pub mod validation;
pub mod logging;
pub mod redact;  // Sensitive data redaction utilities
pub mod sftp;
pub mod diagnostics;  // Sprint 3: VM Diagnostics, Serial Console, Audit Logs
pub mod doctor;  // Sprint 7: Connectivity Doctor
pub mod snapshots;  // Sprint 16: VM Snapshot Manager
mod frb_generated;