/// VM Diagnostics Module - Sprint 3
///
/// This module provides diagnostic tools for troubleshooting VMs:
/// - Serial Port Output (boot logs, kernel messages)
/// - VM Diagnostics (status, guest agent, network, disk)
/// - Cloud Audit Logs (recent events)
///
/// API References:
/// - Serial Port: https://cloud.google.com/compute/docs/instances/interacting-with-serial-console
/// - Audit Logs: https://cloud.google.com/logging/docs/reference/v2/rest

use anyhow::{Result, anyhow};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tracing::{info, debug, error, warn};

use crate::gcp_rest_client::GcpAuthClient;
use crate::redact::redact_sensitive;

// ==========================================
// SERIAL PORT OUTPUT
// ==========================================

/// Serial port output from a VM instance
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SerialPortOutput {
    /// The actual serial port content
    pub contents: String,
    /// Position in the serial port output (for incremental fetching)
    pub next: i64,
    /// Start position of the returned content
    pub start: i64,
    /// Instance name
    pub instance_name: String,
    /// Project ID
    pub project_id: String,
    /// Zone
    pub zone: String,
    /// Timestamp when fetched
    pub fetched_at: String,
}

/// Serial port number (1-4)
#[derive(Debug, Clone, Copy, Serialize, Deserialize, Default)]
pub enum SerialPortNumber {
    /// Port 1: Default console (boot logs, kernel messages)
    #[default]
    Port1 = 1,
    /// Port 2: Serial console interactive
    Port2 = 2,
    /// Port 3: Usually unused
    Port3 = 3,
    /// Port 4: Usually unused
    Port4 = 4,
}

impl SerialPortNumber {
    pub fn as_u8(&self) -> u8 {
        *self as u8
    }
}

// ==========================================
// VM DIAGNOSTICS
// ==========================================

/// VM diagnostic information
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VmDiagnostics {
    /// Instance name
    pub instance_name: String,
    /// Project ID
    pub project_id: String,
    /// Zone
    pub zone: String,
    /// Current status (RUNNING, STOPPED, etc.)
    pub status: String,
    /// Last start timestamp
    pub last_start_timestamp: Option<String>,
    /// Last stop timestamp
    pub last_stop_timestamp: Option<String>,
    /// Guest agent status
    pub guest_agent_status: GuestAgentStatus,
    /// Network interfaces
    pub network_interfaces: Vec<NetworkInterface>,
    /// Disk status
    pub disks: Vec<DiskStatus>,
    /// Machine type
    pub machine_type: String,
    /// Labels
    pub labels: Vec<(String, String)>,
    /// Creation timestamp
    pub creation_timestamp: Option<String>,
}

/// Guest OS features and agent status
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct GuestAgentStatus {
    /// Whether guest agent is reporting
    pub is_reporting: bool,
    /// Guest OS type (if available)
    pub os_type: Option<String>,
    /// Guest OS version (if available)
    pub os_version: Option<String>,
    /// Last heartbeat time
    pub last_heartbeat: Option<String>,
}

/// Network interface information
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NetworkInterface {
    /// Network name
    pub network: String,
    /// Subnetwork name
    pub subnetwork: Option<String>,
    /// Internal IP address
    pub internal_ip: Option<String>,
    /// External IP address (if assigned)
    pub external_ip: Option<String>,
    /// Network tier (PREMIUM, STANDARD)
    pub network_tier: Option<String>,
}

/// Disk status information
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiskStatus {
    /// Disk name/source
    pub name: String,
    /// Disk type (pd-standard, pd-ssd, etc.)
    pub disk_type: Option<String>,
    /// Disk size in GB
    pub size_gb: Option<u32>,
    /// Whether this is the boot disk
    pub is_boot: bool,
    /// Auto-delete flag
    pub auto_delete: bool,
    /// Mode (READ_WRITE, READ_ONLY)
    pub mode: String,
}

// ==========================================
// CLOUD AUDIT LOGS
// ==========================================

/// Audit log entry
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuditLogEntry {
    /// Log entry ID
    pub insert_id: String,
    /// Timestamp
    pub timestamp: String,
    /// Severity (INFO, WARNING, ERROR)
    pub severity: String,
    /// Log name
    pub log_name: String,
    /// Resource type (gce_instance, etc.)
    pub resource_type: String,
    /// Method name (compute.instances.start, etc.)
    pub method_name: Option<String>,
    /// Principal email (actor)
    pub principal_email: Option<String>,
    /// Status code
    pub status_code: Option<i32>,
    /// Status message
    pub status_message: Option<String>,
    /// Resource name
    pub resource_name: Option<String>,
    /// Request payload (JSON string, sanitized)
    pub request_summary: Option<String>,
}

/// Filter for audit log queries
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct AuditLogFilter {
    /// Instance name to filter by
    pub instance_name: Option<String>,
    /// Max number of entries to return
    pub max_entries: Option<u32>,
    /// Time range in hours (default: 24)
    pub hours_ago: Option<u32>,
    /// Filter by method names
    pub method_filter: Option<Vec<String>>,
    /// Filter by severity
    pub severity_filter: Option<Vec<String>>,
}

// ==========================================
// DIAGNOSTICS CLIENT
// ==========================================

/// Client for VM diagnostics
pub struct DiagnosticsClient {
    auth: Arc<GcpAuthClient>,
    compute_base_url: String,
    logging_base_url: String,
}

impl DiagnosticsClient {
    pub async fn new() -> Result<Self> {
        let auth = GcpAuthClient::get_or_init()?;

        Ok(Self {
            auth,
            compute_base_url: "https://compute.googleapis.com/compute/v1".to_string(),
            logging_base_url: "https://logging.googleapis.com/v2".to_string(),
        })
    }

    /// Get serial port output from a VM
    ///
    /// API: GET /projects/{project}/zones/{zone}/instances/{instance}/serialPort
    ///
    /// # Arguments
    /// * `project` - Project ID
    /// * `zone` - Zone name
    /// * `instance` - Instance name
    /// * `port` - Serial port number (1-4, default 1)
    /// * `start` - Optional start position (for incremental fetch)
    pub async fn get_serial_port_output(
        &self,
        project: &str,
        zone: &str,
        instance: &str,
        port: SerialPortNumber,
        start: Option<i64>,
    ) -> Result<SerialPortOutput> {
        info!("📟 Getting serial port {} output for {}/{}/{}", port.as_u8(), project, zone, instance);

        let token = self.auth.get_access_token().await?;
        let client = reqwest::Client::new();

        // Build URL with query parameters
        let mut url = format!(
            "{}/projects/{}/zones/{}/instances/{}/serialPort?port={}",
            self.compute_base_url, project, zone, instance, port.as_u8()
        );

        if let Some(start_pos) = start {
            url.push_str(&format!("&start={}", start_pos));
        }

        debug!("Making request to: {}", url);

        let response = client
            .get(&url)
            .bearer_auth(&token)
            .header("Content-Type", "application/json")
            .send()
            .await
            .map_err(|e| anyhow!("Failed to send request: {}", e))?;

        if !response.status().is_success() {
            let status = response.status();
            let error_text = response.text().await.unwrap_or_default();
            error!("API request failed: {} - {}", status, redact_sensitive(&error_text));

            // Check for specific errors
            if status.as_u16() == 400 && error_text.contains("serial port logging is not enabled") {
                return Err(anyhow!(
                    "SERIAL_PORT_DISABLED: Serial port logging is not enabled for instance '{}'. \
                    Enable it by setting 'serial-port-logging-enable' metadata to 'TRUE' on the instance.",
                    instance
                ));
            }

            if status.as_u16() == 403 {
                return Err(anyhow!(
                    "PERMISSION_DENIED: You don't have permission to read serial port output for instance '{}'. \
                    Required permission: 'compute.instances.getSerialPortOutput'.",
                    instance
                ));
            }

            return Err(anyhow!("API error {}: {}", status, redact_sensitive(&error_text)));
        }

        let response_json: serde_json::Value = response.json().await?;

        let contents = response_json["contents"]
            .as_str()
            .unwrap_or("")
            .to_string();

        let next = response_json["next"]
            .as_str()
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);

        let start_pos = response_json["start"]
            .as_str()
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);

        info!("✓ Got {} bytes of serial output", contents.len());

        Ok(SerialPortOutput {
            contents,
            next,
            start: start_pos,
            instance_name: instance.to_string(),
            project_id: project.to_string(),
            zone: zone.to_string(),
            fetched_at: chrono::Utc::now().to_rfc3339(),
        })
    }

    /// Get detailed VM diagnostics
    ///
    /// API: GET /projects/{project}/zones/{zone}/instances/{instance}
    pub async fn get_vm_diagnostics(
        &self,
        project: &str,
        zone: &str,
        instance: &str,
    ) -> Result<VmDiagnostics> {
        info!("🔍 Getting diagnostics for {}/{}/{}", project, zone, instance);

        let token = self.auth.get_access_token().await?;
        let client = reqwest::Client::new();

        let url = format!(
            "{}/projects/{}/zones/{}/instances/{}",
            self.compute_base_url, project, zone, instance
        );

        let response = client
            .get(&url)
            .bearer_auth(&token)
            .header("Content-Type", "application/json")
            .send()
            .await
            .map_err(|e| anyhow!("Failed to send request: {}", e))?;

        if !response.status().is_success() {
            let status = response.status();
            let error_text = response.text().await.unwrap_or_default();
            error!("API request failed: {} - {}", status, redact_sensitive(&error_text));
            return Err(anyhow!("API error {}: {}", status, redact_sensitive(&error_text)));
        }

        let inst: serde_json::Value = response.json().await?;

        // Parse network interfaces
        let network_interfaces = inst["networkInterfaces"]
            .as_array()
            .map(|arr| {
                arr.iter().map(|ni| {
                    let external_ip = ni["accessConfigs"]
                        .as_array()
                        .and_then(|configs| {
                            configs.iter()
                                .find_map(|c| c["natIP"].as_str().map(String::from))
                        });

                    NetworkInterface {
                        network: ni["network"].as_str()
                            .and_then(|n| n.split('/').last())
                            .unwrap_or("unknown")
                            .to_string(),
                        subnetwork: ni["subnetwork"].as_str()
                            .and_then(|s| s.split('/').last())
                            .map(String::from),
                        internal_ip: ni["networkIP"].as_str().map(String::from),
                        external_ip,
                        network_tier: ni["accessConfigs"]
                            .as_array()
                            .and_then(|c| c.first())
                            .and_then(|c| c["networkTier"].as_str())
                            .map(String::from),
                    }
                }).collect()
            })
            .unwrap_or_default();

        // Parse disks
        let disks = inst["disks"]
            .as_array()
            .map(|arr| {
                arr.iter().map(|d| {
                    DiskStatus {
                        name: d["source"].as_str()
                            .and_then(|s| s.split('/').last())
                            .unwrap_or("unknown")
                            .to_string(),
                        disk_type: d["type"].as_str().map(String::from),
                        size_gb: d["diskSizeGb"].as_str()
                            .and_then(|s| s.parse().ok()),
                        is_boot: d["boot"].as_bool().unwrap_or(false),
                        auto_delete: d["autoDelete"].as_bool().unwrap_or(false),
                        mode: d["mode"].as_str().unwrap_or("READ_WRITE").to_string(),
                    }
                }).collect()
            })
            .unwrap_or_default();

        // Parse labels
        let labels = inst["labels"]
            .as_object()
            .map(|obj| {
                obj.iter()
                    .map(|(k, v)| (k.clone(), v.as_str().unwrap_or("").to_string()))
                    .collect()
            })
            .unwrap_or_default();

        // Parse guest attributes for agent status
        let guest_agent_status = self.get_guest_agent_status(project, zone, instance).await
            .unwrap_or_default();

        info!("✓ Got diagnostics for instance {}", instance);

        Ok(VmDiagnostics {
            instance_name: instance.to_string(),
            project_id: project.to_string(),
            zone: zone.to_string(),
            status: inst["status"].as_str().unwrap_or("UNKNOWN").to_string(),
            last_start_timestamp: inst["lastStartTimestamp"].as_str().map(String::from),
            last_stop_timestamp: inst["lastStopTimestamp"].as_str().map(String::from),
            guest_agent_status,
            network_interfaces,
            disks,
            machine_type: inst["machineType"].as_str()
                .and_then(|m| m.split('/').last())
                .unwrap_or("unknown")
                .to_string(),
            labels,
            creation_timestamp: inst["creationTimestamp"].as_str().map(String::from),
        })
    }

    /// Fallback to check guest agent via serial console
    async fn check_guest_agent_via_serial(
        &self,
        project: &str,
        zone: &str,
        instance: &str,
    ) -> Result<GuestAgentStatus> {
        debug!("Checking serial console for guest agent status on {}", instance);
        
        match self.get_serial_port_output(project, zone, instance, SerialPortNumber::Port1, None).await {
            Ok(serial) => {
                let lower_contents = serial.contents.to_lowercase();
                if lower_contents.contains("gceagent:") 
                    || lower_contents.contains("gceguestagent")
                    || lower_contents.contains("google-guest-agent")
                    || lower_contents.contains("google compute engine guest agent") 
                {
                    info!("Guest agent detected via serial console for {}", instance);
                    Ok(GuestAgentStatus {
                        is_reporting: true,
                        os_type: Some("Detected via Serial".to_string()),
                        ..Default::default()
                    })
                } else {
                    Ok(GuestAgentStatus::default())
                }
            }
            Err(e) => {
                warn!("Failed to check serial console for guest agent: {}", e);
                Ok(GuestAgentStatus::default())
            }
        }
    }

    /// Get guest agent status from guest attributes
    async fn get_guest_agent_status(
        &self,
        project: &str,
        zone: &str,
        instance: &str,
    ) -> Result<GuestAgentStatus> {
        let token = self.auth.get_access_token().await?;
        let client = reqwest::Client::new();

        // Try to get guest attributes
        let url = format!(
            "{}/projects/{}/zones/{}/instances/{}/getGuestAttributes?queryPath=guestInventory/",
            self.compute_base_url, project, zone, instance
        );

        let response = client
            .get(&url)
            .bearer_auth(&token)
            .send()
            .await;

        match response {
            Ok(resp) if resp.status().is_success() => {
                let attrs: serde_json::Value = resp.json().await.unwrap_or_default();

                let mut status = GuestAgentStatus {
                    is_reporting: true,
                    ..Default::default()
                };

                // Parse guest inventory attributes
                if let Some(items) = attrs["queryValue"]["items"].as_array() {
                    for item in items {
                        let key = item["key"].as_str().unwrap_or("");
                        let value = item["value"].as_str().unwrap_or("");

                        match key {
                            "ShortName" | "Hostname" => {
                                // OS type indicator
                            }
                            "LongName" | "KernelRelease" => {
                                status.os_version = Some(value.to_string());
                            }
                            "LastUpdated" => {
                                status.last_heartbeat = Some(value.to_string());
                            }
                            _ => {}
                        }
                    }
                }

                Ok(status)
            }
            Ok(resp) => {
                // 404 means no guest attributes (agent not running or not configured)
                if resp.status().as_u16() == 404 {
                    debug!("Guest attributes not available for {}", instance);
                }
                self.check_guest_agent_via_serial(project, zone, instance).await
            }
            Err(e) => {
                warn!("Failed to get guest attributes: {}", e);
                self.check_guest_agent_via_serial(project, zone, instance).await
            }
        }
    }

    /// Get audit logs for a VM
    ///
    /// API: POST /entries:list
    pub async fn get_audit_logs(
        &self,
        project: &str,
        filter: AuditLogFilter,
    ) -> Result<Vec<AuditLogEntry>> {
        info!("📋 Getting audit logs for project {}", project);

        let token = self.auth.get_access_token().await?;
        let client = reqwest::Client::new();

        let url = format!("{}/entries:list", self.logging_base_url);

        // Build filter string
        let hours = filter.hours_ago.unwrap_or(24);
        let mut filter_parts = vec![
            format!("logName:\"projects/{}/logs/cloudaudit.googleapis.com\"", project),
            format!("timestamp >= \"{}\"",
                (chrono::Utc::now() - chrono::Duration::hours(hours as i64)).to_rfc3339()),
        ];

        // Add instance filter if specified
        if let Some(instance_name) = &filter.instance_name {
            filter_parts.push(format!(
                "protoPayload.resourceName:\"instances/{}\"",
                instance_name
            ));
        }

        // Add method filter if specified
        if let Some(methods) = &filter.method_filter {
            let method_filter = methods.iter()
                .map(|m| format!("protoPayload.methodName=\"{}\"", m))
                .collect::<Vec<_>>()
                .join(" OR ");
            filter_parts.push(format!("({})", method_filter));
        }

        // Add severity filter if specified
        if let Some(severities) = &filter.severity_filter {
            let sev_filter = severities.iter()
                .map(|s| format!("severity=\"{}\"", s))
                .collect::<Vec<_>>()
                .join(" OR ");
            filter_parts.push(format!("({})", sev_filter));
        }

        let filter_string = filter_parts.join(" AND ");
        debug!("Audit log filter: {}", filter_string);

        let body = serde_json::json!({
            "resourceNames": [format!("projects/{}", project)],
            "filter": filter_string,
            "orderBy": "timestamp desc",
            "pageSize": filter.max_entries.unwrap_or(100),
        });

        let response = client
            .post(&url)
            .bearer_auth(&token)
            .header("Content-Type", "application/json")
            .json(&body)
            .send()
            .await
            .map_err(|e| anyhow!("Failed to send request: {}", e))?;

        if !response.status().is_success() {
            let status = response.status();
            let error_text = response.text().await.unwrap_or_default();
            error!("API request failed: {} - {}", status, redact_sensitive(&error_text));

            if status.as_u16() == 403 {
                return Err(anyhow!(
                    "PERMISSION_DENIED: You don't have permission to read audit logs. \
                    Required permission: 'logging.logEntries.list'."
                ));
            }

            return Err(anyhow!("API error {}: {}", status, redact_sensitive(&error_text)));
        }

        let response_json: serde_json::Value = response.json().await?;

        let entries: Vec<AuditLogEntry> = response_json["entries"]
            .as_array()
            .map(|arr| {
                arr.iter().filter_map(|entry| {
                    Some(AuditLogEntry {
                        insert_id: entry["insertId"].as_str()?.to_string(),
                        timestamp: entry["timestamp"].as_str()?.to_string(),
                        severity: entry["severity"].as_str().unwrap_or("DEFAULT").to_string(),
                        log_name: entry["logName"].as_str()
                            .and_then(|n| n.split('/').last())
                            .unwrap_or("unknown")
                            .to_string(),
                        resource_type: entry["resource"]["type"].as_str()
                            .unwrap_or("unknown")
                            .to_string(),
                        method_name: entry["protoPayload"]["methodName"]
                            .as_str()
                            .map(String::from),
                        principal_email: entry["protoPayload"]["authenticationInfo"]["principalEmail"]
                            .as_str()
                            .map(|e| redact_email_domain(e)),
                        status_code: entry["protoPayload"]["status"]["code"].as_i64()
                            .map(|c| c as i32),
                        status_message: entry["protoPayload"]["status"]["message"]
                            .as_str()
                            .map(String::from),
                        resource_name: entry["protoPayload"]["resourceName"]
                            .as_str()
                            .and_then(|r| r.split('/').last())
                            .map(String::from),
                        request_summary: summarize_request(&entry["protoPayload"]["request"]),
                    })
                }).collect()
            })
            .unwrap_or_default();

        info!("✓ Got {} audit log entries", entries.len());

        Ok(entries)
    }
}

// ==========================================
// HELPER FUNCTIONS
// ==========================================

/// Redact email domain for privacy (keep username@...)
fn redact_email_domain(email: &str) -> String {
    if let Some(at_pos) = email.find('@') {
        let username = &email[..at_pos];
        format!("{}@...", username)
    } else {
        "***".to_string()
    }
}

/// Summarize request payload (avoid exposing sensitive data)
fn summarize_request(request: &serde_json::Value) -> Option<String> {
    if request.is_null() {
        return None;
    }

    // Just return a brief summary of what the request contained
    let keys: Vec<&str> = request.as_object()
        .map(|obj| obj.keys().map(|s| s.as_str()).collect())
        .unwrap_or_default();

    if keys.is_empty() {
        None
    } else {
        Some(format!("Fields: {}", keys.join(", ")))
    }
}

// ==========================================
// PUBLIC API FUNCTIONS
// ==========================================

/// Get serial port output from a VM instance
pub async fn get_serial_port_output(
    project: String,
    zone: String,
    instance: String,
    port: u8,
    start: Option<i64>,
) -> Result<SerialPortOutput> {
    let port_num = match port {
        1 => SerialPortNumber::Port1,
        2 => SerialPortNumber::Port2,
        3 => SerialPortNumber::Port3,
        4 => SerialPortNumber::Port4,
        _ => SerialPortNumber::Port1,
    };

    let client = DiagnosticsClient::new().await?;
    client.get_serial_port_output(&project, &zone, &instance, port_num, start).await
}

/// Get VM diagnostics
pub async fn get_vm_diagnostics(
    project: String,
    zone: String,
    instance: String,
) -> Result<VmDiagnostics> {
    let client = DiagnosticsClient::new().await?;
    client.get_vm_diagnostics(&project, &zone, &instance).await
}

/// Get audit logs for a project
pub async fn get_audit_logs(
    project: String,
    instance_name: Option<String>,
    max_entries: Option<u32>,
    hours_ago: Option<u32>,
) -> Result<Vec<AuditLogEntry>> {
    let client = DiagnosticsClient::new().await?;
    client.get_audit_logs(&project, AuditLogFilter {
        instance_name,
        max_entries,
        hours_ago,
        ..Default::default()
    }).await
}

// ==========================================
// TESTS
// ==========================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_serial_port_number_values() {
        assert_eq!(SerialPortNumber::Port1.as_u8(), 1);
        assert_eq!(SerialPortNumber::Port2.as_u8(), 2);
        assert_eq!(SerialPortNumber::Port3.as_u8(), 3);
        assert_eq!(SerialPortNumber::Port4.as_u8(), 4);
    }

    #[test]
    fn test_redact_email_domain() {
        assert_eq!(redact_email_domain("user@example.com"), "user@...");
        assert_eq!(redact_email_domain("admin@corp.company.com"), "admin@...");
        assert_eq!(redact_email_domain("invalid"), "***");
    }

    #[test]
    fn test_summarize_request() {
        let request = serde_json::json!({
            "name": "test",
            "zone": "us-central1-a"
        });
        let summary = summarize_request(&request);
        assert!(summary.is_some());
        assert!(summary.unwrap().contains("name"));
    }

    #[test]
    fn test_summarize_request_null() {
        let request = serde_json::Value::Null;
        assert!(summarize_request(&request).is_none());
    }

    #[test]
    fn test_default_guest_agent_status() {
        let status = GuestAgentStatus::default();
        assert!(!status.is_reporting);
        assert!(status.os_type.is_none());
    }
}
