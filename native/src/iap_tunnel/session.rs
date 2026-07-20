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

use crate::iap_tunnel::error::{classify_http_status, TunnelError};
use crate::iap_tunnel::frame::{self, Frame};
use futures_util::{SinkExt, StreamExt};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::Message;

/// Maximum times we try to resume a dropped relay connection before giving up.
const MAX_RECONNECTS: u32 = 3;

/// Bridge one local TCP connection to the relay until either side closes.
pub async fn run_session(
    target: TunnelTarget,
    local: TcpStream,
    token: String,
) -> Result<(), TunnelError> {
    let (mut local_read, mut local_write) = local.into_split();
    let mut policy = AckPolicy::new();
    let mut sid: Option<String> = None;
    let mut reconnects = 0u32;
    let mut pending = Vec::<u8>::new();

    loop {
        let url = match &sid {
            None => connect_url(&target),
            Some(sid) => reconnect_url(&target, sid, policy.total_received()),
        };

        let mut request = url
            .into_client_request()
            .map_err(|e| TunnelError::ProtocolError { detail: e.to_string() })?;
        request.headers_mut().insert(
            "Authorization",
            format!("Bearer {}", token)
                .parse()
                .map_err(|_| TunnelError::NotAuthenticated)?,
        );
        request.headers_mut().insert(
            "Sec-WebSocket-Protocol",
            "relay.tunnel.cloudproxy.app".parse().unwrap(),
        );

        let (mut ws, _) = match tokio_tungstenite::connect_async(request).await {
            Ok(pair) => pair,
            Err(tokio_tungstenite::tungstenite::Error::Http(resp)) => {
                let status = resp.status().as_u16();
                let body = resp
                    .body()
                    .as_ref()
                    .map(|b| String::from_utf8_lossy(b).to_string())
                    .unwrap_or_default();
                return Err(classify_http_status(status, &body));
            }
            Err(e) => {
                return Err(TunnelError::RelayUnreachable_from(e));
            }
        };

        let closed_cleanly = pump(
            &mut ws,
            &mut local_read,
            &mut local_write,
            &mut policy,
            &mut sid,
            &mut pending,
        )
        .await?;

        if closed_cleanly {
            return Ok(());
        }
        if sid.is_none() {
            // Never got a session id from the relay, so there is nothing to
            // resume — a reconnect attempt would just repeat the connect.
            return Err(TunnelError::RelayUnreachable);
        }
        if reconnects >= MAX_RECONNECTS {
            return Err(TunnelError::RelayUnreachable);
        }
        reconnects += 1;
        tracing::warn!(
            instance = %target.instance,
            attempt = reconnects,
            "IAP relay dropped, reconnecting"
        );
    }
}

/// One connected lifetime. Returns Ok(true) when the peer closed cleanly.
async fn pump(
    ws: &mut tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<TcpStream>,
    >,
    local_read: &mut tokio::net::tcp::OwnedReadHalf,
    local_write: &mut tokio::net::tcp::OwnedWriteHalf,
    policy: &mut AckPolicy,
    sid: &mut Option<String>,
    pending: &mut Vec<u8>,
) -> Result<bool, TunnelError> {
    let mut buf = vec![0u8; frame::MAX_DATA_FRAME_SIZE];

    loop {
        tokio::select! {
            read = local_read.read(&mut buf) => {
                let n = read.map_err(|e| TunnelError::ProtocolError {
                    detail: format!("local read failed: {}", e),
                })?;
                if n == 0 {
                    let _ = ws.close(None).await;
                    return Ok(true);
                }
                for chunk in frame::chunks(&buf[..n]) {
                    if let Err(e) = ws.send(Message::Binary(frame::encode_data(chunk))).await {
                        tracing::warn!(error = %e, "relay send failed, will attempt reconnect");
                        return Ok(false);
                    }
                }
            }
            incoming = ws.next() => {
                let message = match incoming {
                    None => return Ok(false),
                    Some(Ok(m)) => m,
                    Some(Err(e)) => {
                        tracing::warn!(error = %e, "relay stream error");
                        return Ok(false);
                    }
                };
                let bytes = match message {
                    Message::Binary(b) => b,
                    Message::Close(_) => return Ok(true),
                    _ => continue,
                };
                pending.extend_from_slice(&bytes);

                while let Some((parsed, consumed)) = frame::decode(pending)
                    .map_err(|e| TunnelError::ProtocolError { detail: format!("{:?}", e) })?
                {
                    pending.drain(..consumed);
                    match parsed {
                        Frame::ConnectSuccessSid(raw) => {
                            *sid = Some(String::from_utf8_lossy(&raw).to_string());
                        }
                        Frame::Data(payload) => {
                            policy.on_received(payload.len());
                            if let Err(e) = local_write.write_all(&payload).await {
                                tracing::warn!(error = %e, "local write failed, ending session");
                                return Ok(true);
                            }
                            if let Some(ack) = policy.take_pending_ack() {
                                if let Err(e) = ws.send(Message::Binary(frame::encode_ack(ack))).await {
                                    tracing::warn!(error = %e, "ack send failed, will attempt reconnect");
                                    return Ok(false);
                                }
                            }
                        }
                        Frame::Ack(_) | Frame::ReconnectSuccessAck(_) => {}
                        Frame::Unknown { tag } => {
                            tracing::debug!(tag, "ignoring unknown relay frame");
                        }
                    }
                }
            }
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
