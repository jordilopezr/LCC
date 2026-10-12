pub mod api;
pub mod app_dirs;
// pub mod license; removed
pub mod gcloud;
pub mod gcloud_bin;
pub mod gcp_rest_client;
pub mod tunnel;
pub mod iap_tunnel;  // 27H1: native IAP TCP forwarding
pub mod rdp_client;
pub mod vnc_client;
pub mod db_client;  // Sprint 4: Database Client Integration
pub mod windows_credentials;  // Sprint 5: Windows Auto-Credentials
pub mod sshfs_mount;  // Sprint 6: SSHFS Mount Support
pub mod validation;
pub mod logging;
pub mod redact;  // Sensitive data redaction utilities
pub mod sftp;
mod ssh_session;
mod ssh_forward;  // 27H1: native ssh2 SSH port-forward engine (opt-in)
mod child_reaper;  // launch external clients without leaving zombies
pub mod diagnostics;  // Sprint 3: VM Diagnostics, Serial Console, Audit Logs
pub mod doctor;  // Sprint 7: Connectivity Doctor
pub mod snapshots;  // Sprint 16: VM Snapshot Manager
pub mod oauth;  // 27H1 SG-D: own OAuth (authorization code + PKCE + loopback)
pub mod token_store;  // 27H1 SG-D/D2: refresh tokens in the OS keyring
pub mod accounts;  // 27H1 SG-D/D4: account management over the native token store
pub mod ssh_keys;  // 27H1 SP-1: ssh-keys metadata formatting and merging
pub mod ssh_access;  // 27H1 SP-1: SSH key provisioning and username selection
pub mod engine_pref;  // 27H1 D5: which auth engine to use, and where that is stored
mod frb_generated;