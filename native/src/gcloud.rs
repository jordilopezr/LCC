use std::collections::HashMap;
use std::process::Command;
use anyhow::{Result, anyhow};
use serde::{Deserialize, Serialize};
use tracing;
use crate::validation::{validate_project_id, validate_zone, validate_instance_name, validate_email, sanitize_zone_from_url};
use tokio::process::Command as TokioCommand;
use tokio::time::{timeout, Duration};

#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(rename_all = "camelCase")] // gcloud JSON often uses camelCase
pub struct GcpProject {
    pub project_id: String,
    pub name: Option<String>,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct GcpInstance {
    pub name: String,
    pub status: String,
    pub zone: String,
    pub machine_type: String,
    pub cpu_count: Option<u32>,
    pub memory_mb: Option<u32>,
    pub disk_gb: Option<u32>,
    pub labels: Vec<(String, String)>,
    pub os_login_enabled: bool,
    pub is_windows: bool,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct GcloudAccount {
    pub account: String,  // email
    pub status: String,   // "ACTIVE" or ""
}

#[derive(Deserialize)]
struct RawDisk {
    #[serde(rename = "diskSizeGb")]
    disk_size_gb: Option<String>,
    boot: Option<bool>,
    licenses: Option<Vec<String>>,
}

#[derive(Deserialize)]
struct RawMetadataItem {
    key: String,
    value: Option<String>,
}

#[derive(Deserialize)]
struct RawMetadata {
    items: Option<Vec<RawMetadataItem>>,
}

#[derive(Deserialize)]
struct RawInstance {
    name: String,
    status: String,
    zone: String,
    #[serde(rename = "machineType")]
    machine_type: Option<String>,
    disks: Option<Vec<RawDisk>>,
    labels: Option<HashMap<String, String>>,
    metadata: Option<RawMetadata>,
}

pub fn is_gcloud_installed() -> bool {
    Command::new("gcloud")
        .arg("--version")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

pub fn is_gcloud_authenticated() -> bool {
    let output = Command::new("gcloud")
        .args(["auth", "list", "--filter=status:ACTIVE", "--format=json"])
        .output();

    match output {
        Ok(o) => {
             if !o.status.success() { return false; }
             let stdout = String::from_utf8_lossy(&o.stdout);
             stdout.trim() != "[]"
        },
        Err(_) => false,
    }
}

/// Get the email of the currently active GCP account
///
/// Uses `gcloud config get-value account` to retrieve the email address
/// of the authenticated user. This is the email associated with the GCP account,
/// not the local Linux username.
///
/// # Returns
/// * Email address of the active GCP account (e.g., "user@domain.com")
/// * Error if gcloud is not authenticated or command fails
pub fn get_gcloud_account() -> Result<String> {
    let output = Command::new("gcloud")
        .args(["config", "get-value", "account"])
        .output()
        .map_err(|e| anyhow!("Failed to execute gcloud: {}", e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(anyhow!("gcloud error: {}", stderr));
    }

    let email = String::from_utf8_lossy(&output.stdout).trim().to_string();

    if email.is_empty() || email == "(unset)" {
        return Err(anyhow!("No active GCP account. Please run 'gcloud auth login' first."));
    }

    tracing::debug!("Retrieved GCP account email: {}", email);
    Ok(email)
}

/// Async version with timeout
pub async fn get_projects_async() -> Result<Vec<GcpProject>> {
    // 10 second timeout for listing projects
    let output = timeout(
        Duration::from_secs(10),
        TokioCommand::new("gcloud")
            .args(["projects", "list", "--format=json"])
            .output()
    )
    .await
    .map_err(|_| anyhow!("Timeout: gcloud projects list took longer than 10 seconds"))?
    .map_err(|e| anyhow!("Failed to execute gcloud: {}", e))?;

    if !output.status.success() {
        return Err(anyhow!("gcloud error: {}", String::from_utf8_lossy(&output.stderr)));
    }

    let projects: Vec<GcpProject> = serde_json::from_slice(&output.stdout)
        .map_err(|e| anyhow!("Failed to parse projects JSON: {}", e))?;
    Ok(projects)
}

/// Synchronous wrapper for FFI bridge
pub fn get_projects() -> Result<Vec<GcpProject>> {
    // Create a tokio runtime for this call
    let rt = tokio::runtime::Runtime::new()
        .map_err(|e| anyhow!("Failed to create tokio runtime: {}", e))?;
    rt.block_on(get_projects_async())
}

/// Extract CPU and memory specs from machine type name
/// Supports standard machine types by parsing their pattern (e.g., "e2-standard-4" → 4 CPUs)
/// Returns (cpu_count, memory_mb) if the machine type can be determined
fn get_machine_specs(machine_type: &str) -> Option<(u32, u32)> {
    // Special cases (micro, small, medium)
    match machine_type {
        "e2-micro" => return Some((2, 1024)),
        "e2-small" => return Some((2, 2048)),
        "e2-medium" => return Some((2, 4096)),
        "f1-micro" => return Some((1, 614)),
        "g1-small" => return Some((1, 1740)),
        _ => {}
    }

    // Parse standard machine types: {series}-{type}-{cpus}
    // Examples: e2-standard-4, n1-standard-8, n2-highmem-16, c2-standard-30
    let parts: Vec<&str> = machine_type.split('-').collect();

    if parts.len() >= 3 {
        let series = parts[0];      // e2, n1, n2, n2d, c2, c3, t2d, etc.
        let type_name = parts[1];   // standard, highmem, highcpu, custom

        // Try to parse CPU count from the last part
        if let Ok(cpu_count) = parts[2].parse::<u32>() {
            // Calculate memory based on type and series
            let memory_mb = match (series, type_name) {
                // E2 series (cost-optimized): 4GB per vCPU for standard
                ("e2", "standard") => cpu_count * 4096,
                ("e2", "highmem") => cpu_count * 8192,
                ("e2", "highcpu") => cpu_count * 1024,

                // N1 series: 3.75GB per vCPU for standard
                ("n1", "standard") => cpu_count * 3840,
                ("n1", "highmem") => cpu_count * 6656,
                ("n1", "highcpu") => cpu_count * 922,

                // N2/N2D series: 4GB per vCPU for standard
                ("n2" | "n2d", "standard") => cpu_count * 4096,
                ("n2" | "n2d", "highmem") => cpu_count * 8192,
                ("n2" | "n2d", "highcpu") => cpu_count * 1024,

                // C2 series (compute-optimized): 4GB per vCPU
                ("c2", "standard") => cpu_count * 4096,

                // C3 series (newer compute): 4GB per vCPU
                ("c3", "standard") => cpu_count * 4096,
                ("c3", "highmem") => cpu_count * 8192,
                ("c3", "highcpu") => cpu_count * 2048,

                // T2D series (AMD): 4GB per vCPU
                ("t2d", "standard") => cpu_count * 4096,

                // M1/M2/M3 series (memory-optimized): Much higher memory
                ("m1", "megamem") => cpu_count * 14336,  // 14GB per vCPU
                ("m1", "ultramem") => cpu_count * 24576, // 24GB per vCPU
                ("m2", "megamem") => cpu_count * 14336,
                ("m2", "ultramem") => cpu_count * 24576,
                ("m3", "megamem") => cpu_count * 14336,
                ("m3", "ultramem") => cpu_count * 24576,

                // A2 series (GPU): 12GB per vCPU
                ("a2", _) => cpu_count * 12288,

                // Default fallback: assume 4GB per vCPU (most common)
                _ => cpu_count * 4096,
            };

            return Some((cpu_count, memory_mb));
        }
    }

    // If we can't parse it, return None
    None
}

/// Async version with timeout
pub async fn get_instances_async(project_id: &str) -> Result<Vec<GcpInstance>> {
    // Validate project ID before passing to shell command
    validate_project_id(project_id)?;

    // 10 second timeout for listing instances
    let output = timeout(
        Duration::from_secs(10),
        TokioCommand::new("gcloud")
            .args(["compute", "instances", "list", "--project", project_id, "--format=json"])
            .output()
    )
    .await
    .map_err(|_| anyhow!("Timeout: gcloud instances list took longer than 10 seconds"))?
    .map_err(|e| anyhow!("Failed to execute gcloud: {}", e))?;

    if !output.status.success() {
        return Err(anyhow!("gcloud error: {}", String::from_utf8_lossy(&output.stderr)));
    }

    let raw_instances: Vec<RawInstance> = serde_json::from_slice(&output.stdout)
        .map_err(|e| anyhow!("Failed to parse instances JSON: {}", e))?;

    let instances = raw_instances.into_iter().map(|raw| {
        // Use sanitize_zone_from_url instead of fragile split
        let zone_name = sanitize_zone_from_url(&raw.zone)
            .unwrap_or_else(|_| {
                // Fallback: extract last path segment and validate it
                raw.zone.split('/').last()
                    .and_then(|z| validate_zone(z).ok().map(|_| z.to_string()))
                    .unwrap_or_else(|| "unknown".to_string())
            });

        let machine_type = raw.machine_type
            .as_deref()
            .map(|url| url.split('/').last().unwrap_or(url))
            .unwrap_or("Unknown")
            .to_string();

        // Extract CPU and memory from machine type
        let (cpu_count, memory_mb) = get_machine_specs(&machine_type)
            .map(|(cpu, mem)| (Some(cpu), Some(mem)))
            .unwrap_or((None, None));

        // Extract disk size from boot disk (first disk marked as boot=true)
        let disk_gb = raw.disks
            .as_ref()
            .and_then(|disks| {
                disks.iter()
                    .find(|d| d.boot.unwrap_or(false))
                    .or_else(|| disks.first())
            })
            .and_then(|disk| disk.disk_size_gb.as_ref())
            .and_then(|size_str| size_str.parse::<u32>().ok());

        // Extract labels
        let labels: Vec<(String, String)> = raw.labels
            .as_ref()
            .map(|l| l.iter().map(|(k, v)| (k.clone(), v.clone())).collect())
            .unwrap_or_default();

        // Detect OS Login from metadata
        let os_login_enabled = raw.metadata
            .as_ref()
            .and_then(|m| m.items.as_ref())
            .map(|items| {
                items.iter().any(|item| {
                    (item.key == "enable-oslogin" || item.key == "enable-os-login")
                        && item.value.as_deref().map(|v| v.eq_ignore_ascii_case("true")).unwrap_or(false)
                })
            })
            .unwrap_or(false);

        // Detect Windows from disk licenses
        let is_windows = raw.disks
            .as_ref()
            .map(|disks| {
                disks.iter().any(|disk| {
                    disk.licenses.as_ref().map(|licenses| {
                        licenses.iter().any(|l| l.to_lowercase().contains("windows"))
                    }).unwrap_or(false)
                })
            })
            .unwrap_or(false);

        GcpInstance {
            name: raw.name,
            status: raw.status,
            zone: zone_name,
            machine_type,
            cpu_count,
            memory_mb,
            disk_gb,
            labels,
            os_login_enabled,
            is_windows,
        }
    }).collect();

    Ok(instances)
}

/// Synchronous wrapper for FFI bridge
pub fn get_instances(project_id: &str) -> Result<Vec<GcpInstance>> {
    // Create a tokio runtime for this call
    let rt = tokio::runtime::Runtime::new()
        .map_err(|e| anyhow!("Failed to create tokio runtime: {}", e))?;
    rt.block_on(get_instances_async(project_id))
}

pub fn execute_login() -> Result<()> {
    // gcloud auth login launches the browser. We wait for it to complete.
    let status = Command::new("gcloud")
        .args(["auth", "login", "--quiet"]) 
        .status()
        .map_err(|e| anyhow!("Failed to execute gcloud login: {}", e))?;

    if status.success() {
        Ok(())
    } else {
        Err(anyhow!("Login failed or was cancelled."))
    }
}

pub fn launch_ssh(project_id: &str, zone: &str, instance_name: &str) -> anyhow::Result<()> {
    // SECURITY: Validate all inputs before passing to command
    validate_project_id(project_id)?;
    validate_zone(zone)?;
    validate_instance_name(instance_name)?;

    tracing::info!(
        project_id = project_id,
        zone = zone,
        instance_name = instance_name,
        "Launching SSH connection"
    );

    // Detect available terminal
    #[cfg(target_os = "windows")]
    let (terminal_bin, terminal_args) = ("cmd", vec!["/c", "start", "cmd", "/k", "gcloud", "compute", "ssh"]);

    #[cfg(not(target_os = "windows"))]
    let (terminal_bin, terminal_args) = if Command::new("gnome-terminal").arg("--version").output().is_ok() {
        ("gnome-terminal", vec!["--", "gcloud", "compute", "ssh"])
    } else if Command::new("konsole").arg("--version").output().is_ok() {
        ("konsole", vec!["-e", "gcloud", "compute", "ssh"])
    } else if Command::new("xterm").arg("-version").output().is_ok() {
        ("xterm", vec!["-e", "gcloud", "compute", "ssh"])
    } else {
        return Err(anyhow::anyhow!("No suitable terminal found (gnome-terminal, konsole, xterm). Please install one."));
    };

    // SECURITY: Pass arguments individually to avoid shell interpolation
    // This prevents command injection even if validation is bypassed
    let mut cmd = Command::new(terminal_bin);
    cmd.args(terminal_args)
        .arg("--project")
        .arg(project_id)
        .arg("--zone")
        .arg(zone)
        .arg(instance_name)
        .spawn()
        .map_err(|e| anyhow::anyhow!("Failed to launch terminal for SSH: {}", e))?;

    Ok(())
}

pub fn launch_sftp_browser(port: u16, username: Option<String>) -> anyhow::Result<()> {
    // Determine username: provided -> env USER -> "user" fallback
    let user = username.or_else(|| std::env::var("USER").ok()).unwrap_or_else(|| "user".to_string());

    // Construct URI: sftp://user@localhost:port
    let uri = format!("sftp://{}@localhost:{}", user, port);

    tracing::info!(uri = uri, "Launching SFTP file browser");

    // Use xdg-open to launch default file manager (or explorer on Windows)
    #[cfg(target_os = "windows")]
    let cmd_name = "explorer";
    #[cfg(not(target_os = "windows"))]
    let cmd_name = "xdg-open";

    Command::new(cmd_name)
        .arg(&uri)
        .spawn()
        .map_err(|e| anyhow::anyhow!("Failed to launch file manager: {}", e))?;

    Ok(())
}

pub fn execute_logout() -> Result<()> {
    tracing::info!("Revoking all gcloud credentials");

    // --quiet evita prompts, --all borra todas las cuentas activas
    let _ = Command::new("gcloud")
        .args(&["auth", "revoke", "--all", "--quiet"])
        .status(); // Ignoramos el resultado, si falla es probable que ya no haya credenciales.

    Ok(())
}

// VM Lifecycle Management Functions

/// Start a stopped instance
pub async fn start_instance_async(project_id: &str, zone: &str, instance_name: &str) -> Result<()> {
    // SECURITY: Validate all inputs
    validate_project_id(project_id)?;
    validate_zone(zone)?;
    validate_instance_name(instance_name)?;

    tracing::info!(
        project_id = project_id,
        zone = zone,
        instance_name = instance_name,
        "Starting instance"
    );

    let output = tokio::time::timeout(
        std::time::Duration::from_secs(120), // 2 minutes timeout for start
        tokio::process::Command::new("gcloud")
            .args(&[
                "compute",
                "instances",
                "start",
                instance_name,
                "--zone",
                zone,
                "--project",
                project_id,
                "--quiet",
            ])
            .output()
    )
    .await
    .map_err(|_| anyhow!("Timeout starting instance after 120 seconds"))?
    .map_err(|e| anyhow!("Failed to execute gcloud start command: {}", e))?;

    if output.status.success() {
        tracing::info!(
            instance_name = instance_name,
            "Instance started successfully"
        );
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        tracing::error!(
            instance_name = instance_name,
            stderr = %stderr,
            "Failed to start instance"
        );
        Err(anyhow!("Failed to start instance: {}", stderr))
    }
}

/// Synchronous wrapper for start_instance
pub fn start_instance(project_id: &str, zone: &str, instance_name: &str) -> Result<()> {
    let rt = tokio::runtime::Runtime::new()
        .map_err(|e| anyhow!("Failed to create tokio runtime: {}", e))?;
    rt.block_on(start_instance_async(project_id, zone, instance_name))
}

/// Stop a running instance
pub async fn stop_instance_async(project_id: &str, zone: &str, instance_name: &str) -> Result<()> {
    // SECURITY: Validate all inputs
    validate_project_id(project_id)?;
    validate_zone(zone)?;
    validate_instance_name(instance_name)?;

    tracing::info!(
        project_id = project_id,
        zone = zone,
        instance_name = instance_name,
        "Stopping instance"
    );

    let output = tokio::time::timeout(
        std::time::Duration::from_secs(120), // 2 minutes timeout for stop
        tokio::process::Command::new("gcloud")
            .args(&[
                "compute",
                "instances",
                "stop",
                instance_name,
                "--zone",
                zone,
                "--project",
                project_id,
                "--quiet",
            ])
            .output()
    )
    .await
    .map_err(|_| anyhow!("Timeout stopping instance after 120 seconds"))?
    .map_err(|e| anyhow!("Failed to execute gcloud stop command: {}", e))?;

    if output.status.success() {
        tracing::info!(
            instance_name = instance_name,
            "Instance stopped successfully"
        );
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        tracing::error!(
            instance_name = instance_name,
            stderr = %stderr,
            "Failed to stop instance"
        );
        Err(anyhow!("Failed to stop instance: {}", stderr))
    }
}

/// Synchronous wrapper for stop_instance
pub fn stop_instance(project_id: &str, zone: &str, instance_name: &str) -> Result<()> {
    let rt = tokio::runtime::Runtime::new()
        .map_err(|e| anyhow!("Failed to create tokio runtime: {}", e))?;
    rt.block_on(stop_instance_async(project_id, zone, instance_name))
}

/// Reset (restart) a running instance
pub async fn reset_instance_async(project_id: &str, zone: &str, instance_name: &str) -> Result<()> {
    // SECURITY: Validate all inputs
    validate_project_id(project_id)?;
    validate_zone(zone)?;
    validate_instance_name(instance_name)?;

    tracing::info!(
        project_id = project_id,
        zone = zone,
        instance_name = instance_name,
        "Resetting instance"
    );

    let output = tokio::time::timeout(
        std::time::Duration::from_secs(120), // 2 minutes timeout for reset
        tokio::process::Command::new("gcloud")
            .args(&[
                "compute",
                "instances",
                "reset",
                instance_name,
                "--zone",
                zone,
                "--project",
                project_id,
                "--quiet",
            ])
            .output()
    )
    .await
    .map_err(|_| anyhow!("Timeout resetting instance after 120 seconds"))?
    .map_err(|e| anyhow!("Failed to execute gcloud reset command: {}", e))?;

    if output.status.success() {
        tracing::info!(
            instance_name = instance_name,
            "Instance reset successfully"
        );
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        tracing::error!(
            instance_name = instance_name,
            stderr = %stderr,
            "Failed to reset instance"
        );
        Err(anyhow!("Failed to reset instance: {}", stderr))
    }
}

/// Synchronous wrapper for reset_instance
pub fn reset_instance(project_id: &str, zone: &str, instance_name: &str) -> Result<()> {
    let rt = tokio::runtime::Runtime::new()
        .map_err(|e| anyhow!("Failed to create tokio runtime: {}", e))?;
    rt.block_on(reset_instance_async(project_id, zone, instance_name))
}

/// Get a single instance using gcloud CLI (async)
/// Uses gcloud compute instances describe which may have different auth than REST API
pub async fn get_instance_async(project_id: &str, zone: &str, instance_name: &str) -> Result<GcpInstance> {
    // Validate inputs
    validate_project_id(project_id)?;
    validate_zone(zone)?;
    validate_instance_name(instance_name)?;

    tracing::info!(
        project_id = project_id,
        zone = zone,
        instance_name = instance_name,
        "Getting instance via gcloud CLI"
    );

    let output = timeout(
        Duration::from_secs(30),
        TokioCommand::new("gcloud")
            .args([
                "compute", "instances", "describe",
                instance_name,
                "--project", project_id,
                "--zone", zone,
                "--format", "json",
            ])
            .output()
    )
    .await
    .map_err(|_| anyhow!("gcloud command timed out"))?
    .map_err(|e| anyhow!("Failed to execute gcloud: {}", e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        if stderr.contains("403") || stderr.contains("PERMISSION_DENIED") || stderr.contains("does not have permission") {
            return Err(anyhow!(
                "PERMISSION_DENIED: You don't have permission to view instance '{}' in project '{}'. \
                Required permission: 'compute.instances.get'.",
                instance_name, project_id
            ));
        }
        if stderr.contains("404") || stderr.contains("was not found") {
            return Err(anyhow!(
                "NOT_FOUND: Instance '{}' not found in zone '{}' of project '{}'.",
                instance_name, zone, project_id
            ));
        }
        return Err(anyhow!("gcloud error: {}", stderr));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let raw: RawInstance = serde_json::from_str(&stdout)
        .map_err(|e| anyhow!("Failed to parse instance JSON: {}", e))?;

    // Extract machine type from URL
    let machine_type = raw.machine_type
        .as_ref()
        .and_then(|mt| mt.split('/').last())
        .unwrap_or("unknown")
        .to_string();

    // Extract disk size from boot disk
    let disk_gb = raw.disks
        .as_ref()
        .and_then(|disks| {
            disks.iter()
                .find(|d| d.boot.unwrap_or(false))
                .or_else(|| disks.first())
        })
        .and_then(|disk| disk.disk_size_gb.as_ref())
        .and_then(|size| size.parse::<u32>().ok());

    // Extract CPU and memory from machine type
    let (cpu_count, memory_mb) = parse_machine_type_specs(&machine_type);

    tracing::info!(
        instance_name = instance_name,
        status = %raw.status,
        "Instance retrieved successfully"
    );

    // Extract labels
    let labels: Vec<(String, String)> = raw.labels
        .as_ref()
        .map(|l| l.iter().map(|(k, v)| (k.clone(), v.clone())).collect())
        .unwrap_or_default();

    // Detect OS Login from metadata
    let os_login_enabled = raw.metadata
        .as_ref()
        .and_then(|m| m.items.as_ref())
        .map(|items| {
            items.iter().any(|item| {
                (item.key == "enable-oslogin" || item.key == "enable-os-login")
                    && item.value.as_deref().map(|v| v.eq_ignore_ascii_case("true")).unwrap_or(false)
            })
        })
        .unwrap_or(false);

    // Detect Windows from disk licenses
    let is_windows = raw.disks
        .as_ref()
        .map(|disks| {
            disks.iter().any(|disk| {
                disk.licenses.as_ref().map(|licenses| {
                    licenses.iter().any(|l| l.to_lowercase().contains("windows"))
                }).unwrap_or(false)
            })
        })
        .unwrap_or(false);

    Ok(GcpInstance {
        name: raw.name,
        status: raw.status,
        zone: sanitize_zone_from_url(&raw.zone)?,
        machine_type,
        cpu_count,
        memory_mb,
        disk_gb,
        labels,
        os_login_enabled,
        is_windows,
    })
}

/// Synchronous wrapper for get_instance
pub fn get_instance(project_id: &str, zone: &str, instance_name: &str) -> Result<GcpInstance> {
    let rt = tokio::runtime::Runtime::new()
        .map_err(|e| anyhow!("Failed to create tokio runtime: {}", e))?;
    rt.block_on(get_instance_async(project_id, zone, instance_name))
}

/// Parse machine type string to extract CPU and memory specs
fn parse_machine_type_specs(machine_type: &str) -> (Option<u32>, Option<u32>) {
    // Handle standard machine types like "e2-standard-4", "n1-highmem-8", etc.
    let parts: Vec<&str> = machine_type.split('-').collect();

    if parts.len() >= 3 {
        // Last part is usually the vCPU count
        if let Ok(cpus) = parts.last().unwrap_or(&"").parse::<u32>() {
            // Estimate memory based on machine type
            let mem_per_cpu = if machine_type.contains("highmem") {
                6656  // ~6.5 GB per vCPU
            } else if machine_type.contains("highcpu") {
                896   // ~0.9 GB per vCPU
            } else {
                3840  // ~3.75 GB per vCPU (standard)
            };
            return (Some(cpus), Some(cpus * mem_per_cpu));
        }
    }

    (None, None)
}

// ==========================================
// Multi-Account Management (Sprint 8)
// ==========================================

/// List all authenticated gcloud accounts
pub async fn list_gcloud_accounts_async() -> Result<Vec<GcloudAccount>> {
    let output = timeout(
        Duration::from_secs(10),
        TokioCommand::new("gcloud")
            .args(["auth", "list", "--format=json"])
            .output()
    )
    .await
    .map_err(|_| anyhow!("Timeout: gcloud auth list took longer than 10 seconds"))?
    .map_err(|e| anyhow!("Failed to execute gcloud: {}", e))?;

    if !output.status.success() {
        return Err(anyhow!("gcloud error: {}", String::from_utf8_lossy(&output.stderr)));
    }

    #[derive(Deserialize)]
    struct RawAccount {
        account: String,
        status: Option<String>,
    }

    let raw_accounts: Vec<RawAccount> = serde_json::from_slice(&output.stdout)
        .map_err(|e| anyhow!("Failed to parse accounts JSON: {}", e))?;

    let accounts = raw_accounts.into_iter().map(|raw| {
        GcloudAccount {
            account: raw.account,
            status: raw.status.unwrap_or_default(),
        }
    }).collect();

    Ok(accounts)
}

/// Switch the active gcloud account
pub async fn switch_gcloud_account_async(email: &str) -> Result<()> {
    validate_email(email)?;

    tracing::info!(email = email, "Switching gcloud account");

    let output = timeout(
        Duration::from_secs(10),
        TokioCommand::new("gcloud")
            .args(["config", "set", "account", email])
            .output()
    )
    .await
    .map_err(|_| anyhow!("Timeout: gcloud config set account took longer than 10 seconds"))?
    .map_err(|e| anyhow!("Failed to execute gcloud: {}", e))?;

    if !output.status.success() {
        return Err(anyhow!("Failed to switch account: {}", String::from_utf8_lossy(&output.stderr)));
    }

    // El token cacheado pertenece a la cuenta anterior
    crate::gcp_rest_client::invalidate_cached_access_token().await;

    tracing::info!(email = email, "Account switched successfully");
    Ok(())
}

/// Add a new gcloud account (opens browser for authentication)
/// This is synchronous because it waits for the browser auth flow
pub fn add_gcloud_account() -> Result<()> {
    tracing::info!("Adding new gcloud account (opening browser)");

    let status = Command::new("gcloud")
        .args(["auth", "login", "--quiet"])
        .status()
        .map_err(|e| anyhow!("Failed to execute gcloud auth login: {}", e))?;

    if status.success() {
        tracing::info!("New account added successfully");
        Ok(())
    } else {
        Err(anyhow!("Login failed or was cancelled."))
    }
}

/// Remove (revoke) a gcloud account
pub async fn remove_gcloud_account_async(email: &str) -> Result<()> {
    validate_email(email)?;

    tracing::info!(email = email, "Revoking gcloud account");

    let output = timeout(
        Duration::from_secs(10),
        TokioCommand::new("gcloud")
            .args(["auth", "revoke", email, "--quiet"])
            .output()
    )
    .await
    .map_err(|_| anyhow!("Timeout: gcloud auth revoke took longer than 10 seconds"))?
    .map_err(|e| anyhow!("Failed to execute gcloud: {}", e))?;

    if !output.status.success() {
        return Err(anyhow!("Failed to revoke account: {}", String::from_utf8_lossy(&output.stderr)));
    }

    tracing::info!(email = email, "Account revoked successfully");
    Ok(())
}

/// Check if a machine type supports suspend operation
/// Shared-core machine types do not support suspend
pub fn machine_type_supports_suspend(machine_type: &str) -> bool {
    !matches!(
        machine_type,
        "f1-micro" | "g1-small" | "e2-micro" | "e2-small" | "e2-medium"
    )
}

/// Convert a GCP email to an OS Login username
/// e.g., "user@domain.com" -> "user_domain_com"
pub fn email_to_oslogin_username(email: &str) -> String {
    email.replace('@', "_").replace('.', "_")
}

/// Suspend a running instance (async)
pub async fn suspend_instance_async(project_id: &str, zone: &str, instance_name: &str) -> Result<()> {
    validate_project_id(project_id)?;
    validate_zone(zone)?;
    validate_instance_name(instance_name)?;

    tracing::info!(
        project_id = project_id,
        zone = zone,
        instance_name = instance_name,
        "Suspending instance"
    );

    let output = tokio::time::timeout(
        std::time::Duration::from_secs(120),
        tokio::process::Command::new("gcloud")
            .args(&[
                "compute", "instances", "suspend",
                instance_name, "--zone", zone,
                "--project", project_id, "--quiet",
            ])
            .output()
    )
    .await
    .map_err(|_| anyhow!("Timeout suspending instance after 120 seconds"))?
    .map_err(|e| anyhow!("Failed to execute gcloud suspend command: {}", e))?;

    if output.status.success() {
        tracing::info!(instance_name = instance_name, "Instance suspended successfully");
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        tracing::error!(instance_name = instance_name, stderr = %stderr, "Failed to suspend instance");
        Err(anyhow!("Failed to suspend instance: {}", stderr))
    }
}

/// Synchronous wrapper for suspend_instance
pub fn suspend_instance(project_id: &str, zone: &str, instance_name: &str) -> Result<()> {
    let rt = tokio::runtime::Runtime::new()
        .map_err(|e| anyhow!("Failed to create tokio runtime: {}", e))?;
    rt.block_on(suspend_instance_async(project_id, zone, instance_name))
}

/// Resume a suspended instance (async)
pub async fn resume_instance_async(project_id: &str, zone: &str, instance_name: &str) -> Result<()> {
    validate_project_id(project_id)?;
    validate_zone(zone)?;
    validate_instance_name(instance_name)?;

    tracing::info!(
        project_id = project_id,
        zone = zone,
        instance_name = instance_name,
        "Resuming instance"
    );

    let output = tokio::time::timeout(
        std::time::Duration::from_secs(120),
        tokio::process::Command::new("gcloud")
            .args(&[
                "compute", "instances", "resume",
                instance_name, "--zone", zone,
                "--project", project_id, "--quiet",
            ])
            .output()
    )
    .await
    .map_err(|_| anyhow!("Timeout resuming instance after 120 seconds"))?
    .map_err(|e| anyhow!("Failed to execute gcloud resume command: {}", e))?;

    if output.status.success() {
        tracing::info!(instance_name = instance_name, "Instance resumed successfully");
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        tracing::error!(instance_name = instance_name, stderr = %stderr, "Failed to resume instance");
        Err(anyhow!("Failed to resume instance: {}", stderr))
    }
}

/// Synchronous wrapper for resume_instance
pub fn resume_instance(project_id: &str, zone: &str, instance_name: &str) -> Result<()> {
    let rt = tokio::runtime::Runtime::new()
        .map_err(|e| anyhow!("Failed to create tokio runtime: {}", e))?;
    rt.block_on(resume_instance_async(project_id, zone, instance_name))
}

/// Get projects for a specific account (without changing global config)
pub async fn get_projects_for_account_async(email: &str) -> Result<Vec<GcpProject>> {
    validate_email(email)?;

    let output = timeout(
        Duration::from_secs(15),
        TokioCommand::new("gcloud")
            .args(["projects", "list", "--account", email, "--format=json"])
            .output()
    )
    .await
    .map_err(|_| anyhow!("Timeout: gcloud projects list took longer than 15 seconds"))?
    .map_err(|e| anyhow!("Failed to execute gcloud: {}", e))?;

    if !output.status.success() {
        return Err(anyhow!("gcloud error: {}", String::from_utf8_lossy(&output.stderr)));
    }

    let projects: Vec<GcpProject> = serde_json::from_slice(&output.stdout)
        .map_err(|e| anyhow!("Failed to parse projects JSON: {}", e))?;
    Ok(projects)
}

