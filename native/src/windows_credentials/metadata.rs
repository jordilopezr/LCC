//! Google Compute Engine instance metadata management.
//!
//! This module handles getting and setting instance metadata,
//! specifically for the `windows-keys` metadata item used for
//! Windows password generation.

use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};
use tracing::{debug, info, error};

use crate::gcp_rest_client::GcpAuthClient;
use crate::validation::validate_gcp_url;

const COMPUTE_API_BASE: &str = "https://compute.googleapis.com/compute/v1";

/// Metadata item (key-value pair).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MetadataItem {
    pub key: String,
    pub value: String,
}

/// Instance metadata with fingerprint for optimistic locking.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Metadata {
    pub fingerprint: String,
    #[serde(default)]
    pub items: Vec<MetadataItem>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
}

/// Windows key request to be sent as metadata.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WindowsKeyRequest {
    #[serde(rename = "userName")]
    pub user_name: String,
    pub modulus: String,
    pub exponent: String,
    pub email: String,
    #[serde(rename = "expireOn")]
    pub expire_on: String,
}

impl WindowsKeyRequest {
    /// Create a new Windows key request.
    pub fn new(user_name: &str, modulus: &str, exponent: &str, email: &str) -> Result<Self> {
        // Expire in 5 minutes
        let expire_on = chrono::Utc::now()
            .checked_add_signed(chrono::Duration::minutes(5))
            .ok_or_else(|| anyhow!("Failed to calculate key expiration time"))?
            .format("%Y-%m-%dT%H:%M:%SZ")
            .to_string();

        Ok(Self {
            user_name: user_name.to_string(),
            modulus: modulus.to_string(),
            exponent: exponent.to_string(),
            email: email.to_string(),
            expire_on,
        })
    }

    /// Serialize to JSON string for metadata value.
    pub fn to_json(&self) -> Result<String> {
        serde_json::to_string(self)
            .map_err(|e| anyhow!("Failed to serialize WindowsKeyRequest: {}", e))
    }
}

/// Get the current metadata for an instance.
pub async fn get_instance_metadata(
    project_id: &str,
    zone: &str,
    instance_name: &str,
) -> Result<Metadata> {
    validate_gcp_url(COMPUTE_API_BASE)?;

    let auth = GcpAuthClient::get_or_init()?;
    let token = auth.get_access_token().await?;

    let url = format!(
        "{}/projects/{}/zones/{}/instances/{}",
        COMPUTE_API_BASE, project_id, zone, instance_name
    );

    debug!("Getting instance metadata from: {}", url);

    let client = reqwest::Client::new();
    let response = client
        .get(&url)
        .bearer_auth(&token)
        .send()
        .await
        .map_err(|e| anyhow!("Failed to get instance: {}", e))?;

    if !response.status().is_success() {
        let status = response.status();
        let error_text = response.text().await.unwrap_or_default();
        error!("Failed to get instance metadata: {} - {}", status, error_text);
        return Err(anyhow!("Failed to get instance: {} - {}", status, error_text));
    }

    let instance: serde_json::Value = response.json().await?;

    // Extract metadata
    let metadata = instance.get("metadata")
        .ok_or_else(|| anyhow!("Instance has no metadata"))?;

    let fingerprint = metadata.get("fingerprint")
        .and_then(|f| f.as_str())
        .ok_or_else(|| anyhow!("Metadata has no fingerprint"))?
        .to_string();

    let items = metadata.get("items")
        .and_then(|i| i.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|item| {
                    let key = item.get("key")?.as_str()?.to_string();
                    let value = item.get("value")?.as_str()?.to_string();
                    Some(MetadataItem { key, value })
                })
                .collect()
        })
        .unwrap_or_default();

    Ok(Metadata {
        fingerprint,
        items,
        kind: Some("compute#metadata".to_string()),
    })
}

/// Set the windows-keys metadata item on an instance.
pub async fn set_windows_keys_metadata(
    project_id: &str,
    zone: &str,
    instance_name: &str,
    key_request: &WindowsKeyRequest,
) -> Result<()> {
    validate_gcp_url(COMPUTE_API_BASE)?;

    // First get the current metadata to get the fingerprint
    let current_metadata = get_instance_metadata(project_id, zone, instance_name).await?;

    let auth = GcpAuthClient::get_or_init()?;
    let token = auth.get_access_token().await?;

    // Build the new metadata, preserving existing items
    let key_json = key_request.to_json()?;

    let mut items: Vec<serde_json::Value> = current_metadata
        .items
        .iter()
        .filter(|item| item.key != "windows-keys") // Remove existing windows-keys
        .map(|item| {
            serde_json::json!({
                "key": item.key,
                "value": item.value
            })
        })
        .collect();

    // Add the new windows-keys item
    items.push(serde_json::json!({
        "key": "windows-keys",
        "value": key_json
    }));

    let metadata_body = serde_json::json!({
        "fingerprint": current_metadata.fingerprint,
        "items": items
    });

    let url = format!(
        "{}/projects/{}/zones/{}/instances/{}/setMetadata",
        COMPUTE_API_BASE, project_id, zone, instance_name
    );

    info!(
        "Setting windows-keys metadata for {} (user: {})",
        instance_name, key_request.user_name
    );
    debug!("Metadata URL: {}", url);

    let client = reqwest::Client::new();
    let response = client
        .post(&url)
        .bearer_auth(&token)
        .json(&metadata_body)
        .send()
        .await
        .map_err(|e| anyhow!("Failed to set metadata: {}", e))?;

    if !response.status().is_success() {
        let status = response.status();
        let error_text = response.text().await.unwrap_or_default();
        error!("Failed to set metadata: {} - {}", status, error_text);
        return Err(anyhow!("Failed to set metadata: {} - {}", status, error_text));
    }

    // The response is an operation - we could wait for it, but it's usually very fast
    let operation: serde_json::Value = response.json().await?;
    let op_name = operation.get("name")
        .and_then(|n| n.as_str())
        .unwrap_or("unknown");

    info!("Metadata operation started: {}", op_name);

    // Wait a moment for the metadata to propagate
    tokio::time::sleep(tokio::time::Duration::from_secs(1)).await;

    Ok(())
}

/// Check if an instance is a Windows VM.
pub async fn is_windows_instance(
    project_id: &str,
    zone: &str,
    instance_name: &str,
) -> Result<bool> {
    let auth = GcpAuthClient::get_or_init()?;
    let token = auth.get_access_token().await?;

    let url = format!(
        "{}/projects/{}/zones/{}/instances/{}",
        COMPUTE_API_BASE, project_id, zone, instance_name
    );

    let client = reqwest::Client::new();
    let response = client
        .get(&url)
        .bearer_auth(&token)
        .send()
        .await
        .map_err(|e| anyhow!("Failed to get instance: {}", e))?;

    if !response.status().is_success() {
        return Err(anyhow!("Failed to get instance"));
    }

    let instance: serde_json::Value = response.json().await?;

    // Check disk sources for "windows" in image name
    if let Some(disks) = instance.get("disks").and_then(|d| d.as_array()) {
        for disk in disks {
            // Check source image
            if let Some(source) = disk.get("source").and_then(|s| s.as_str()) {
                if source.to_lowercase().contains("windows") {
                    return Ok(true);
                }
            }
            // Check licenses
            if let Some(licenses) = disk.get("licenses").and_then(|l| l.as_array()) {
                for license in licenses {
                    if let Some(lic_str) = license.as_str() {
                        if lic_str.to_lowercase().contains("windows") {
                            return Ok(true);
                        }
                    }
                }
            }
        }
    }

    // Check labels
    if let Some(labels) = instance.get("labels").and_then(|l| l.as_object()) {
        if let Some(os) = labels.get("os").and_then(|o| o.as_str()) {
            if os.to_lowercase().contains("windows") {
                return Ok(true);
            }
        }
    }

    // Check metadata for windows-specific keys
    if let Some(metadata) = instance.get("metadata") {
        if let Some(items) = metadata.get("items").and_then(|i| i.as_array()) {
            for item in items {
                if let Some(key) = item.get("key").and_then(|k| k.as_str()) {
                    if key == "windows-startup-script-ps1" || key == "windows-startup-script-cmd" {
                        return Ok(true);
                    }
                }
            }
        }
    }

    Ok(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_windows_key_request_serialization() {
        let request = WindowsKeyRequest::new(
            "admin",
            "base64modulus",
            "AQAB",
            "user@example.com",
        ).unwrap();

        let json = request.to_json().unwrap();
        assert!(json.contains("userName"));
        assert!(json.contains("admin"));
        assert!(json.contains("modulus"));
        assert!(json.contains("expireOn"));
    }

    #[test]
    fn test_windows_key_request_expiration() {
        let request = WindowsKeyRequest::new(
            "admin",
            "modulus",
            "exponent",
            "user@example.com",
        ).unwrap();

        // Expiration should be in the future
        let expire_time = chrono::DateTime::parse_from_rfc3339(
            &format!("{}+00:00", request.expire_on.replace("Z", ""))
        );
        assert!(expire_time.is_ok());

        let expire_time = expire_time.unwrap();
        let now = chrono::Utc::now();
        assert!(expire_time > now);
    }
}
