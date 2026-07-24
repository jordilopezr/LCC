//! Windows Credentials Module - Sprint 5
//!
//! This module provides functionality to generate and manage Windows VM
//! credentials using the Google Compute Engine guest agent API.
//!
//! ## How it works
//!
//! 1. Generate an RSA key pair
//! 2. Send the public key to the VM's metadata (windows-keys)
//! 3. The Windows guest agent generates a password and encrypts it
//! 4. Read the encrypted password from serial port 4
//! 5. Decrypt the password using our private key
//! 6. Store the credential securely in the system keyring
//!
//! ## API References
//! - Windows password: https://cloud.google.com/compute/docs/instances/windows/automate-pw-generation

pub mod keygen;
pub mod metadata;
pub mod serial_parser;
pub mod storage;

// Re-export main types
pub use keygen::RsaKeyPair;
pub use metadata::{is_windows_instance, WindowsKeyRequest};
pub use serial_parser::WindowsKeyResponse;
pub use storage::WindowsCredential;

use anyhow::{anyhow, Result};
use tracing::{debug, info};

/// Default timeout for waiting for the guest agent response (60 seconds)
const DEFAULT_TIMEOUT_SECS: u64 = 60;

/// Generate a new Windows password for a VM instance.
///
/// This function:
/// 1. Generates an RSA key pair
/// 2. Sends the public key to the VM's metadata
/// 3. Waits for the guest agent to generate and return the encrypted password
/// 4. Decrypts the password
/// 5. Stores the credential in the system keyring
///
/// # Arguments
/// * `project_id` - GCP project ID
/// * `zone` - Compute Engine zone
/// * `instance_name` - Name of the VM instance
/// * `username` - Windows username to generate password for
/// * `email` - Email address (for GCP tracking)
///
/// # Returns
/// The generated WindowsCredential containing the username and decrypted password.
///
/// # Errors
/// Returns an error if:
/// - RSA key generation fails
/// - Setting metadata fails
/// - Guest agent doesn't respond within timeout
/// - Password decryption fails
/// - Credential storage fails
pub async fn generate_windows_password(
    project_id: &str,
    zone: &str,
    instance_name: &str,
    username: &str,
    email: &str,
) -> Result<WindowsCredential> {
    info!(
        "Generating Windows password for {}@{}/{}/{}",
        username, instance_name, project_id, zone
    );

    // Step 1: Generate RSA key pair
    info!("Step 1: Generating RSA key pair");
    let keypair = RsaKeyPair::generate()
        .map_err(|e| anyhow!("Failed to generate RSA key pair: {}", e))?;

    let modulus = keypair.modulus_base64();
    let exponent = keypair.exponent_base64();

    debug!("Generated RSA key pair (modulus length: {})", modulus.len());

    // Step 2: Create and send the key request to metadata
    info!("Step 2: Setting windows-keys metadata");
    let key_request = WindowsKeyRequest::new(username, &modulus, &exponent, email)?;

    metadata::set_windows_keys_metadata(project_id, zone, instance_name, &key_request)
        .await
        .map_err(|e| anyhow!("Failed to set metadata: {}", e))?;

    // Step 3: Wait for the guest agent to respond
    info!("Step 3: Waiting for guest agent response");
    let response = serial_parser::wait_for_password_response(
        project_id,
        zone,
        instance_name,
        &modulus,
        DEFAULT_TIMEOUT_SECS,
    )
    .await?;

    // Check for errors in the response
    if let Some(ref error_msg) = response.error_message {
        if !error_msg.is_empty() {
            return Err(anyhow!("Guest agent error: {}", error_msg));
        }
    }

    if response.encrypted_password.is_empty() {
        return Err(anyhow!(
            "Guest agent returned empty password. Make sure the Google Guest Agent is running."
        ));
    }

    // Step 4: Decrypt the password
    info!("Step 4: Decrypting password");
    let password = keypair
        .decrypt_password(&response.encrypted_password)
        .map_err(|e| anyhow!("Failed to decrypt password: {}", e))?;

    // Step 5: Create and store the credential
    info!("Step 5: Storing credential in keyring");
    let credential = WindowsCredential::new(
        username.to_string(),
        password,
        project_id.to_string(),
        zone.to_string(),
        instance_name.to_string(),
    );

    storage::store_credential_await(&credential)
        .await
        .map_err(|e| anyhow!("Failed to store credential: {}", e))?;

    info!(
        "Successfully generated and stored Windows password for {}@{}",
        username, instance_name
    );

    Ok(credential)
}

/// Reset an existing Windows password for a VM instance.
///
/// This is functionally the same as `generate_windows_password` but with
/// different logging to indicate it's a reset operation.
pub async fn reset_windows_password(
    project_id: &str,
    zone: &str,
    instance_name: &str,
    username: &str,
    email: &str,
) -> Result<WindowsCredential> {
    info!(
        "Resetting Windows password for {}@{}/{}/{}",
        username, instance_name, project_id, zone
    );

    // Delete existing credential if any (use async version)
    let _ = storage::delete_credential_await(project_id, zone, instance_name).await;

    // Generate new password
    generate_windows_password(project_id, zone, instance_name, username, email).await
}

/// Get a stored credential for an instance.
pub fn get_stored_credential(
    project_id: &str,
    zone: &str,
    instance_name: &str,
) -> Option<WindowsCredential> {
    storage::retrieve_credential(project_id, zone, instance_name)
}

/// Get all stored Windows credentials.
pub fn get_all_stored_credentials() -> Vec<WindowsCredential> {
    storage::list_all_credentials()
}

/// Delete a stored credential.
pub fn delete_stored_credential(
    project_id: &str,
    zone: &str,
    instance_name: &str,
) -> Result<()> {
    storage::delete_credential(project_id, zone, instance_name)
        .map_err(|e| anyhow!("Failed to delete credential: {}", e))
}

/// Clear all stored Windows credentials.
pub fn clear_all_credentials() -> Result<u32> {
    storage::clear_all().map_err(|e| anyhow!("Failed to clear credentials: {}", e))
}

/// Check if an instance is a Windows VM.
pub async fn check_is_windows_instance(
    project_id: &str,
    zone: &str,
    instance_name: &str,
) -> Result<bool> {
    is_windows_instance(project_id, zone, instance_name).await
}

#[cfg(test)]
mod tests {
    use super::*;

    // These tests require a running Windows VM and are integration tests
    // Run with: cargo test --features integration

    #[test]
    fn test_module_compiles() {
        // Basic test to ensure the module compiles
        assert!(true);
    }
}
