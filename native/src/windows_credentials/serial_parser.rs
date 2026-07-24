//! Serial port output parser for Windows guest agent responses.
//!
//! The Windows guest agent responds to password requests via serial port 4.
//! This module polls the serial port and parses the response.

use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};
use tracing::{debug, error, info, warn};

use crate::gcp_rest_client::GcpAuthClient;

const COMPUTE_API_BASE: &str = "https://compute.googleapis.com/compute/v1";
const SERIAL_PORT_4: u8 = 4;

/// Response from the Windows guest agent containing the encrypted password.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WindowsKeyResponse {
    /// The modulus of the public key used (for matching the response)
    pub modulus: String,
    /// The encrypted password (base64 encoded)
    #[serde(rename = "encryptedPassword")]
    pub encrypted_password: String,
    /// The username the password was generated for
    #[serde(rename = "userName")]
    pub user_name: String,
    /// Whether a password was found
    #[serde(rename = "passwordFound", default)]
    pub password_found: bool,
    /// Error message if password generation failed
    #[serde(rename = "errorMessage")]
    pub error_message: Option<String>,
    /// Expiration time of the response
    #[serde(rename = "expiresOn")]
    pub expires_on: Option<String>,
}

/// Get serial port 4 output from an instance.
async fn get_serial_port_output(
    project_id: &str,
    zone: &str,
    instance_name: &str,
    start: Option<i64>,
) -> Result<(String, i64)> {
    let auth = GcpAuthClient::get_or_init()?;
    let token = auth.get_access_token().await?;

    let mut url = format!(
        "{}/projects/{}/zones/{}/instances/{}/serialPort?port={}",
        COMPUTE_API_BASE, project_id, zone, instance_name, SERIAL_PORT_4
    );

    if let Some(start_pos) = start {
        url.push_str(&format!("&start={}", start_pos));
    }

    let client = reqwest::Client::new();
    let response = client
        .get(&url)
        .bearer_auth(&token)
        .send()
        .await
        .map_err(|e| anyhow!("Failed to get serial port output: {}", e))?;

    if !response.status().is_success() {
        let status = response.status();
        let error_text = response.text().await.unwrap_or_default();
        return Err(anyhow!(
            "Failed to get serial port output: {} - {}",
            status,
            error_text
        ));
    }

    let body: serde_json::Value = response.json().await?;

    let contents = body
        .get("contents")
        .and_then(|c| c.as_str())
        .unwrap_or("")
        .to_string();

    let next = body
        .get("next")
        .and_then(|n| n.as_i64())
        .unwrap_or(0);

    Ok((contents, next))
}

/// Parse serial output to find the Windows key response.
///
/// The guest agent writes JSON responses to serial port 4.
/// Each line is a separate JSON object.
pub fn parse_serial_output(output: &str, target_modulus: &str) -> Option<WindowsKeyResponse> {
    // Split by newlines and try to parse each line as JSON
    for line in output.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }

        // Try to parse as WindowsKeyResponse
        if let Ok(response) = serde_json::from_str::<WindowsKeyResponse>(line) {
            // Check if this response matches our modulus
            if response.modulus == target_modulus {
                debug!("Found matching Windows key response");
                return Some(response);
            }
        }
    }

    None
}

/// Wait for the Windows guest agent to respond with the generated password.
///
/// This function polls serial port 4 until either:
/// - The guest agent responds with a matching password
/// - The timeout is reached
/// - An error occurs
///
/// # Arguments
/// * `project_id` - GCP project ID
/// * `zone` - Compute Engine zone
/// * `instance_name` - Name of the VM instance
/// * `target_modulus` - The modulus from our public key (to match the response)
/// * `timeout_secs` - Maximum time to wait for a response
///
/// # Returns
/// The WindowsKeyResponse from the guest agent, or an error.
pub async fn wait_for_password_response(
    project_id: &str,
    zone: &str,
    instance_name: &str,
    target_modulus: &str,
    timeout_secs: u64,
) -> Result<WindowsKeyResponse> {
    info!(
        "Waiting for Windows guest agent response (timeout: {}s)",
        timeout_secs
    );

    let start_time = std::time::Instant::now();
    let timeout = std::time::Duration::from_secs(timeout_secs);
    let poll_interval = std::time::Duration::from_secs(2);

    // Start position for serial port output
    let mut start_pos: Option<i64> = None;

    while start_time.elapsed() < timeout {
        debug!(
            "Polling serial port 4 (elapsed: {}s)",
            start_time.elapsed().as_secs()
        );

        match get_serial_port_output(project_id, zone, instance_name, start_pos).await {
            Ok((contents, next)) => {
                // Update start position for next poll
                start_pos = Some(next);

                if !contents.is_empty() {
                    // Try to parse the response
                    if let Some(response) = parse_serial_output(&contents, target_modulus) {
                        // Check for errors
                        if let Some(ref error_msg) = response.error_message {
                            if !error_msg.is_empty() {
                                error!("Guest agent error: {}", error_msg);
                                return Err(anyhow!("Guest agent error: {}", error_msg));
                            }
                        }

                        // Check if password was found
                        if response.password_found || !response.encrypted_password.is_empty() {
                            info!("Received password response from guest agent");
                            return Ok(response);
                        }
                    }
                }
            }
            Err(e) => {
                warn!("Error polling serial port: {}", e);
                // Continue polling, might be transient
            }
        }

        // Wait before next poll
        tokio::time::sleep(poll_interval).await;
    }

    error!(
        "Timeout waiting for guest agent response after {}s",
        timeout_secs
    );
    Err(anyhow!(
        "Timeout waiting for Windows guest agent response. \
        Make sure the VM is running and the Google Guest Agent is installed."
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_valid_response() {
        let response_json = r#"{"modulus":"ABC123","encryptedPassword":"xyz789","userName":"admin","passwordFound":true}"#;
        let output = format!("Some log line\n{}\nAnother line", response_json);

        let result = parse_serial_output(&output, "ABC123");
        assert!(result.is_some());

        let response = result.unwrap();
        assert_eq!(response.modulus, "ABC123");
        assert_eq!(response.encrypted_password, "xyz789");
        assert_eq!(response.user_name, "admin");
        assert!(response.password_found);
    }

    #[test]
    fn test_parse_wrong_modulus() {
        let response_json = r#"{"modulus":"ABC123","encryptedPassword":"xyz789","userName":"admin","passwordFound":true}"#;
        let output = format!("{}", response_json);

        // Looking for different modulus
        let result = parse_serial_output(&output, "DIFFERENT");
        assert!(result.is_none());
    }

    #[test]
    fn test_parse_empty_output() {
        let result = parse_serial_output("", "ABC123");
        assert!(result.is_none());
    }

    #[test]
    fn test_parse_invalid_json() {
        let output = "Not a JSON line\nAnother invalid line\n";
        let result = parse_serial_output(&output, "ABC123");
        assert!(result.is_none());
    }

    #[test]
    fn test_parse_error_response() {
        let response_json = r#"{"modulus":"ABC123","encryptedPassword":"","userName":"admin","passwordFound":false,"errorMessage":"User not found"}"#;
        let output = response_json.to_string();

        let result = parse_serial_output(&output, "ABC123");
        assert!(result.is_some());

        let response = result.unwrap();
        assert!(!response.password_found);
        assert_eq!(response.error_message, Some("User not found".to_string()));
    }

    #[test]
    fn test_parse_multiple_responses() {
        // Multiple responses, we should find the one matching our modulus
        let output = r#"{"modulus":"OTHER","encryptedPassword":"aaa","userName":"other","passwordFound":true}
{"modulus":"TARGET","encryptedPassword":"bbb","userName":"admin","passwordFound":true}
{"modulus":"ANOTHER","encryptedPassword":"ccc","userName":"another","passwordFound":true}"#;

        let result = parse_serial_output(&output, "TARGET");
        assert!(result.is_some());

        let response = result.unwrap();
        assert_eq!(response.modulus, "TARGET");
        assert_eq!(response.encrypted_password, "bbb");
    }
}
