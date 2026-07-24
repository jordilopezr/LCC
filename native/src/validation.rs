use anyhow::{Result, anyhow};
use regex::Regex;
use lazy_static::lazy_static;

lazy_static! {
    // GCP Project ID: 6-30 chars, lowercase letters, digits, hyphens
    // Must start with letter, end with letter or digit
    static ref PROJECT_ID_REGEX: Regex = Regex::new(
        r"^[a-z]([a-z0-9-]{4,28}[a-z0-9])?$"
    ).unwrap();

    // GCP Zone: e.g., us-central1-a, europe-west1-b, asia-east1-c
    // Format: {region}-{location}{sublocation}-{zone_letter}
    static ref ZONE_REGEX: Regex = Regex::new(
        r"^[a-z]+-[a-z]+[0-9]+-[a-z]$"
    ).unwrap();

    // GCP Instance Name: 1-63 chars, lowercase letters, digits, hyphens
    // Must start with letter
    static ref INSTANCE_NAME_REGEX: Regex = Regex::new(
        r"^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$"
    ).unwrap();

    // Linux Username: Standard POSIX username format
    // Must start with lowercase letter or underscore
    // Can contain lowercase letters, digits, underscores, hyphens
    // 1-32 characters long
    static ref USERNAME_REGEX: Regex = Regex::new(
        r"^[a-z_][a-z0-9_-]{0,31}$"
    ).unwrap();

    // Email address: basic validation for gcloud account emails
    // Supports standard email format: local@domain.tld
    static ref EMAIL_REGEX: Regex = Regex::new(
        r"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$"
    ).unwrap();
}

/// Validates a GCP project ID
///
/// # Rules
/// - 6-30 characters long
/// - Must start with a lowercase letter
/// - Can contain lowercase letters, digits, and hyphens
/// - Must end with a letter or digit
///
/// # Examples
/// ```
/// # use native::validation::*;
/// assert!(validate_project_id("my-project-123").is_ok());
/// assert!(validate_project_id("MyProject").is_err()); // uppercase not allowed
/// assert!(validate_project_id("123-project").is_err()); // must start with letter
/// ```
pub fn validate_project_id(project_id: &str) -> Result<()> {
    if project_id.is_empty() {
        return Err(anyhow!("Project ID cannot be empty"));
    }

    if !PROJECT_ID_REGEX.is_match(project_id) {
        return Err(anyhow!(
            "Invalid project ID '{}'. Must be 6-30 chars, lowercase letters/digits/hyphens, \
             start with letter, end with letter or digit",
            project_id
        ));
    }

    Ok(())
}

/// Validates a GCP zone name
///
/// # Rules
/// - Format: {region}-{location}{number}-{zone_letter}
/// - Example: us-central1-a, europe-west2-b
///
/// # Examples
/// ```
/// # use native::validation::*;
/// assert!(validate_zone("us-central1-a").is_ok());
/// assert!(validate_zone("europe-west1-b").is_ok());
/// assert!(validate_zone("invalid-zone").is_err());
/// ```
pub fn validate_zone(zone: &str) -> Result<()> {
    if zone.is_empty() {
        return Err(anyhow!("Zone cannot be empty"));
    }

    if !ZONE_REGEX.is_match(zone) {
        return Err(anyhow!(
            "Invalid zone '{}'. Expected format: region-location#-letter (e.g., us-central1-a)",
            zone
        ));
    }

    Ok(())
}

/// Validates a GCP instance name
///
/// # Rules
/// - 1-63 characters long
/// - Must start with a lowercase letter
/// - Can contain lowercase letters, digits, and hyphens
/// - Must end with a letter or digit (if length > 1)
///
/// # Examples
/// ```
/// # use native::validation::*;
/// assert!(validate_instance_name("my-vm-01").is_ok());
/// assert!(validate_instance_name("a").is_ok()); // single letter valid
/// assert!(validate_instance_name("VM-01").is_err()); // uppercase not allowed
/// assert!(validate_instance_name("vm-").is_err()); // can't end with hyphen
/// ```
pub fn validate_instance_name(instance_name: &str) -> Result<()> {
    if instance_name.is_empty() {
        return Err(anyhow!("Instance name cannot be empty"));
    }

    if instance_name.len() > 63 {
        return Err(anyhow!(
            "Instance name '{}' too long ({} chars). Maximum is 63 characters",
            instance_name,
            instance_name.len()
        ));
    }

    if !INSTANCE_NAME_REGEX.is_match(instance_name) {
        return Err(anyhow!(
            "Invalid instance name '{}'. Must start with lowercase letter, \
             contain only lowercase letters/digits/hyphens, and end with letter or digit",
            instance_name
        ));
    }

    Ok(())
}

/// Validates a Linux username for SFTP operations
///
/// # Rules
/// - 1-32 characters long
/// - Must start with a lowercase letter or underscore
/// - Can contain lowercase letters, digits, underscores, and hyphens
/// - Follows POSIX username standards
///
/// # Examples
/// ```
/// # use native::validation::*;
/// assert!(validate_username("jlopezre").is_ok());
/// assert!(validate_username("_service").is_ok());
/// assert!(validate_username("user-name_01").is_ok());
/// assert!(validate_username("../root").is_err()); // path traversal attempt
/// assert!(validate_username("User").is_err()); // uppercase not allowed
/// ```
pub fn validate_username(username: &str) -> Result<()> {
    if username.is_empty() {
        return Err(anyhow!("Username cannot be empty"));
    }

    if username.len() > 32 {
        return Err(anyhow!(
            "Username '{}' too long ({} chars). Maximum is 32 characters",
            username,
            username.len()
        ));
    }

    if !USERNAME_REGEX.is_match(username) {
        return Err(anyhow!(
            "Invalid username '{}'. Must start with lowercase letter or underscore, \
             contain only lowercase letters/digits/underscores/hyphens, max 32 chars",
            username
        ));
    }

    Ok(())
}

/// Sanitizes a zone string from GCP API response
///
/// GCP API returns zones as full URLs like:
/// "https://www.googleapis.com/compute/v1/projects/myproject/zones/us-central1-a"
///
/// This function extracts just the zone name and validates it.
pub fn sanitize_zone_from_url(zone_url: &str) -> Result<String> {
    let zone_name = zone_url
        .split('/')
        .last()
        .ok_or_else(|| anyhow!("Invalid zone URL format: {}", zone_url))?;

    // Validate the extracted zone name
    validate_zone(zone_name)?;

    Ok(zone_name.to_string())
}

/// Validates an email address format (for gcloud account management)
///
/// # Rules
/// - Must contain exactly one @ symbol
/// - Local part: letters, digits, dots, underscores, percent, plus, hyphens
/// - Domain: letters, digits, dots, hyphens
/// - TLD: at least 2 characters
/// - Maximum 254 characters (RFC 5321)
///
/// # Examples
/// ```
/// # use native::validation::*;
/// assert!(validate_email("user@example.com").is_ok());
/// assert!(validate_email("user.name+tag@domain.co.uk").is_ok());
/// assert!(validate_email("invalid").is_err());
/// ```
pub fn validate_email(email: &str) -> Result<()> {
    if email.is_empty() {
        return Err(anyhow!("Email cannot be empty"));
    }

    if email.len() > 254 {
        return Err(anyhow!(
            "Email '{}' too long ({} chars). Maximum is 254 characters",
            email,
            email.len()
        ));
    }

    if !EMAIL_REGEX.is_match(email) {
        return Err(anyhow!(
            "Invalid email '{}'. Expected format: user@domain.com",
            email
        ));
    }

    Ok(())
}

/// Validates GCP snapshot names.
///
/// # Rules
/// - 1–63 characters long
/// - Must start with a lowercase letter
/// - Can contain lowercase letters, digits, and hyphens
/// - Must not end with a hyphen
///
/// # Examples
/// ```
/// # use native::validation::*;
/// assert!(validate_snapshot_name("my-vm-20260218-143022").is_ok());
/// assert!(validate_snapshot_name("snap1").is_ok());
/// assert!(validate_snapshot_name("Snap").is_err());  // uppercase
/// assert!(validate_snapshot_name("snap-").is_err()); // ends with hyphen
/// ```
pub fn validate_snapshot_name(name: &str) -> Result<()> {
    if name.is_empty() || name.len() > 63 {
        return Err(anyhow!("Snapshot name must be 1-63 characters"));
    }
    if !name.chars().next().map(|c| c.is_ascii_lowercase()).unwrap_or(false) {
        return Err(anyhow!("Snapshot name must start with a lowercase letter"));
    }
    if !name.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-') {
        return Err(anyhow!("Snapshot name may only contain lowercase letters, digits, and hyphens"));
    }
    if name.ends_with('-') {
        return Err(anyhow!("Snapshot name must not end with a hyphen"));
    }
    Ok(())
}

pub fn validate_snapshot_description(description: &str) -> Result<()> {
    if description.len() > 2048 {
        return Err(anyhow!("Snapshot description too long (max 2048 characters)"));
    }
    if description.contains('\0') || description.contains('\x01') {
        return Err(anyhow!("Snapshot description contains invalid characters"));
    }
    Ok(())
}

/// Validate that a URL targets a GCP API domain over HTTPS.
///
/// Accepted: `https://*.googleapis.com/...`
/// Rejected: non-HTTPS schemes, non-googleapis.com hosts.
///
/// This is a defense-in-depth measure against misconfiguration or supply-chain
/// tampering that could redirect GCP API calls to an attacker-controlled server.
pub fn validate_gcp_url(url: &str) -> Result<()> {
    if !url.starts_with("https://") {
        return Err(anyhow!("GCP request URL must use HTTPS"));
    }
    // Extract host: everything after "https://" up to the first '/' or end
    let host = url["https://".len()..]
        .split('/')
        .next()
        .unwrap_or("");
    if !host.ends_with(".googleapis.com") && host != "googleapis.com" {
        return Err(anyhow!("GCP request URL host is not a googleapis.com domain"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_valid_project_ids() {
        assert!(validate_project_id("my-project").is_ok());
        assert!(validate_project_id("my-project-123").is_ok());
        assert!(validate_project_id("a12345").is_ok());
        assert!(validate_project_id("project-with-many-hyphens-123").is_ok());
    }

    #[test]
    fn test_invalid_project_ids() {
        // Too short
        assert!(validate_project_id("abc").is_err());

        // Uppercase
        assert!(validate_project_id("MyProject").is_err());

        // Starts with number
        assert!(validate_project_id("123project").is_err());

        // Ends with hyphen
        assert!(validate_project_id("project-").is_err());

        // Contains underscore
        assert!(validate_project_id("my_project").is_err());

        // Empty
        assert!(validate_project_id("").is_err());

        // Too long (31 chars)
        assert!(validate_project_id("a123456789012345678901234567890").is_err());
    }

    #[test]
    fn test_valid_zones() {
        assert!(validate_zone("us-central1-a").is_ok());
        assert!(validate_zone("europe-west1-b").is_ok());
        assert!(validate_zone("asia-east1-c").is_ok());
        assert!(validate_zone("us-west2-a").is_ok());
    }

    #[test]
    fn test_invalid_zones() {
        assert!(validate_zone("invalid").is_err());
        assert!(validate_zone("us-central").is_err());
        assert!(validate_zone("US-CENTRAL1-A").is_err());
        assert!(validate_zone("").is_err());
        assert!(validate_zone("us_central1_a").is_err());
    }

    #[test]
    fn test_valid_instance_names() {
        assert!(validate_instance_name("my-vm").is_ok());
        assert!(validate_instance_name("a").is_ok());
        assert!(validate_instance_name("vm-01-test").is_ok());
        assert!(validate_instance_name("instance-with-many-hyphens").is_ok());
    }

    #[test]
    fn test_invalid_instance_names() {
        // Uppercase
        assert!(validate_instance_name("MyVM").is_err());

        // Starts with number
        assert!(validate_instance_name("1-vm").is_err());

        // Ends with hyphen
        assert!(validate_instance_name("vm-").is_err());

        // Contains underscore
        assert!(validate_instance_name("my_vm").is_err());

        // Empty
        assert!(validate_instance_name("").is_err());

        // Too long (64 chars)
        assert!(validate_instance_name(
            "a123456789012345678901234567890123456789012345678901234567890123"
        ).is_err());

        // Starts with hyphen
        assert!(validate_instance_name("-vm").is_err());
    }

    #[test]
    fn test_sanitize_zone_from_url() {
        // Valid GCP API URL
        let url = "https://www.googleapis.com/compute/v1/projects/my-project/zones/us-central1-a";
        assert_eq!(sanitize_zone_from_url(url).unwrap(), "us-central1-a");

        // Already just the zone name
        assert_eq!(sanitize_zone_from_url("us-west1-b").unwrap(), "us-west1-b");

        // Invalid zone in URL
        assert!(sanitize_zone_from_url("https://example.com/invalid-zone").is_err());
    }

    #[test]
    fn test_valid_usernames() {
        assert!(validate_username("jlopezre").is_ok());
        assert!(validate_username("_service").is_ok());
        assert!(validate_username("user01").is_ok());
        assert!(validate_username("user-name_01").is_ok());
        assert!(validate_username("a").is_ok());
    }

    #[test]
    fn test_invalid_usernames() {
        // Uppercase
        assert!(validate_username("User").is_err());
        assert!(validate_username("ROOT").is_err());

        // Starts with number
        assert!(validate_username("1user").is_err());

        // Starts with hyphen
        assert!(validate_username("-user").is_err());

        // Path traversal attempts
        assert!(validate_username("../root").is_err());
        assert!(validate_username("..").is_err());

        // Contains invalid characters
        assert!(validate_username("user@host").is_err());
        assert!(validate_username("user.name").is_err());
        assert!(validate_username("user/admin").is_err());

        // Empty
        assert!(validate_username("").is_err());

        // Too long (33 chars)
        assert!(validate_username("a12345678901234567890123456789012").is_err());
    }

    #[test]
    fn test_valid_emails() {
        assert!(validate_email("user@example.com").is_ok());
        assert!(validate_email("user.name@domain.co.uk").is_ok());
        assert!(validate_email("user+tag@gmail.com").is_ok());
        assert!(validate_email("test123@company.org").is_ok());
    }

    #[test]
    fn test_invalid_emails() {
        assert!(validate_email("").is_err());
        assert!(validate_email("invalid").is_err());
        assert!(validate_email("@domain.com").is_err());
        assert!(validate_email("user@").is_err());
        assert!(validate_email("user@.com").is_err());
        assert!(validate_email("user; rm -rf /@domain.com").is_err());
    }

    #[test]
    fn test_valid_snapshot_names() {
        assert!(validate_snapshot_name("my-vm-20260218-143022").is_ok());
        assert!(validate_snapshot_name("snap1").is_ok());
        assert!(validate_snapshot_name("a").is_ok());
        assert!(validate_snapshot_name("instance-backup-daily").is_ok());
    }

    #[test]
    fn test_invalid_snapshot_names() {
        // Uppercase
        assert!(validate_snapshot_name("Snap").is_err());
        // Starts with digit
        assert!(validate_snapshot_name("1snap").is_err());
        // Starts with hyphen
        assert!(validate_snapshot_name("-snap").is_err());
        // Ends with hyphen
        assert!(validate_snapshot_name("snap-").is_err());
        // Contains underscore
        assert!(validate_snapshot_name("my_snap").is_err());
        // Empty
        assert!(validate_snapshot_name("").is_err());
        // Too long (64 chars)
        assert!(validate_snapshot_name(
            "a123456789012345678901234567890123456789012345678901234567890123"
        ).is_err());
        // Injection attempts
        assert!(validate_snapshot_name("snap; rm -rf /").is_err());
        assert!(validate_snapshot_name("snap$(whoami)").is_err());
    }

    #[test]
    fn test_command_injection_attempts() {
        // These should all be rejected
        assert!(validate_instance_name("vm; rm -rf /").is_err());
        assert!(validate_instance_name("vm && whoami").is_err());
        assert!(validate_instance_name("vm | cat /etc/passwd").is_err());
        assert!(validate_instance_name("vm`whoami`").is_err());
        assert!(validate_instance_name("vm$(whoami)").is_err());
        assert!(validate_project_id("project; drop table users").is_err());
        assert!(validate_zone("us-central1-a; ls -la").is_err());
        assert!(validate_username("user; rm -rf /").is_err());
        assert!(validate_username("user`whoami`").is_err());
    }

    #[test]
    fn test_validate_gcp_url_valid() {
        assert!(validate_gcp_url("https://compute.googleapis.com/compute/v1/projects/foo").is_ok());
        assert!(validate_gcp_url("https://cloudresourcemanager.googleapis.com/v1/projects").is_ok());
        assert!(validate_gcp_url("https://oauth2.googleapis.com/token").is_ok());
        assert!(validate_gcp_url("https://googleapis.com/").is_ok());
    }

    #[test]
    fn test_validate_gcp_url_rejected() {
        // Non-HTTPS
        assert!(validate_gcp_url("http://compute.googleapis.com/compute/v1").is_err());
        // Wrong domain
        assert!(validate_gcp_url("https://evil.com/googleapis.com/token").is_err());
        assert!(validate_gcp_url("https://googleapis.com.evil.com/token").is_err());
        assert!(validate_gcp_url("https://notgoogleapis.com/token").is_err());
        // No scheme
        assert!(validate_gcp_url("compute.googleapis.com/compute/v1").is_err());
        // Empty
        assert!(validate_gcp_url("").is_err());
    }
}
