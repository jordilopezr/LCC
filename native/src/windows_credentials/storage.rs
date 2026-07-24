//! Secure credential storage using the system keyring.
//!
//! Cross-platform: uses GNOME Keyring / KWallet on Linux,
//! macOS Keychain on macOS, and Windows Credential Manager on Windows.

use chrono::Utc;
use keyring::Entry;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use tracing::{debug, error, info, warn};

const SERVICE_NAME: &str = "linux-cloud-connector";

/// Windows credential stored in the system keyring.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WindowsCredential {
    pub username: String,
    pub password: String,
    pub instance_name: String,
    pub project_id: String,
    pub zone: String,
    /// ISO 8601 timestamp string (for FFI compatibility)
    pub created_at: String,
    /// ISO 8601 timestamp string (optional, for FFI compatibility)
    pub expires_at: Option<String>,
}

impl WindowsCredential {
    /// Create a new Windows credential.
    pub fn new(
        username: String,
        password: String,
        project_id: String,
        zone: String,
        instance_name: String,
    ) -> Self {
        Self {
            username,
            password,
            instance_name,
            project_id,
            zone,
            created_at: Utc::now().to_rfc3339(),
            expires_at: None,
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Keyring "username" is the composite key identifying a specific VM credential.
fn keyring_username(project_id: &str, zone: &str, instance_name: &str) -> String {
    format!("{}::{}::{}", project_id, zone, instance_name)
}

/// Path to the index file that tracks all stored keyring keys.
/// Required because the keyring API does not support enumeration.
fn index_file_path() -> Option<PathBuf> {
    let mut path = crate::app_dirs::migrated_app_dir(dirs::data_local_dir()?);
    path.push("credentials_index.json");
    Some(path)
}

fn load_index() -> Vec<String> {
    let path = match index_file_path() {
        Some(p) => p,
        None => return Vec::new(),
    };
    if !path.exists() {
        return Vec::new();
    }
    std::fs::read_to_string(&path)
        .ok()
        .and_then(|s| serde_json::from_str::<Vec<String>>(&s).ok())
        .unwrap_or_default()
}

fn save_index(keys: &[String]) -> Result<(), String> {
    let path = index_file_path().ok_or("Cannot determine data directory")?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("Failed to create data directory: {}", e))?;
    }
    let json = serde_json::to_string(keys)
        .map_err(|e| format!("Failed to serialize index: {}", e))?;
    std::fs::write(&path, json)
        .map_err(|e| format!("Failed to write index file: {}", e))?;
    Ok(())
}

fn add_to_index(key: &str) -> Result<(), String> {
    let mut keys = load_index();
    if !keys.iter().any(|k| k == key) {
        keys.push(key.to_string());
        save_index(&keys)?;
    }
    Ok(())
}

fn remove_from_index(key: &str) {
    let mut keys = load_index();
    keys.retain(|k| k != key);
    let _ = save_index(&keys);
}

// ─────────────────────────────────────────────────────────────────────────────
// Public API
// ─────────────────────────────────────────────────────────────────────────────

/// Store a credential in the system keyring (sync).
pub fn store_credential(credential: &WindowsCredential) -> Result<(), String> {
    let key = keyring_username(&credential.project_id, &credential.zone, &credential.instance_name);
    let entry = Entry::new(SERVICE_NAME, &key)
        .map_err(|e| format!("Failed to create keyring entry: {}", e))?;
    let json = serde_json::to_string(credential)
        .map_err(|e| format!("Failed to serialize credential: {}", e))?;
    entry.set_password(&json)
        .map_err(|e| format!("Failed to store credential in keyring: {}", e))?;
    add_to_index(&key)?;
    info!(
        "Stored Windows credential for {}@{}/{}/{}",
        credential.username, credential.instance_name, credential.project_id, credential.zone
    );
    Ok(())
}

/// Store a credential in the system keyring (async-compatible wrapper).
pub async fn store_credential_await(credential: &WindowsCredential) -> Result<(), String> {
    store_credential(credential)
}

/// Retrieve a credential from the system keyring.
pub fn retrieve_credential(
    project_id: &str,
    zone: &str,
    instance_name: &str,
) -> Option<WindowsCredential> {
    let key = keyring_username(project_id, zone, instance_name);
    let entry = Entry::new(SERVICE_NAME, &key).ok()?;
    let json = entry.get_password().ok()?;
    let cred: WindowsCredential = serde_json::from_str(&json).ok()?;
    debug!("Retrieved Windows credential for {}@{}", cred.username, instance_name);
    Some(cred)
}

/// List all stored credentials.
pub fn list_all_credentials() -> Vec<WindowsCredential> {
    let keys = load_index();
    let mut credentials = Vec::new();

    for key in &keys {
        let entry = match Entry::new(SERVICE_NAME, key) {
            Ok(e) => e,
            Err(e) => {
                warn!("Failed to open keyring entry for {}: {}", key, e);
                continue;
            }
        };
        match entry.get_password() {
            Ok(json) => match serde_json::from_str::<WindowsCredential>(&json) {
                Ok(cred) => credentials.push(cred),
                Err(e) => warn!("Failed to deserialize credential for {}: {}", key, e),
            },
            Err(keyring::Error::NoEntry) => {
                // Present in index but no longer in keyring — clean up
                remove_from_index(key);
            }
            Err(e) => warn!("Failed to retrieve credential for {}: {}", key, e),
        }
    }

    info!("Found {} stored Windows credentials", credentials.len());
    credentials
}

/// Delete a specific credential (sync).
pub fn delete_credential(project_id: &str, zone: &str, instance_name: &str) -> Result<(), String> {
    let key = keyring_username(project_id, zone, instance_name);
    let entry = Entry::new(SERVICE_NAME, &key)
        .map_err(|e| format!("Failed to create keyring entry: {}", e))?;
    match entry.delete_credential() {
        Ok(()) => {}
        Err(keyring::Error::NoEntry) => {
            debug!("No credential to delete for {}/{}/{}", project_id, zone, instance_name);
        }
        Err(e) => return Err(format!("Failed to delete credential: {}", e)),
    }
    remove_from_index(&key);
    info!(
        "Deleted Windows credential for {}/{}/{}",
        project_id, zone, instance_name
    );
    Ok(())
}

/// Delete a specific credential (async-compatible wrapper).
pub async fn delete_credential_await(
    project_id: &str,
    zone: &str,
    instance_name: &str,
) -> Result<(), String> {
    delete_credential(project_id, zone, instance_name)
}

/// Clear all stored credentials.
pub fn clear_all() -> Result<u32, String> {
    let keys = load_index();
    let count = keys.len() as u32;

    for key in &keys {
        if let Ok(entry) = Entry::new(SERVICE_NAME, key) {
            if let Err(e) = entry.delete_credential() {
                error!("Failed to delete credential for {}: {}", key, e);
            }
        }
    }

    save_index(&[])?;
    info!("Cleared {} Windows credentials", count);
    Ok(count)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_keyring_username_format() {
        let key = keyring_username("my-project", "us-central1-a", "my-vm");
        assert_eq!(key, "my-project::us-central1-a::my-vm");
    }

    #[test]
    fn test_windows_credential_new() {
        let cred = WindowsCredential::new(
            "Administrator".to_string(),
            "P@ssw0rd!".to_string(),
            "proj-123".to_string(),
            "us-east1-b".to_string(),
            "win-vm-01".to_string(),
        );
        assert_eq!(cred.username, "Administrator");
        assert_eq!(cred.instance_name, "win-vm-01");
        assert!(cred.expires_at.is_none());
    }

    #[test]
    #[ignore] // Requires system keyring
    fn test_store_retrieve_delete() {
        let cred = WindowsCredential::new(
            "testuser".to_string(),
            "TestPassword123!".to_string(),
            "test-project".to_string(),
            "us-central1-a".to_string(),
            "test-vm".to_string(),
        );

        store_credential(&cred).expect("store failed");

        let retrieved = retrieve_credential("test-project", "us-central1-a", "test-vm");
        assert!(retrieved.is_some());
        let retrieved = retrieved.unwrap();
        assert_eq!(retrieved.username, "testuser");
        assert_eq!(retrieved.password, "TestPassword123!");

        delete_credential("test-project", "us-central1-a", "test-vm").expect("delete failed");
        assert!(retrieve_credential("test-project", "us-central1-a", "test-vm").is_none());
    }
}
