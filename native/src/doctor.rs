/// Connectivity Doctor Module - Sprint 7
///
/// Automated troubleshooter that diagnoses connectivity problems with GCP VMs.
/// Runs 10 checks grouped in 5 categories and generates actionable reports.
///
/// Categories:
/// 1. Authentication - gcloud CLI, active account, ADC credentials
/// 2. ProjectPermissions - project access, Compute Engine API
/// 3. IapNetwork - IAP API, firewall rules
/// 4. VmStatus - VM state, guest agent
/// 5. LocalEnvironment - local remote clients (RDP, VNC, SSH)

use anyhow::{Result, anyhow};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use std::time::Instant;
use tracing::info;

use crate::gcp_rest_client::GcpAuthClient;
use crate::redact::redact_sensitive;

// ==========================================
// ENUMS & STRUCTS
// ==========================================

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum DoctorCheckStatus {
    Pass,
    Warning,
    Fail,
    Skipped,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum DoctorCheckCategory {
    Authentication,
    ProjectPermissions,
    IapNetwork,
    VmStatus,
    LocalEnvironment,
}

impl DoctorCheckCategory {
    pub fn display_name(&self) -> &'static str {
        match self {
            DoctorCheckCategory::Authentication => "Authentication",
            DoctorCheckCategory::ProjectPermissions => "Project & Permissions",
            DoctorCheckCategory::IapNetwork => "IAP & Network",
            DoctorCheckCategory::VmStatus => "VM Status",
            DoctorCheckCategory::LocalEnvironment => "Local Environment",
        }
    }

    pub fn all() -> Vec<DoctorCheckCategory> {
        vec![
            DoctorCheckCategory::Authentication,
            DoctorCheckCategory::ProjectPermissions,
            DoctorCheckCategory::IapNetwork,
            DoctorCheckCategory::VmStatus,
            DoctorCheckCategory::LocalEnvironment,
        ]
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DoctorCheckResult {
    pub check_id: String,
    pub name: String,
    pub category: DoctorCheckCategory,
    pub status: DoctorCheckStatus,
    pub message: String,
    pub details: Option<String>,
    pub suggestion: Option<String>,
    pub fix_command: Option<String>,
    pub fix_action_id: Option<String>,
    pub duration_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DoctorReport {
    pub checks: Vec<DoctorCheckResult>,
    pub project_id: String,
    pub zone: String,
    pub instance_name: String,
    pub generated_at: String,
    pub gcloud_version: Option<String>,
    pub gcloud_account: Option<String>,
    pub total_duration_ms: u64,
    pub pass_count: u32,
    pub warning_count: u32,
    pub fail_count: u32,
    pub skipped_count: u32,
}

// ==========================================
// DOCTOR CLIENT
// ==========================================

pub struct DoctorClient {
    auth: Option<Arc<GcpAuthClient>>,
    compute_base_url: String,
    serviceusage_base_url: String,
    crm_base_url: String,
}

impl DoctorClient {
    pub fn new() -> Self {
        let auth = GcpAuthClient::get_or_init().ok();

        Self {
            auth,
            compute_base_url: "https://compute.googleapis.com/compute/v1".to_string(),
            serviceusage_base_url: "https://serviceusage.googleapis.com/v1".to_string(),
            crm_base_url: "https://cloudresourcemanager.googleapis.com/v1".to_string(),
        }
    }

    // ==========================================
    // CHECK 1: gcloud CLI installed
    // ==========================================

    fn check_gcloud_installed(&self) -> DoctorCheckResult {
        let start = Instant::now();
        let installed = crate::gcloud::is_gcloud_installed();

        if installed {
            DoctorCheckResult {
                check_id: "auth_gcloud_installed".to_string(),
                name: "gcloud CLI Installed".to_string(),
                category: DoctorCheckCategory::Authentication,
                status: DoctorCheckStatus::Pass,
                message: "gcloud CLI is installed and accessible".to_string(),
                details: None,
                suggestion: None,
                fix_command: None,
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            }
        } else {
            DoctorCheckResult {
                check_id: "auth_gcloud_installed".to_string(),
                name: "gcloud CLI Installed".to_string(),
                category: DoctorCheckCategory::Authentication,
                status: DoctorCheckStatus::Fail,
                message: "gcloud CLI is not installed or not in PATH".to_string(),
                details: Some("The Google Cloud SDK (gcloud) is required for IAP tunneling and authentication.".to_string()),
                suggestion: Some("Install the Google Cloud SDK from https://cloud.google.com/sdk/docs/install".to_string()),
                fix_command: Some("curl https://sdk.cloud.google.com | bash".to_string()),
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            }
        }
    }

    // ==========================================
    // CHECK 2: gcloud authenticated
    // ==========================================

    fn check_gcloud_account(&self) -> DoctorCheckResult {
        let start = Instant::now();
        let authenticated = crate::gcloud::is_gcloud_authenticated();

        if authenticated {
            let account = crate::gcloud::get_gcloud_account().unwrap_or_default();
            DoctorCheckResult {
                check_id: "auth_gcloud_account".to_string(),
                name: "gcloud Account Active".to_string(),
                category: DoctorCheckCategory::Authentication,
                status: DoctorCheckStatus::Pass,
                message: format!("Authenticated as: {}", account),
                details: None,
                suggestion: None,
                fix_command: None,
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            }
        } else {
            DoctorCheckResult {
                check_id: "auth_gcloud_account".to_string(),
                name: "gcloud Account Active".to_string(),
                category: DoctorCheckCategory::Authentication,
                status: DoctorCheckStatus::Fail,
                message: "No active gcloud account found".to_string(),
                details: Some("You need to authenticate with gcloud to access GCP resources.".to_string()),
                suggestion: Some("Run 'gcloud auth login' to authenticate.".to_string()),
                fix_command: Some("gcloud auth login".to_string()),
                fix_action_id: Some("re_authenticate".to_string()),
                duration_ms: start.elapsed().as_millis() as u64,
            }
        }
    }

    // ==========================================
    // CHECK 3: ADC credentials file
    // ==========================================

    fn check_adc_credentials(&self) -> DoctorCheckResult {
        let start = Instant::now();
        let home = std::env::var("HOME")
            .or_else(|_| std::env::var("USERPROFILE"))
            .unwrap_or_default();

        let creds_path = std::path::PathBuf::from(&home)
            .join(".config")
            .join("gcloud")
            .join("application_default_credentials.json");

        if creds_path.exists() {
            DoctorCheckResult {
                check_id: "auth_adc_credentials".to_string(),
                name: "Application Default Credentials".to_string(),
                category: DoctorCheckCategory::Authentication,
                status: DoctorCheckStatus::Pass,
                message: "ADC credentials file found".to_string(),
                details: Some(format!("Path: {}", creds_path.display())),
                suggestion: None,
                fix_command: None,
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            }
        } else {
            DoctorCheckResult {
                check_id: "auth_adc_credentials".to_string(),
                name: "Application Default Credentials".to_string(),
                category: DoctorCheckCategory::Authentication,
                status: DoctorCheckStatus::Fail,
                message: "ADC credentials file not found".to_string(),
                details: Some(format!("Expected at: {}", creds_path.display())),
                suggestion: Some("Run 'gcloud auth application-default login' to create ADC credentials.".to_string()),
                fix_command: Some("gcloud auth application-default login".to_string()),
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            }
        }
    }

    // ==========================================
    // CHECK 4: Project accessible
    // ==========================================

    async fn check_project_accessible(&self, project: &str) -> DoctorCheckResult {
        let start = Instant::now();
        let auth = match &self.auth {
            Some(a) => a,
            None => return self.skipped_check(
                "project_accessible",
                "Project Accessible",
                DoctorCheckCategory::ProjectPermissions,
                "Skipped: no authentication available",
                start,
            ),
        };

        let token = match auth.get_access_token().await {
            Ok(t) => t,
            Err(e) => return DoctorCheckResult {
                check_id: "project_accessible".to_string(),
                name: "Project Accessible".to_string(),
                category: DoctorCheckCategory::ProjectPermissions,
                status: DoctorCheckStatus::Fail,
                message: "Failed to get access token".to_string(),
                details: Some(format!("Error: {}", redact_sensitive(&e.to_string()))),
                suggestion: Some("Re-authenticate with 'gcloud auth application-default login'.".to_string()),
                fix_command: Some("gcloud auth application-default login".to_string()),
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
        };

        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(10))
            .build()
            .unwrap_or_default();

        let url = format!("{}/projects/{}", self.crm_base_url, project);
        let resp = client.get(&url).bearer_auth(&token).send().await;

        match resp {
            Ok(r) if r.status().is_success() => DoctorCheckResult {
                check_id: "project_accessible".to_string(),
                name: "Project Accessible".to_string(),
                category: DoctorCheckCategory::ProjectPermissions,
                status: DoctorCheckStatus::Pass,
                message: format!("Project '{}' is accessible", project),
                details: None,
                suggestion: None,
                fix_command: None,
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
            Ok(r) if r.status().as_u16() == 403 => DoctorCheckResult {
                check_id: "project_accessible".to_string(),
                name: "Project Accessible".to_string(),
                category: DoctorCheckCategory::ProjectPermissions,
                status: DoctorCheckStatus::Fail,
                message: format!("Permission denied for project '{}'", project),
                details: Some("Your account does not have access to this project.".to_string()),
                suggestion: Some("Ensure you have the 'Viewer' role or higher on the project.".to_string()),
                fix_command: None,
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
            Ok(r) if r.status().as_u16() == 404 => DoctorCheckResult {
                check_id: "project_accessible".to_string(),
                name: "Project Accessible".to_string(),
                category: DoctorCheckCategory::ProjectPermissions,
                status: DoctorCheckStatus::Fail,
                message: format!("Project '{}' not found", project),
                details: Some("The project ID may be incorrect or the project may have been deleted.".to_string()),
                suggestion: Some("Verify the project ID is correct.".to_string()),
                fix_command: Some("gcloud projects list".to_string()),
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
            Ok(r) => DoctorCheckResult {
                check_id: "project_accessible".to_string(),
                name: "Project Accessible".to_string(),
                category: DoctorCheckCategory::ProjectPermissions,
                status: DoctorCheckStatus::Fail,
                message: format!("Unexpected response: HTTP {}", r.status()),
                details: None,
                suggestion: None,
                fix_command: None,
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
            Err(e) => DoctorCheckResult {
                check_id: "project_accessible".to_string(),
                name: "Project Accessible".to_string(),
                category: DoctorCheckCategory::ProjectPermissions,
                status: DoctorCheckStatus::Fail,
                message: "Network error checking project access".to_string(),
                details: Some(format!("Error: {}", redact_sensitive(&e.to_string()))),
                suggestion: Some("Check your network connection.".to_string()),
                fix_command: None,
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
        }
    }

    // ==========================================
    // CHECK 5: Compute Engine API enabled
    // ==========================================

    async fn check_compute_api_enabled(&self, project: &str) -> DoctorCheckResult {
        self.check_api_enabled(
            project,
            "compute.googleapis.com",
            "compute_api_enabled",
            "Compute Engine API",
            "gcloud services enable compute.googleapis.com",
        ).await
    }

    // ==========================================
    // CHECK 6: IAP API enabled
    // ==========================================

    async fn check_iap_api_enabled(&self, project: &str) -> DoctorCheckResult {
        self.check_api_enabled(
            project,
            "iap.googleapis.com",
            "iap_api_enabled",
            "IAP API",
            "gcloud services enable iap.googleapis.com",
        ).await
    }

    /// Generic API enabled check
    async fn check_api_enabled(
        &self,
        project: &str,
        api_name: &str,
        check_id: &str,
        display_name: &str,
        fix_cmd: &str,
    ) -> DoctorCheckResult {
        let start = Instant::now();
        let category = if check_id.starts_with("iap") {
            DoctorCheckCategory::IapNetwork
        } else {
            DoctorCheckCategory::ProjectPermissions
        };

        let auth = match &self.auth {
            Some(a) => a,
            None => return self.skipped_check(
                check_id,
                display_name,
                category,
                "Skipped: no authentication available",
                start,
            ),
        };

        let token = match auth.get_access_token().await {
            Ok(t) => t,
            Err(_) => return self.skipped_check(
                check_id,
                display_name,
                category,
                "Skipped: failed to get access token",
                start,
            ),
        };

        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(10))
            .build()
            .unwrap_or_default();

        let url = format!(
            "{}/projects/{}/services/{}",
            self.serviceusage_base_url, project, api_name
        );

        let resp = client.get(&url).bearer_auth(&token).send().await;

        match resp {
            Ok(r) if r.status().is_success() => {
                let body: serde_json::Value = r.json().await.unwrap_or_default();
                let state = body["state"].as_str().unwrap_or("UNKNOWN");
                if state == "ENABLED" {
                    DoctorCheckResult {
                        check_id: check_id.to_string(),
                        name: format!("{} Enabled", display_name),
                        category,
                        status: DoctorCheckStatus::Pass,
                        message: format!("{} is enabled", display_name),
                        details: None,
                        suggestion: None,
                        fix_command: None,
                        fix_action_id: None,
                        duration_ms: start.elapsed().as_millis() as u64,
                    }
                } else {
                    DoctorCheckResult {
                        check_id: check_id.to_string(),
                        name: format!("{} Enabled", display_name),
                        category,
                        status: DoctorCheckStatus::Fail,
                        message: format!("{} is not enabled (state: {})", display_name, state),
                        details: Some(format!("The {} needs to be enabled for this project.", display_name)),
                        suggestion: Some(format!("Enable it with: {}", fix_cmd)),
                        fix_command: Some(fix_cmd.to_string()),
                        fix_action_id: None,
                        duration_ms: start.elapsed().as_millis() as u64,
                    }
                }
            }
            Ok(r) => {
                let status = r.status();
                DoctorCheckResult {
                    check_id: check_id.to_string(),
                    name: format!("{} Enabled", display_name),
                    category,
                    status: DoctorCheckStatus::Fail,
                    message: format!("Could not check {} status (HTTP {})", display_name, status),
                    details: None,
                    suggestion: Some(format!("Try enabling manually: {}", fix_cmd)),
                    fix_command: Some(fix_cmd.to_string()),
                    fix_action_id: None,
                    duration_ms: start.elapsed().as_millis() as u64,
                }
            }
            Err(e) => DoctorCheckResult {
                check_id: check_id.to_string(),
                name: format!("{} Enabled", display_name),
                category,
                status: DoctorCheckStatus::Fail,
                message: format!("Network error checking {}", display_name),
                details: Some(format!("Error: {}", redact_sensitive(&e.to_string()))),
                suggestion: Some("Check your network connection.".to_string()),
                fix_command: None,
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
        }
    }

    // ==========================================
    // CHECK 7: IAP firewall rule
    // ==========================================

    async fn check_iap_firewall(&self, project: &str) -> DoctorCheckResult {
        let start = Instant::now();
        let auth = match &self.auth {
            Some(a) => a,
            None => return self.skipped_check(
                "iap_firewall",
                "IAP Firewall Rule",
                DoctorCheckCategory::IapNetwork,
                "Skipped: no authentication available",
                start,
            ),
        };

        let token = match auth.get_access_token().await {
            Ok(t) => t,
            Err(_) => return self.skipped_check(
                "iap_firewall",
                "IAP Firewall Rule",
                DoctorCheckCategory::IapNetwork,
                "Skipped: failed to get access token",
                start,
            ),
        };

        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(10))
            .build()
            .unwrap_or_default();

        let url = format!(
            "{}/projects/{}/global/firewalls",
            self.compute_base_url, project
        );

        let resp = client.get(&url).bearer_auth(&token).send().await;

        match resp {
            Ok(r) if r.status().is_success() => {
                let body: serde_json::Value = r.json().await.unwrap_or_default();
                let firewalls = body["items"].as_array();

                let iap_range = "35.235.240.0/20";
                let has_iap_rule = firewalls.map(|rules| {
                    rules.iter().any(|rule| {
                        let direction = rule["direction"].as_str().unwrap_or("");
                        if direction != "INGRESS" {
                            return false;
                        }
                        let disabled = rule["disabled"].as_bool().unwrap_or(false);
                        if disabled {
                            return false;
                        }
                        rule["sourceRanges"].as_array()
                            .map(|ranges| {
                                ranges.iter().any(|r| {
                                    r.as_str().map(|s| s == iap_range).unwrap_or(false)
                                })
                            })
                            .unwrap_or(false)
                    })
                }).unwrap_or(false);

                if has_iap_rule {
                    DoctorCheckResult {
                        check_id: "iap_firewall".to_string(),
                        name: "IAP Firewall Rule".to_string(),
                        category: DoctorCheckCategory::IapNetwork,
                        status: DoctorCheckStatus::Pass,
                        message: "Firewall rule allowing IAP range (35.235.240.0/20) found".to_string(),
                        details: None,
                        suggestion: None,
                        fix_command: None,
                        fix_action_id: None,
                        duration_ms: start.elapsed().as_millis() as u64,
                    }
                } else {
                    DoctorCheckResult {
                        check_id: "iap_firewall".to_string(),
                        name: "IAP Firewall Rule".to_string(),
                        category: DoctorCheckCategory::IapNetwork,
                        status: DoctorCheckStatus::Warning,
                        message: "No firewall rule found for IAP range (35.235.240.0/20)".to_string(),
                        details: Some("IAP tunneling requires a firewall rule that allows ingress from 35.235.240.0/20.".to_string()),
                        suggestion: Some("Create a firewall rule allowing TCP ingress from 35.235.240.0/20.".to_string()),
                        fix_command: Some(format!(
                            "gcloud compute firewall-rules create allow-iap --project={} --direction=INGRESS --action=ALLOW --rules=tcp:22,tcp:3389 --source-ranges=35.235.240.0/20",
                            project
                        )),
                        fix_action_id: None,
                        duration_ms: start.elapsed().as_millis() as u64,
                    }
                }
            }
            Ok(r) if r.status().as_u16() == 403 => DoctorCheckResult {
                check_id: "iap_firewall".to_string(),
                name: "IAP Firewall Rule".to_string(),
                category: DoctorCheckCategory::IapNetwork,
                status: DoctorCheckStatus::Warning,
                message: "Permission denied to list firewall rules".to_string(),
                details: Some("Cannot verify IAP firewall rules without 'compute.firewalls.list' permission.".to_string()),
                suggestion: Some("Ask a project admin to verify IAP firewall rules exist.".to_string()),
                fix_command: None,
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
            Ok(r) => DoctorCheckResult {
                check_id: "iap_firewall".to_string(),
                name: "IAP Firewall Rule".to_string(),
                category: DoctorCheckCategory::IapNetwork,
                status: DoctorCheckStatus::Fail,
                message: format!("Could not check firewall rules (HTTP {})", r.status()),
                details: None,
                suggestion: None,
                fix_command: None,
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
            Err(e) => DoctorCheckResult {
                check_id: "iap_firewall".to_string(),
                name: "IAP Firewall Rule".to_string(),
                category: DoctorCheckCategory::IapNetwork,
                status: DoctorCheckStatus::Fail,
                message: "Network error checking firewall rules".to_string(),
                details: Some(format!("Error: {}", redact_sensitive(&e.to_string()))),
                suggestion: Some("Check your network connection.".to_string()),
                fix_command: None,
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
        }
    }

    // ==========================================
    // CHECK 8: VM status
    // ==========================================

    async fn check_vm_status(&self, project: &str, zone: &str, instance: &str) -> DoctorCheckResult {
        let start = Instant::now();
        let auth = match &self.auth {
            Some(a) => a,
            None => return self.skipped_check(
                "vm_status",
                "VM Status",
                DoctorCheckCategory::VmStatus,
                "Skipped: no authentication available",
                start,
            ),
        };

        let token = match auth.get_access_token().await {
            Ok(t) => t,
            Err(_) => return self.skipped_check(
                "vm_status",
                "VM Status",
                DoctorCheckCategory::VmStatus,
                "Skipped: failed to get access token",
                start,
            ),
        };

        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(10))
            .build()
            .unwrap_or_default();

        let url = format!(
            "{}/projects/{}/zones/{}/instances/{}",
            self.compute_base_url, project, zone, instance
        );

        let resp = client.get(&url).bearer_auth(&token).send().await;

        match resp {
            Ok(r) if r.status().is_success() => {
                let body: serde_json::Value = r.json().await.unwrap_or_default();
                let status = body["status"].as_str().unwrap_or("UNKNOWN");

                match status {
                    "RUNNING" => DoctorCheckResult {
                        check_id: "vm_status".to_string(),
                        name: "VM Status".to_string(),
                        category: DoctorCheckCategory::VmStatus,
                        status: DoctorCheckStatus::Pass,
                        message: format!("VM '{}' is RUNNING", instance),
                        details: None,
                        suggestion: None,
                        fix_command: None,
                        fix_action_id: None,
                        duration_ms: start.elapsed().as_millis() as u64,
                    },
                    "TERMINATED" | "STOPPED" => DoctorCheckResult {
                        check_id: "vm_status".to_string(),
                        name: "VM Status".to_string(),
                        category: DoctorCheckCategory::VmStatus,
                        status: DoctorCheckStatus::Fail,
                        message: format!("VM '{}' is {} (not running)", instance, status),
                        details: Some("The VM must be running to establish connections.".to_string()),
                        suggestion: Some("Start the VM to enable connections.".to_string()),
                        fix_command: Some(format!(
                            "gcloud compute instances start {} --project={} --zone={}",
                            instance, project, zone
                        )),
                        fix_action_id: Some("start_vm".to_string()),
                        duration_ms: start.elapsed().as_millis() as u64,
                    },
                    "STAGING" | "PROVISIONING" => DoctorCheckResult {
                        check_id: "vm_status".to_string(),
                        name: "VM Status".to_string(),
                        category: DoctorCheckCategory::VmStatus,
                        status: DoctorCheckStatus::Warning,
                        message: format!("VM '{}' is {} (starting up)", instance, status),
                        details: Some("The VM is starting up. Wait a few minutes.".to_string()),
                        suggestion: Some("Wait for the VM to reach RUNNING state.".to_string()),
                        fix_command: None,
                        fix_action_id: None,
                        duration_ms: start.elapsed().as_millis() as u64,
                    },
                    _ => DoctorCheckResult {
                        check_id: "vm_status".to_string(),
                        name: "VM Status".to_string(),
                        category: DoctorCheckCategory::VmStatus,
                        status: DoctorCheckStatus::Warning,
                        message: format!("VM '{}' is in state: {}", instance, status),
                        details: None,
                        suggestion: None,
                        fix_command: None,
                        fix_action_id: None,
                        duration_ms: start.elapsed().as_millis() as u64,
                    },
                }
            }
            Ok(r) if r.status().as_u16() == 404 => DoctorCheckResult {
                check_id: "vm_status".to_string(),
                name: "VM Status".to_string(),
                category: DoctorCheckCategory::VmStatus,
                status: DoctorCheckStatus::Fail,
                message: format!("VM '{}' not found in {}/{}", instance, project, zone),
                details: Some("The instance name or zone may be incorrect.".to_string()),
                suggestion: Some("Verify the instance name and zone.".to_string()),
                fix_command: Some(format!("gcloud compute instances list --project={}", project)),
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
            Ok(r) => DoctorCheckResult {
                check_id: "vm_status".to_string(),
                name: "VM Status".to_string(),
                category: DoctorCheckCategory::VmStatus,
                status: DoctorCheckStatus::Fail,
                message: format!("Could not check VM status (HTTP {})", r.status()),
                details: None,
                suggestion: None,
                fix_command: None,
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
            Err(e) => DoctorCheckResult {
                check_id: "vm_status".to_string(),
                name: "VM Status".to_string(),
                category: DoctorCheckCategory::VmStatus,
                status: DoctorCheckStatus::Fail,
                message: "Network error checking VM status".to_string(),
                details: Some(format!("Error: {}", redact_sensitive(&e.to_string()))),
                suggestion: Some("Check your network connection.".to_string()),
                fix_command: None,
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
        }
    }

    // ==========================================
    // CHECK 9: Guest agent
    // ==========================================

    async fn check_vm_guest_agent(&self, project: &str, zone: &str, instance: &str) -> DoctorCheckResult {
        let start = Instant::now();
        let auth = match &self.auth {
            Some(a) => a,
            None => return self.skipped_check(
                "vm_guest_agent",
                "VM Guest Agent",
                DoctorCheckCategory::VmStatus,
                "Skipped: no authentication available",
                start,
            ),
        };

        let token = match auth.get_access_token().await {
            Ok(t) => t,
            Err(_) => return self.skipped_check(
                "vm_guest_agent",
                "VM Guest Agent",
                DoctorCheckCategory::VmStatus,
                "Skipped: failed to get access token",
                start,
            ),
        };

        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(10))
            .build()
            .unwrap_or_default();

        let url = format!(
            "{}/projects/{}/zones/{}/instances/{}/getGuestAttributes?queryPath=guestInventory/",
            self.compute_base_url, project, zone, instance
        );

        let resp = client.get(&url).bearer_auth(&token).send().await;

        match resp {
            Ok(r) if r.status().is_success() => {
                let body: serde_json::Value = r.json().await.unwrap_or_default();
                let has_items = body["queryValue"]["items"].as_array()
                    .map(|a| !a.is_empty())
                    .unwrap_or(false);

                if has_items {
                    DoctorCheckResult {
                        check_id: "vm_guest_agent".to_string(),
                        name: "VM Guest Agent".to_string(),
                        category: DoctorCheckCategory::VmStatus,
                        status: DoctorCheckStatus::Pass,
                        message: "Guest agent is responding".to_string(),
                        details: None,
                        suggestion: None,
                        fix_command: None,
                        fix_action_id: None,
                        duration_ms: start.elapsed().as_millis() as u64,
                    }
                } else {
                    DoctorCheckResult {
                        check_id: "vm_guest_agent".to_string(),
                        name: "VM Guest Agent".to_string(),
                        category: DoctorCheckCategory::VmStatus,
                        status: DoctorCheckStatus::Warning,
                        message: "Guest agent returned empty inventory".to_string(),
                        details: Some("The guest agent may be starting up or not fully configured.".to_string()),
                        suggestion: Some("Wait a few minutes after VM start, or check the guest agent service.".to_string()),
                        fix_command: None,
                        fix_action_id: None,
                        duration_ms: start.elapsed().as_millis() as u64,
                    }
                }
            }
            Ok(r) if r.status().as_u16() == 404 => DoctorCheckResult {
                check_id: "vm_guest_agent".to_string(),
                name: "VM Guest Agent".to_string(),
                category: DoctorCheckCategory::VmStatus,
                status: DoctorCheckStatus::Warning,
                message: "Guest agent not reporting (no guest attributes)".to_string(),
                details: Some("Guest attributes are not available. The agent may not be installed or VM may be stopped.".to_string()),
                suggestion: Some("Ensure the VM is running and the guest agent is installed.".to_string()),
                fix_command: None,
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
            Ok(_) | Err(_) => DoctorCheckResult {
                check_id: "vm_guest_agent".to_string(),
                name: "VM Guest Agent".to_string(),
                category: DoctorCheckCategory::VmStatus,
                status: DoctorCheckStatus::Warning,
                message: "Could not check guest agent status".to_string(),
                details: Some("This check is informational and does not block connectivity.".to_string()),
                suggestion: None,
                fix_command: None,
                fix_action_id: None,
                duration_ms: start.elapsed().as_millis() as u64,
            },
        }
    }

    // ==========================================
    // CHECK 10: Local clients installed
    // ==========================================

    fn check_local_clients(&self) -> DoctorCheckResult {
        let start = Instant::now();

        // Check RDP clients
        let rdp_clients: Vec<String> = crate::rdp_client::RdpClientType::fallback_order()
            .into_iter()
            .filter(|c| c.is_available())
            .map(|c| c.display_name().to_string())
            .collect();

        // Check VNC clients
        let vnc_clients: Vec<String> = crate::vnc_client::VncClientType::fallback_order()
            .into_iter()
            .filter(|c| c.is_available())
            .map(|c| c.display_name().to_string())
            .collect();

        // Check SSH
        let ssh_available = std::process::Command::new("ssh")
            .arg("-V")
            .output()
            .is_ok();

        let mut details_parts = Vec::new();
        if !rdp_clients.is_empty() {
            details_parts.push(format!("RDP: {}", rdp_clients.join(", ")));
        } else {
            details_parts.push("RDP: none found".to_string());
        }
        if !vnc_clients.is_empty() {
            details_parts.push(format!("VNC: {}", vnc_clients.join(", ")));
        } else {
            details_parts.push("VNC: none found".to_string());
        }
        details_parts.push(format!("SSH: {}", if ssh_available { "available" } else { "not found" }));

        let has_any = !rdp_clients.is_empty() || !vnc_clients.is_empty() || ssh_available;
        let has_all = !rdp_clients.is_empty() && !vnc_clients.is_empty() && ssh_available;

        let (status, message) = if has_all {
            (DoctorCheckStatus::Pass, "All remote client types available".to_string())
        } else if has_any {
            (DoctorCheckStatus::Warning, "Some remote client types are missing".to_string())
        } else {
            (DoctorCheckStatus::Fail, "No remote clients found".to_string())
        };

        DoctorCheckResult {
            check_id: "local_clients".to_string(),
            name: "Local Remote Clients".to_string(),
            category: DoctorCheckCategory::LocalEnvironment,
            status,
            message,
            details: Some(details_parts.join("\n")),
            suggestion: if !has_all {
                Some("Install missing clients: sudo apt install remmina openssh-client".to_string())
            } else {
                None
            },
            fix_command: if !has_all {
                Some("sudo apt install remmina openssh-client".to_string())
            } else {
                None
            },
            fix_action_id: None,
            duration_ms: start.elapsed().as_millis() as u64,
        }
    }

    // ==========================================
    // HELPER: skipped check
    // ==========================================

    fn skipped_check(
        &self,
        check_id: &str,
        name: &str,
        category: DoctorCheckCategory,
        message: &str,
        start: Instant,
    ) -> DoctorCheckResult {
        DoctorCheckResult {
            check_id: check_id.to_string(),
            name: name.to_string(),
            category,
            status: DoctorCheckStatus::Skipped,
            message: message.to_string(),
            details: None,
            suggestion: None,
            fix_command: None,
            fix_action_id: None,
            duration_ms: start.elapsed().as_millis() as u64,
        }
    }

    // ==========================================
    // ORCHESTRATOR: run all checks
    // ==========================================

    pub async fn run_all_checks(
        &self,
        project_id: &str,
        zone: &str,
        instance_name: &str,
    ) -> DoctorReport {
        let total_start = Instant::now();
        let mut checks = Vec::new();

        info!("🩺 Running Connectivity Doctor for {}/{}/{}", project_id, zone, instance_name);

        // Check 1: gcloud installed
        let c1 = self.check_gcloud_installed();
        let gcloud_installed = c1.status == DoctorCheckStatus::Pass;
        checks.push(c1);

        // Check 2: gcloud account (skip if gcloud not installed)
        if gcloud_installed {
            let c2 = self.check_gcloud_account();
            checks.push(c2);
        } else {
            checks.push(self.skipped_check(
                "auth_gcloud_account",
                "gcloud Account Active",
                DoctorCheckCategory::Authentication,
                "Skipped: gcloud CLI not installed",
                Instant::now(),
            ));
        }

        // Check 3: ADC credentials (always runs)
        checks.push(self.check_adc_credentials());

        // Determine if we can run authenticated checks
        let has_auth = self.auth.is_some();
        let gcloud_authenticated = checks.iter()
            .find(|c| c.check_id == "auth_gcloud_account")
            .map(|c| c.status == DoctorCheckStatus::Pass)
            .unwrap_or(false);

        let can_run_api_checks = has_auth && gcloud_authenticated;

        // Checks 4-9: API-based checks (skip if no auth)
        if can_run_api_checks {
            checks.push(self.check_project_accessible(project_id).await);
            checks.push(self.check_compute_api_enabled(project_id).await);
            checks.push(self.check_iap_api_enabled(project_id).await);
            checks.push(self.check_iap_firewall(project_id).await);
            checks.push(self.check_vm_status(project_id, zone, instance_name).await);
            checks.push(self.check_vm_guest_agent(project_id, zone, instance_name).await);
        } else {
            let skip_msg = if !has_auth {
                "Skipped: no ADC credentials available"
            } else {
                "Skipped: gcloud not authenticated"
            };
            checks.push(self.skipped_check("project_accessible", "Project Accessible", DoctorCheckCategory::ProjectPermissions, skip_msg, Instant::now()));
            checks.push(self.skipped_check("compute_api_enabled", "Compute Engine API Enabled", DoctorCheckCategory::ProjectPermissions, skip_msg, Instant::now()));
            checks.push(self.skipped_check("iap_api_enabled", "IAP API Enabled", DoctorCheckCategory::IapNetwork, skip_msg, Instant::now()));
            checks.push(self.skipped_check("iap_firewall", "IAP Firewall Rule", DoctorCheckCategory::IapNetwork, skip_msg, Instant::now()));
            checks.push(self.skipped_check("vm_status", "VM Status", DoctorCheckCategory::VmStatus, skip_msg, Instant::now()));
            checks.push(self.skipped_check("vm_guest_agent", "VM Guest Agent", DoctorCheckCategory::VmStatus, skip_msg, Instant::now()));
        }

        // Check 10: local clients (always runs)
        checks.push(self.check_local_clients());

        // Build report
        let pass_count = checks.iter().filter(|c| c.status == DoctorCheckStatus::Pass).count() as u32;
        let warning_count = checks.iter().filter(|c| c.status == DoctorCheckStatus::Warning).count() as u32;
        let fail_count = checks.iter().filter(|c| c.status == DoctorCheckStatus::Fail).count() as u32;
        let skipped_count = checks.iter().filter(|c| c.status == DoctorCheckStatus::Skipped).count() as u32;

        let gcloud_version = if gcloud_installed {
            std::process::Command::new("gcloud")
                .arg("--version")
                .output()
                .ok()
                .and_then(|o| String::from_utf8(o.stdout).ok())
                .and_then(|s| s.lines().next().map(|l| l.trim().to_string()))
        } else {
            None
        };

        let gcloud_account = if gcloud_authenticated {
            crate::gcloud::get_gcloud_account().ok()
        } else {
            None
        };

        info!("🩺 Doctor complete: {} pass, {} warn, {} fail, {} skipped",
            pass_count, warning_count, fail_count, skipped_count);

        DoctorReport {
            checks,
            project_id: project_id.to_string(),
            zone: zone.to_string(),
            instance_name: instance_name.to_string(),
            generated_at: chrono::Utc::now().to_rfc3339(),
            gcloud_version,
            gcloud_account,
            total_duration_ms: total_start.elapsed().as_millis() as u64,
            pass_count,
            warning_count,
            fail_count,
            skipped_count,
        }
    }
}

// ==========================================
// REPORT GENERATION
// ==========================================

pub fn generate_doctor_report_markdown(report: &DoctorReport) -> String {
    let mut md = String::new();

    md.push_str("# Connectivity Doctor Report\n\n");
    md.push_str(&format!("**Generated:** {}\n\n", report.generated_at));
    md.push_str(&format!("**Project:** {}\n", report.project_id));
    md.push_str(&format!("**Zone:** {}\n", report.zone));
    md.push_str(&format!("**Instance:** {}\n", report.instance_name));

    if let Some(ver) = &report.gcloud_version {
        md.push_str(&format!("**gcloud:** {}\n", ver));
    }
    if let Some(acc) = &report.gcloud_account {
        md.push_str(&format!("**Account:** {}\n", acc));
    }
    md.push_str("\n");

    // Summary
    md.push_str("## Summary\n\n");
    md.push_str(&format!(
        "| Pass | Warning | Fail | Skipped | Total Time |\n|------|---------|------|---------|------------|\n| {} | {} | {} | {} | {}ms |\n\n",
        report.pass_count, report.warning_count, report.fail_count, report.skipped_count, report.total_duration_ms
    ));

    // Checks grouped by category
    for category in DoctorCheckCategory::all() {
        let cat_checks: Vec<&DoctorCheckResult> = report.checks.iter()
            .filter(|c| c.category == category)
            .collect();

        if cat_checks.is_empty() {
            continue;
        }

        md.push_str(&format!("## {}\n\n", category.display_name()));

        for check in cat_checks {
            let icon = match check.status {
                DoctorCheckStatus::Pass => "PASS",
                DoctorCheckStatus::Warning => "WARN",
                DoctorCheckStatus::Fail => "FAIL",
                DoctorCheckStatus::Skipped => "SKIP",
            };

            md.push_str(&format!("### [{}] {}\n\n", icon, check.name));
            md.push_str(&format!("{}\n\n", check.message));

            if let Some(details) = &check.details {
                md.push_str(&format!("**Details:** {}\n\n", details));
            }
            if let Some(suggestion) = &check.suggestion {
                md.push_str(&format!("**Suggestion:** {}\n\n", suggestion));
            }
            if let Some(fix_cmd) = &check.fix_command {
                md.push_str(&format!("**Fix command:**\n```\n{}\n```\n\n", fix_cmd));
            }
        }
    }

    // Redact sensitive data from the final report
    redact_sensitive(&md)
}

// ==========================================
// FIX ACTIONS
// ==========================================

pub async fn execute_doctor_fix(
    fix_action_id: &str,
    project_id: &str,
    zone: &str,
    instance_name: &str,
) -> Result<String> {
    info!("🔧 Executing doctor fix: {}", fix_action_id);

    match fix_action_id {
        "re_authenticate" => {
            crate::gcloud::execute_login()?;
            Ok("Re-authentication completed. Please run Doctor again.".to_string())
        }
        "start_vm" => {
            let p = project_id.to_string();
            let z = zone.to_string();
            let i = instance_name.to_string();
            tokio::task::spawn_blocking(move || {
                crate::gcloud::start_instance(&p, &z, &i)
            }).await
                .map_err(|e| anyhow!("Task join error: {}", e))??;
            Ok(format!("VM '{}' start command issued. It may take a few minutes.", instance_name))
        }
        _ => Err(anyhow!("Unknown fix action: {}", fix_action_id)),
    }
}

// ==========================================
// PUBLIC API FUNCTIONS
// ==========================================

pub async fn run_doctor(
    project_id: String,
    zone: String,
    instance_name: String,
) -> Result<DoctorReport> {
    let client = DoctorClient::new();
    Ok(client.run_all_checks(&project_id, &zone, &instance_name).await)
}

pub fn generate_doctor_report(report: DoctorReport) -> String {
    generate_doctor_report_markdown(&report)
}

pub async fn execute_fix(
    fix_action_id: String,
    project_id: String,
    zone: String,
    instance_name: String,
) -> Result<String> {
    execute_doctor_fix(&fix_action_id, &project_id, &zone, &instance_name).await
}

// ==========================================
// TESTS
// ==========================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_check_gcloud_installed() {
        let client = DoctorClient::new();
        let result = client.check_gcloud_installed();
        assert_eq!(result.check_id, "auth_gcloud_installed");
        assert_eq!(result.category, DoctorCheckCategory::Authentication);
        // Status depends on environment, but check_id and category should be correct
    }

    #[test]
    fn test_check_local_clients() {
        let client = DoctorClient::new();
        let result = client.check_local_clients();
        assert_eq!(result.check_id, "local_clients");
        assert_eq!(result.category, DoctorCheckCategory::LocalEnvironment);
        // Should have details about available clients
        assert!(result.details.is_some());
    }

    #[test]
    fn test_report_markdown_generation() {
        let report = DoctorReport {
            checks: vec![
                DoctorCheckResult {
                    check_id: "test_check".to_string(),
                    name: "Test Check".to_string(),
                    category: DoctorCheckCategory::Authentication,
                    status: DoctorCheckStatus::Pass,
                    message: "All good".to_string(),
                    details: Some("Detailed info".to_string()),
                    suggestion: None,
                    fix_command: None,
                    fix_action_id: None,
                    duration_ms: 42,
                },
            ],
            project_id: "test-project".to_string(),
            zone: "us-central1-a".to_string(),
            instance_name: "test-vm".to_string(),
            generated_at: "2024-01-01T00:00:00Z".to_string(),
            gcloud_version: Some("Google Cloud SDK 400.0.0".to_string()),
            gcloud_account: Some("test@example.com".to_string()),
            total_duration_ms: 100,
            pass_count: 1,
            warning_count: 0,
            fail_count: 0,
            skipped_count: 0,
        };

        let md = generate_doctor_report_markdown(&report);
        assert!(md.contains("# Connectivity Doctor Report"));
        assert!(md.contains("test-project"));
        assert!(md.contains("test-vm"));
        assert!(md.contains("Test Check"));
        assert!(md.contains("[PASS]"));
        assert!(md.contains("Authentication"));
    }

    #[test]
    fn test_report_redacts_sensitive_data() {
        let report = DoctorReport {
            checks: vec![
                DoctorCheckResult {
                    check_id: "test".to_string(),
                    name: "Test".to_string(),
                    category: DoctorCheckCategory::Authentication,
                    status: DoctorCheckStatus::Fail,
                    message: "Error with token".to_string(),
                    details: Some(r#"access_token: "ya29.secret_value_12345""#.to_string()),
                    suggestion: None,
                    fix_command: None,
                    fix_action_id: None,
                    duration_ms: 10,
                },
            ],
            project_id: "my-project".to_string(),
            zone: "us-central1-a".to_string(),
            instance_name: "my-vm".to_string(),
            generated_at: "2024-01-01T00:00:00Z".to_string(),
            gcloud_version: None,
            gcloud_account: None,
            total_duration_ms: 10,
            pass_count: 0,
            warning_count: 0,
            fail_count: 1,
            skipped_count: 0,
        };

        let md = generate_doctor_report_markdown(&report);
        assert!(!md.contains("ya29.secret_value_12345"));
        assert!(md.contains("[REDACTED]"));
    }

    #[test]
    fn test_category_display_names() {
        assert_eq!(DoctorCheckCategory::Authentication.display_name(), "Authentication");
        assert_eq!(DoctorCheckCategory::ProjectPermissions.display_name(), "Project & Permissions");
        assert_eq!(DoctorCheckCategory::IapNetwork.display_name(), "IAP & Network");
        assert_eq!(DoctorCheckCategory::VmStatus.display_name(), "VM Status");
        assert_eq!(DoctorCheckCategory::LocalEnvironment.display_name(), "Local Environment");
    }

    #[test]
    fn test_category_all() {
        let cats = DoctorCheckCategory::all();
        assert_eq!(cats.len(), 5);
    }

    #[test]
    fn test_skipped_check() {
        let client = DoctorClient::new();
        let result = client.skipped_check(
            "test_id",
            "Test Name",
            DoctorCheckCategory::Authentication,
            "Skipped for testing",
            Instant::now(),
        );
        assert_eq!(result.status, DoctorCheckStatus::Skipped);
        assert_eq!(result.check_id, "test_id");
        assert_eq!(result.name, "Test Name");
    }
}
