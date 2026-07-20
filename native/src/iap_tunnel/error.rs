//! Typed tunnel errors.
//!
//! `code()` returns a stable snake_case identifier that crosses the bridge and
//! is mapped to a localized string in Dart. `detail()` carries diagnostic data
//! that is deliberately NOT translated.

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TunnelError {
    NotAuthenticated,
    PermissionDenied,
    InstanceNotFound { instance: String },
    InstanceNotRunning,
    FirewallBlocked,
    RelayUnreachable,
    ProtocolError { detail: String },
    LocalPortUnavailable { port: u16 },
}

impl TunnelError {
    pub fn code(&self) -> &'static str {
        match self {
            TunnelError::NotAuthenticated => "not_authenticated",
            TunnelError::PermissionDenied => "permission_denied",
            TunnelError::InstanceNotFound { .. } => "instance_not_found",
            TunnelError::InstanceNotRunning => "instance_not_running",
            TunnelError::FirewallBlocked => "firewall_blocked",
            TunnelError::RelayUnreachable => "relay_unreachable",
            TunnelError::ProtocolError { .. } => "protocol_error",
            TunnelError::LocalPortUnavailable { .. } => "local_port_unavailable",
        }
    }

    /// Diagnostic payload, in English, for logs and error reports.
    pub fn detail(&self) -> Option<String> {
        match self {
            TunnelError::InstanceNotFound { instance } => Some(instance.clone()),
            TunnelError::ProtocolError { detail } => Some(detail.clone()),
            TunnelError::LocalPortUnavailable { port } => Some(port.to_string()),
            _ => None,
        }
    }
}

impl std::fmt::Display for TunnelError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self.detail() {
            Some(detail) => write!(f, "{} ({})", self.code(), detail),
            None => write!(f, "{}", self.code()),
        }
    }
}

impl std::error::Error for TunnelError {}

/// Map an HTTP status from the relay handshake to a typed error.
pub fn classify_http_status(status: u16, body: &str) -> TunnelError {
    match status {
        401 => TunnelError::NotAuthenticated,
        403 => TunnelError::PermissionDenied,
        404 => TunnelError::InstanceNotFound { instance: String::new() },
        500 | 502 | 503 | 504 => TunnelError::RelayUnreachable,
        other => TunnelError::ProtocolError {
            detail: format!("relay returned HTTP {}: {}", other, body),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use super::*;

    #[test]
    fn codes_are_stable_snake_case() {
        assert_eq!(TunnelError::NotAuthenticated.code(), "not_authenticated");
        assert_eq!(TunnelError::PermissionDenied.code(), "permission_denied");
        assert_eq!(
            TunnelError::InstanceNotFound { instance: "vm1".into() }.code(),
            "instance_not_found"
        );
        assert_eq!(TunnelError::InstanceNotRunning.code(), "instance_not_running");
        assert_eq!(TunnelError::FirewallBlocked.code(), "firewall_blocked");
        assert_eq!(TunnelError::RelayUnreachable.code(), "relay_unreachable");
        assert_eq!(
            TunnelError::ProtocolError { detail: "x".into() }.code(),
            "protocol_error"
        );
        assert_eq!(
            TunnelError::LocalPortUnavailable { port: 1 }.code(),
            "local_port_unavailable"
        );
    }

    #[test]
    fn detail_carries_diagnostic_payload() {
        assert_eq!(
            TunnelError::InstanceNotFound { instance: "vm1".into() }.detail(),
            Some("vm1".to_string())
        );
        assert_eq!(
            TunnelError::ProtocolError { detail: "bad tag".into() }.detail(),
            Some("bad tag".to_string())
        );
        assert_eq!(TunnelError::FirewallBlocked.detail(), None);
    }

    #[test]
    fn http_statuses_map_to_errors() {
        assert_eq!(classify_http_status(401, ""), TunnelError::NotAuthenticated);
        assert_eq!(classify_http_status(403, ""), TunnelError::PermissionDenied);
        assert_eq!(
            classify_http_status(404, "instance not found"),
            TunnelError::InstanceNotFound { instance: String::new() }
        );
        assert_eq!(classify_http_status(503, ""), TunnelError::RelayUnreachable);
    }

    #[test]
    fn unmapped_status_becomes_protocol_error_with_detail() {
        let err = classify_http_status(418, "teapot");
        assert_eq!(err.code(), "protocol_error");
        assert!(err.detail().unwrap().contains("418"));
    }
}
