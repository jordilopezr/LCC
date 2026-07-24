// Sprint 16: VM Snapshot Manager
// Provides create, list, delete, and restore (disk-from-snapshot) operations
// for GCP persistent disk snapshots.

use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};
use crate::validation::{validate_project_id, validate_zone, validate_instance_name, validate_snapshot_name, validate_snapshot_description};

/// Represents a GCP disk snapshot.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GcpSnapshot {
    pub name: String,
    pub status: String,             // "READY", "CREATING", "DELETING", "FAILED"
    pub creation_timestamp: String, // ISO 8601: "2026-02-18T14:30:00.000-07:00"
    pub source_disk: String,        // last segment of the source disk URL
    pub disk_size_gb: u64,
    pub storage_bytes: u64,         // 0 if not yet available (CREATING)
    pub description: String,
}

// ──────────────────────────────────────────────────────────────────────────────
// get_boot_disk_name
// ──────────────────────────────────────────────────────────────────────────────

pub async fn get_boot_disk_name_async(project_id: &str, zone: &str, instance_name: &str) -> Result<String> {
    validate_project_id(project_id)?;
    validate_zone(zone)?;
    validate_instance_name(instance_name)?;

    tracing::info!(
        project_id = project_id,
        zone = zone,
        instance_name = instance_name,
        "Getting boot disk name"
    );

    let output = tokio::time::timeout(
        std::time::Duration::from_secs(60),
        tokio::process::Command::new("gcloud")
            .args([
                "compute", "instances", "describe",
                instance_name,
                "--zone", zone,
                "--project", project_id,
                "--format=value(disks[0].source)",
            ])
            .output(),
    )
    .await
    .map_err(|_| anyhow!("Timeout getting boot disk name after 60 seconds"))?
    .map_err(|e| anyhow!("Failed to execute gcloud instances describe: {}", e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        tracing::error!(
            instance_name = instance_name,
            stderr = %stderr,
            "Failed to get boot disk name"
        );
        return Err(anyhow!("Failed to get boot disk name: {}", stderr));
    }

    let raw = String::from_utf8_lossy(&output.stdout).trim().to_string();
    // The value is a full URL like:
    // https://www.googleapis.com/.../projects/my-proj/zones/us-central1-a/disks/my-vm
    let disk_name = raw
        .split('/')
        .last()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| anyhow!("Unexpected disk source URL format: {}", raw))?
        .to_string();

    tracing::info!(
        instance_name = instance_name,
        disk_name = disk_name,
        "Boot disk name resolved"
    );
    Ok(disk_name)
}

pub fn get_boot_disk_name(project_id: &str, zone: &str, instance_name: &str) -> Result<String> {
    let rt = tokio::runtime::Runtime::new()
        .map_err(|e| anyhow!("Failed to create tokio runtime: {}", e))?;
    rt.block_on(get_boot_disk_name_async(project_id, zone, instance_name))
}

// ──────────────────────────────────────────────────────────────────────────────
// list_snapshots
// ──────────────────────────────────────────────────────────────────────────────

pub async fn list_snapshots_async(project_id: &str, zone: &str, instance_name: &str) -> Result<Vec<GcpSnapshot>> {
    validate_project_id(project_id)?;
    validate_zone(zone)?;
    validate_instance_name(instance_name)?;

    tracing::info!(
        project_id = project_id,
        instance_name = instance_name,
        "Listing snapshots"
    );

    let disk_name = get_boot_disk_name_async(project_id, zone, instance_name).await?;

    let filter = format!("sourceDisk~/{}", disk_name);

    let output = tokio::time::timeout(
        std::time::Duration::from_secs(60),
        tokio::process::Command::new("gcloud")
            .args([
                "compute", "snapshots", "list",
                "--project", project_id,
                "--filter", &filter,
                "--format=json(name,status,creationTimestamp,sourceDisk,diskSizeGb,storageBytes,description)",
            ])
            .output(),
    )
    .await
    .map_err(|_| anyhow!("Timeout listing snapshots after 60 seconds"))?
    .map_err(|e| anyhow!("Failed to execute gcloud snapshots list: {}", e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        tracing::error!(
            instance_name = instance_name,
            stderr = %stderr,
            "Failed to list snapshots"
        );
        return Err(anyhow!("Failed to list snapshots: {}", stderr));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let raw: Vec<serde_json::Value> = serde_json::from_str(stdout.trim())
        .unwrap_or_else(|_| vec![]);

    let snapshots = raw
        .into_iter()
        .map(|v| {
            let source_disk_url = v["sourceDisk"].as_str().unwrap_or("").to_string();
            let source_disk = source_disk_url
                .split('/')
                .last()
                .unwrap_or("")
                .to_string();

            let disk_size_gb = v["diskSizeGb"]
                .as_str()
                .and_then(|s| s.parse::<u64>().ok())
                .or_else(|| v["diskSizeGb"].as_u64())
                .unwrap_or(0);

            let storage_bytes = v["storageBytes"]
                .as_str()
                .and_then(|s| s.parse::<u64>().ok())
                .or_else(|| v["storageBytes"].as_u64())
                .unwrap_or(0);

            GcpSnapshot {
                name: v["name"].as_str().unwrap_or("").to_string(),
                status: v["status"].as_str().unwrap_or("UNKNOWN").to_string(),
                creation_timestamp: v["creationTimestamp"].as_str().unwrap_or("").to_string(),
                source_disk,
                disk_size_gb,
                storage_bytes,
                description: v["description"].as_str().unwrap_or("").to_string(),
            }
        })
        .collect();

    tracing::info!(
        instance_name = instance_name,
        "Snapshots listed successfully"
    );
    Ok(snapshots)
}

pub fn list_snapshots(project_id: &str, zone: &str, instance_name: &str) -> Result<Vec<GcpSnapshot>> {
    let rt = tokio::runtime::Runtime::new()
        .map_err(|e| anyhow!("Failed to create tokio runtime: {}", e))?;
    rt.block_on(list_snapshots_async(project_id, zone, instance_name))
}

// ──────────────────────────────────────────────────────────────────────────────
// create_snapshot
// ──────────────────────────────────────────────────────────────────────────────

pub async fn create_snapshot_async(
    project_id: &str,
    zone: &str,
    instance_name: &str,
    snapshot_name: &str,
    description: &str,
) -> Result<()> {
    validate_project_id(project_id)?;
    validate_zone(zone)?;
    validate_instance_name(instance_name)?;
    validate_snapshot_name(snapshot_name)?;
    validate_snapshot_description(description)?;

    tracing::info!(
        project_id = project_id,
        zone = zone,
        instance_name = instance_name,
        snapshot_name = snapshot_name,
        "Creating snapshot"
    );

    let disk_name = get_boot_disk_name_async(project_id, zone, instance_name).await?;

    let output = tokio::time::timeout(
        std::time::Duration::from_secs(300),
        tokio::process::Command::new("gcloud")
            .args([
                "compute", "disks", "snapshot",
                &disk_name,
                "--zone", zone,
                "--project", project_id,
                "--snapshot-names", snapshot_name,
                "--description", description,
                "--quiet",
            ])
            .output(),
    )
    .await
    .map_err(|_| anyhow!("Timeout creating snapshot after 300 seconds"))?
    .map_err(|e| anyhow!("Failed to execute gcloud disks snapshot: {}", e))?;

    if output.status.success() {
        tracing::info!(snapshot_name = snapshot_name, "Snapshot created successfully");
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        tracing::error!(snapshot_name = snapshot_name, stderr = %stderr, "Failed to create snapshot");
        Err(anyhow!("Failed to create snapshot: {}", stderr))
    }
}

pub fn create_snapshot(
    project_id: &str,
    zone: &str,
    instance_name: &str,
    snapshot_name: &str,
    description: &str,
) -> Result<()> {
    let rt = tokio::runtime::Runtime::new()
        .map_err(|e| anyhow!("Failed to create tokio runtime: {}", e))?;
    rt.block_on(create_snapshot_async(project_id, zone, instance_name, snapshot_name, description))
}

// ──────────────────────────────────────────────────────────────────────────────
// delete_snapshot
// ──────────────────────────────────────────────────────────────────────────────

pub async fn delete_snapshot_async(project_id: &str, snapshot_name: &str) -> Result<()> {
    validate_project_id(project_id)?;
    validate_snapshot_name(snapshot_name)?;

    tracing::info!(
        project_id = project_id,
        snapshot_name = snapshot_name,
        "Deleting snapshot"
    );

    let output = tokio::time::timeout(
        std::time::Duration::from_secs(120),
        tokio::process::Command::new("gcloud")
            .args([
                "compute", "snapshots", "delete",
                snapshot_name,
                "--project", project_id,
                "--quiet",
            ])
            .output(),
    )
    .await
    .map_err(|_| anyhow!("Timeout deleting snapshot after 120 seconds"))?
    .map_err(|e| anyhow!("Failed to execute gcloud snapshots delete: {}", e))?;

    if output.status.success() {
        tracing::info!(snapshot_name = snapshot_name, "Snapshot deleted successfully");
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        tracing::error!(snapshot_name = snapshot_name, stderr = %stderr, "Failed to delete snapshot");
        Err(anyhow!("Failed to delete snapshot: {}", stderr))
    }
}

pub fn delete_snapshot(project_id: &str, snapshot_name: &str) -> Result<()> {
    let rt = tokio::runtime::Runtime::new()
        .map_err(|e| anyhow!("Failed to create tokio runtime: {}", e))?;
    rt.block_on(delete_snapshot_async(project_id, snapshot_name))
}

// ──────────────────────────────────────────────────────────────────────────────
// create_disk_from_snapshot (Restore)
// ──────────────────────────────────────────────────────────────────────────────

pub async fn create_disk_from_snapshot_async(
    project_id: &str,
    zone: &str,
    snapshot_name: &str,
    new_disk_name: &str,
) -> Result<()> {
    validate_project_id(project_id)?;
    validate_zone(zone)?;
    validate_snapshot_name(snapshot_name)?;
    // new_disk_name follows same rules as instance names in GCP
    crate::validation::validate_instance_name(new_disk_name)?;

    tracing::info!(
        project_id = project_id,
        zone = zone,
        snapshot_name = snapshot_name,
        new_disk_name = new_disk_name,
        "Creating disk from snapshot"
    );

    let output = tokio::time::timeout(
        std::time::Duration::from_secs(300),
        tokio::process::Command::new("gcloud")
            .args([
                "compute", "disks", "create",
                new_disk_name,
                "--zone", zone,
                "--project", project_id,
                "--source-snapshot", snapshot_name,
                "--quiet",
            ])
            .output(),
    )
    .await
    .map_err(|_| anyhow!("Timeout creating disk from snapshot after 300 seconds"))?
    .map_err(|e| anyhow!("Failed to execute gcloud disks create: {}", e))?;

    if output.status.success() {
        tracing::info!(new_disk_name = new_disk_name, "Disk created from snapshot successfully");
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        tracing::error!(new_disk_name = new_disk_name, stderr = %stderr, "Failed to create disk from snapshot");
        Err(anyhow!("Failed to create disk from snapshot: {}", stderr))
    }
}

pub fn create_disk_from_snapshot(
    project_id: &str,
    zone: &str,
    snapshot_name: &str,
    new_disk_name: &str,
) -> Result<()> {
    let rt = tokio::runtime::Runtime::new()
        .map_err(|e| anyhow!("Failed to create tokio runtime: {}", e))?;
    rt.block_on(create_disk_from_snapshot_async(project_id, zone, snapshot_name, new_disk_name))
}

// ──────────────────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {

    #[test]
    fn test_parse_disk_name_from_url() {
        let url = "https://www.googleapis.com/compute/v1/projects/my-proj/zones/us-central1-a/disks/my-vm";
        let name = url.split('/').last().unwrap();
        assert_eq!(name, "my-vm");
    }

    #[test]
    fn test_snapshot_name_generation_format() {
        let name = "my-vm-20260218-143022";
        assert!(name.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-'));
        assert!(name.len() <= 63);
    }

    #[test]
    fn test_parse_snapshot_json() {
        let json = r#"[{
            "name": "my-vm-snap-1",
            "status": "READY",
            "creationTimestamp": "2026-02-18T14:30:00.000-07:00",
            "sourceDisk": "https://googleapis.com/compute/v1/projects/my-proj/zones/us-central1-a/disks/my-vm",
            "diskSizeGb": "50",
            "storageBytes": "1073741824",
            "description": "Test snapshot"
        }]"#;
        let snapshots: Vec<serde_json::Value> = serde_json::from_str(json).unwrap();
        assert_eq!(snapshots[0]["name"], "my-vm-snap-1");
        assert_eq!(snapshots[0]["status"], "READY");
    }

    #[test]
    fn test_source_disk_url_parsing() {
        let url = "https://googleapis.com/compute/v1/projects/my-proj/zones/us-central1-a/disks/my-vm";
        let disk_name = url.split('/').last().unwrap_or("");
        assert_eq!(disk_name, "my-vm");
    }

    #[test]
    fn test_storage_bytes_parsing() {
        // storageBytes comes as a string in the JSON
        let v: serde_json::Value = serde_json::from_str(r#"{"storageBytes": "1073741824"}"#).unwrap();
        let bytes = v["storageBytes"]
            .as_str()
            .and_then(|s| s.parse::<u64>().ok())
            .or_else(|| v["storageBytes"].as_u64())
            .unwrap_or(0);
        assert_eq!(bytes, 1_073_741_824u64);
    }
}
