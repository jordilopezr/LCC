//! Sensitive data redaction module
//!
//! This module provides utilities for redacting sensitive information from
//! strings before logging or displaying them. This helps prevent accidental
//! exposure of credentials, tokens, and other sensitive data.
//!
//! # Security
//! This addresses CWE-532 (Insertion of Sensitive Information into Log File)

use regex::Regex;
use std::sync::LazyLock;

/// Patterns for sensitive data that should be redacted
static REDACTION_PATTERNS: LazyLock<Vec<(Regex, &'static str)>> = LazyLock::new(|| {
    vec![
        // OAuth/API tokens (various formats)
        (
            Regex::new(r#"(access_token|token|bearer|authorization)["\s:=]+["\']?([a-zA-Z0-9_\-\.]+)["\']?"#).unwrap(),
            "$1=[REDACTED]"
        ),
        // Google Cloud refresh tokens
        (
            Regex::new(r#"(refresh_token)["\s:=]+["\']?([a-zA-Z0-9_\-/\+\.]+)["\']?"#).unwrap(),
            "$1=[REDACTED]"
        ),
        // Client secrets
        (
            Regex::new(r#"(client_secret|secret)["\s:=]+["\']?([a-zA-Z0-9_\-\.]+)["\']?"#).unwrap(),
            "$1=[REDACTED]"
        ),
        // Passwords in various formats
        (
            Regex::new(r#"(password|passwd|pwd)["\s:=]+["\']?([^\s"\'&]+)["\']?"#).unwrap(),
            "$1=[REDACTED]"
        ),
        // API keys
        (
            Regex::new(r#"(api_key|apikey|api-key)["\s:=]+["\']?([a-zA-Z0-9_\-\.]+)["\']?"#).unwrap(),
            "$1=[REDACTED]"
        ),
        // Private keys (PEM format headers)
        (
            Regex::new(r#"-----BEGIN[A-Z\s]+PRIVATE KEY-----[\s\S]*?-----END[A-Z\s]+PRIVATE KEY-----"#).unwrap(),
            "[REDACTED_PRIVATE_KEY]"
        ),
        // Base64-encoded credentials (common in headers)
        (
            Regex::new(r#"Basic\s+([A-Za-z0-9+/=]{20,})"#).unwrap(),
            "Basic [REDACTED]"
        ),
        // JWT tokens (three base64 parts separated by dots)
        (
            Regex::new(r#"eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#).unwrap(),
            "[REDACTED_JWT]"
        ),
    ]
});

/// Redact sensitive information from a string
///
/// This function applies multiple regex patterns to identify and redact
/// sensitive information such as tokens, passwords, and API keys.
///
/// # Arguments
/// * `input` - The string that may contain sensitive information
///
/// # Returns
/// A new string with sensitive information replaced by [REDACTED] markers
///
/// # Example
/// ```
/// use native::redact::redact_sensitive;
///
/// let input = r#"{"access_token": "ya29.secret123", "password": "mypassword"}"#;
/// let redacted = redact_sensitive(input);
/// assert!(!redacted.contains("ya29.secret123"));
/// assert!(!redacted.contains("mypassword"));
/// ```
pub fn redact_sensitive(input: &str) -> String {
    let mut result = input.to_string();

    for (pattern, replacement) in REDACTION_PATTERNS.iter() {
        result = pattern.replace_all(&result, *replacement).to_string();
    }

    result
}

/// Redact a single value completely (for direct credential handling)
///
/// Use this when you need to log that a credential exists without revealing any part of it.
///
/// # Arguments
/// * `value` - The sensitive value to redact
///
/// # Returns
/// A string indicating the value's presence and approximate length
pub fn redact_value(value: &str) -> String {
    let len = value.len();
    if len == 0 {
        "[EMPTY]".to_string()
    } else if len <= 10 {
        "[REDACTED:short]".to_string()
    } else {
        format!("[REDACTED:{}chars]", len)
    }
}

/// Check if a string contains potentially sensitive data
///
/// This is useful for warning about potential credential leaks before logging.
pub fn contains_sensitive(input: &str) -> bool {
    let sensitive_keywords = [
        "password", "passwd", "pwd", "secret", "token", "api_key",
        "apikey", "private_key", "credential", "auth", "bearer",
    ];

    let lower = input.to_lowercase();
    sensitive_keywords.iter().any(|kw| lower.contains(kw))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_redact_access_token() {
        let input = r#"{"access_token": "ya29.a0AfH6SMBx_secret_token_123"}"#;
        let result = redact_sensitive(input);
        assert!(!result.contains("ya29.a0AfH6SMBx_secret_token_123"));
        assert!(result.contains("[REDACTED]"));
    }

    #[test]
    fn test_redact_password() {
        let input = "password=MyS3cr3tP@ss!";
        let result = redact_sensitive(input);
        assert!(!result.contains("MyS3cr3tP@ss!"));
        assert!(result.contains("[REDACTED]"));
    }

    #[test]
    fn test_redact_client_secret() {
        let input = r#"client_secret: "GOCSPX-abcdef123456""#;
        let result = redact_sensitive(input);
        assert!(!result.contains("GOCSPX-abcdef123456"));
        assert!(result.contains("[REDACTED]"));
    }

    #[test]
    fn test_redact_jwt() {
        let input = "Authorization: Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signature123";
        let result = redact_sensitive(input);
        assert!(!result.contains("eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9"));
        assert!(result.contains("[REDACTED_JWT]"));
    }

    #[test]
    fn test_redact_basic_auth() {
        let input = "Authorization: Basic dXNlcm5hbWU6cGFzc3dvcmQ=";
        let result = redact_sensitive(input);
        assert!(!result.contains("dXNlcm5hbWU6cGFzc3dvcmQ="));
        assert!(result.contains("[REDACTED]"));
    }

    #[test]
    fn test_redact_value() {
        assert_eq!(redact_value(""), "[EMPTY]");
        assert_eq!(redact_value("short"), "[REDACTED:short]");
        assert_eq!(redact_value("this_is_a_longer_secret"), "[REDACTED:23chars]");
    }

    #[test]
    fn test_contains_sensitive() {
        assert!(contains_sensitive("my_password=123"));
        assert!(contains_sensitive("Access-Token: xyz"));
        assert!(!contains_sensitive("Hello World"));
        assert!(!contains_sensitive("instance_name=my-vm"));
    }

    #[test]
    fn test_preserves_non_sensitive() {
        let input = "project=my-project zone=us-central1-a instance=my-vm";
        let result = redact_sensitive(input);
        assert_eq!(input, result);
    }
}
