//! IAP relay session: target description, URL building and ACK accounting.

use crate::iap_tunnel::frame::MAX_DATA_FRAME_SIZE;

const RELAY_HOST: &str = "tunnel.cloudproxy.app";

/// What we are tunnelling to.
#[derive(Debug, Clone)]
pub struct TunnelTarget {
    pub project: String,
    pub zone: String,
    pub instance: String,
    pub remote_port: u16,
    pub interface: String,
}

impl TunnelTarget {
    pub fn new(project: &str, zone: &str, instance: &str, remote_port: u16) -> Self {
        Self {
            project: project.to_string(),
            zone: zone.to_string(),
            instance: instance.to_string(),
            remote_port,
            interface: "nic0".to_string(),
        }
    }
}

/// Percent-encode a query value (RFC 3986 unreserved set kept as-is).
fn encode(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*byte as char)
            }
            other => out.push_str(&format!("%{:02X}", other)),
        }
    }
    out
}

pub fn connect_url(target: &TunnelTarget) -> String {
    format!(
        "wss://{host}/v4/connect?project={project}&zone={zone}&instance={instance}\
         &interface={interface}&port={port}&newWebsocket=True",
        host = RELAY_HOST,
        project = encode(&target.project),
        zone = encode(&target.zone),
        instance = encode(&target.instance),
        interface = encode(&target.interface),
        port = target.remote_port,
    )
}

pub fn reconnect_url(target: &TunnelTarget, sid: &str, ack: u64) -> String {
    format!(
        "wss://{host}/v4/reconnect?sid={sid}&ack={ack}&zone={zone}&newWebsocket=True",
        host = RELAY_HOST,
        sid = encode(sid),
        ack = ack,
        zone = encode(&target.zone),
    )
}

/// Decides when to ACK. The relay recommends waiting for more than twice the
/// window size before acking, to avoid burning cycles on both ends.
#[derive(Debug, Default)]
pub struct AckPolicy {
    total_received: u64,
    total_acked: u64,
}

impl AckPolicy {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn on_received(&mut self, bytes: usize) {
        self.total_received += bytes as u64;
    }

    pub fn total_received(&self) -> u64 {
        self.total_received
    }

    /// Returns the value to ACK if the threshold has been crossed, marking
    /// those bytes as acknowledged.
    pub fn take_pending_ack(&mut self) -> Option<u64> {
        let threshold = (2 * MAX_DATA_FRAME_SIZE) as u64;
        if self.total_received - self.total_acked > threshold {
            self.total_acked = self.total_received;
            Some(self.total_acked)
        } else {
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn target() -> TunnelTarget {
        TunnelTarget::new("my-proj", "us-central1-a", "vm-1", 22)
    }

    #[test]
    fn connect_url_has_required_params() {
        let url = connect_url(&target());
        assert!(url.starts_with("wss://tunnel.cloudproxy.app/v4/connect?"));
        assert!(url.contains("project=my-proj"));
        assert!(url.contains("zone=us-central1-a"));
        assert!(url.contains("instance=vm-1"));
        assert!(url.contains("interface=nic0"));
        assert!(url.contains("port=22"));
        assert!(url.contains("newWebsocket=True"));
    }

    #[test]
    fn reconnect_url_carries_sid_and_ack() {
        let url = reconnect_url(&target(), "SID-123", 4096);
        assert!(url.starts_with("wss://tunnel.cloudproxy.app/v4/reconnect?"));
        assert!(url.contains("sid=SID-123"));
        assert!(url.contains("ack=4096"));
        assert!(url.contains("zone=us-central1-a"));
        assert!(url.contains("newWebsocket=True"));
    }

    #[test]
    fn url_params_are_percent_encoded() {
        let mut t = target();
        t.instance = "vm with space".to_string();
        assert!(connect_url(&t).contains("instance=vm%20with%20space"));
    }

    #[test]
    fn ack_is_withheld_until_threshold_is_exceeded() {
        let mut policy = AckPolicy::new();
        policy.on_received(crate::iap_tunnel::frame::MAX_DATA_FRAME_SIZE * 2);
        // Exactly 2x the window is NOT more than 2x — no ack yet.
        assert_eq!(policy.take_pending_ack(), None);

        policy.on_received(1);
        let acked = policy.take_pending_ack().expect("ack past threshold");
        assert_eq!(acked, (crate::iap_tunnel::frame::MAX_DATA_FRAME_SIZE * 2 + 1) as u64);
        // Draining twice must not re-ack the same bytes.
        assert_eq!(policy.take_pending_ack(), None);
    }

    #[test]
    fn total_received_accumulates() {
        let mut policy = AckPolicy::new();
        policy.on_received(10);
        policy.on_received(5);
        assert_eq!(policy.total_received(), 15);
    }
}
