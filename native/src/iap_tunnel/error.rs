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
    /// The relay answered and authenticated us, but never got through to the
    /// VM's port. Distinct from [`TunnelError::RelayUnreachable`] because the
    /// cause lives in the user's own project (a firewall rule that does not
    /// open this port to `35.235.240.0/20`, or nothing listening on it) and is
    /// therefore the one failure they can actually fix. Collapsing the two —
    /// as this enum used to — pointed every such report at the network.
    BackendUnreachable { port: u16 },
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
            TunnelError::BackendUnreachable { .. } => "backend_unreachable",
            TunnelError::ProtocolError { .. } => "protocol_error",
            TunnelError::LocalPortUnavailable { .. } => "local_port_unavailable",
        }
    }

    /// Diagnostic payload, in English, for logs and error reports.
    pub fn detail(&self) -> Option<String> {
        match self {
            TunnelError::InstanceNotFound { instance } => Some(instance.clone()),
            TunnelError::ProtocolError { detail } => Some(detail.clone()),
            TunnelError::BackendUnreachable { port } => Some(port.to_string()),
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
///
/// The relay's own answer is logged before classifying: 401/403/404 collapse to
/// variants that carry no detail, so without this the only record of *why* a
/// tunnel failed is discarded here. That silence cost a real debugging session.
pub fn classify_http_status(status: u16, body: &str) -> TunnelError {
    tracing::warn!(
        status,
        body = %crate::redact::redact_sensitive(body),
        "IAP relay rejected the tunnel handshake"
    );
    match status {
        401 => TunnelError::NotAuthenticated,
        403 => TunnelError::PermissionDenied,
        404 => TunnelError::InstanceNotFound { instance: String::new() },
        s if (500..=599).contains(&s) => TunnelError::RelayUnreachable,
        other => TunnelError::ProtocolError {
            detail: format!("relay returned HTTP {}: {}", other, body),
        },
    }
}

impl TunnelError {
    /// Classify a WebSocket transport failure. Anything that is not an HTTP
    /// status is treated as the relay being unreachable (DNS, TLS, proxy).
    #[allow(non_snake_case)]
    pub fn RelayUnreachable_from(err: tokio_tungstenite::tungstenite::Error) -> Self {
        tracing::warn!(error = %err, "IAP relay unreachable");
        TunnelError::RelayUnreachable
    }
}

#[cfg(test)]
mod tests {
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
            TunnelError::BackendUnreachable { port: 3000 }.code(),
            "backend_unreachable"
        );
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
        assert_eq!(
            TunnelError::BackendUnreachable { port: 3000 }.detail(),
            Some("3000".to_string())
        );
        assert_eq!(TunnelError::FirewallBlocked.detail(), None);
    }

    #[test]
    fn backend_unreachable_is_not_relay_unreachable() {
        // The whole point of the variant: a port the relay could not reach must
        // not be reported as a network/proxy problem between here and Google.
        assert_ne!(
            TunnelError::BackendUnreachable { port: 3000 }.code(),
            TunnelError::RelayUnreachable.code()
        );
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
