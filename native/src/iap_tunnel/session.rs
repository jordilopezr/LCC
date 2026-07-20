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

/// Buffers outbound bytes not yet acknowledged by the relay, so they can be
/// resent after a reconnect.
///
/// ACK semantics: the relay sends us `Frame::Ack(n)` / `Frame::ReconnectSuccessAck(n)`
/// meaning "I have received `n` bytes of your outbound stream so far" — this
/// is the mirror of our own `AckPolicy`, which tracks what WE received.
#[derive(Debug, Default)]
pub struct OutboundBuffer {
    total_sent: u64,
    confirmed: u64,
    unacked: std::collections::VecDeque<u8>,
}

impl OutboundBuffer {
    pub fn new() -> Self {
        Self::default()
    }

    /// Record bytes we just handed to the relay.
    pub fn record_sent(&mut self, bytes: &[u8]) {
        self.unacked.extend(bytes.iter().copied());
        self.total_sent += bytes.len() as u64;
    }

    /// The relay told us it has received `confirmed_total` bytes of our
    /// outbound stream in total. Drop the now-confirmed prefix.
    pub fn on_relay_ack(&mut self, confirmed_total: u64) {
        // Guard against a stale/repeated ack (confirmed_total <= confirmed,
        // idempotent no-op) or a bogus one that would claim more than we've
        // ever sent (clamp to total_sent).
        if confirmed_total <= self.confirmed {
            return;
        }
        let confirmed_total = confirmed_total.min(self.total_sent);
        let to_drop = (confirmed_total - self.confirmed).min(self.unacked.len() as u64);
        for _ in 0..to_drop {
            self.unacked.pop_front();
        }
        self.confirmed = confirmed_total;
    }

    /// Given the relay's reconnect ack (bytes of our outbound stream it has
    /// confirmed as of the resumed session), return everything from that
    /// point to the end of what we've sent, in order, so it can be resent.
    pub fn bytes_to_resend(&self, relay_confirmed: u64) -> Vec<u8> {
        // `unacked` only holds bytes from `self.confirmed` onward, so a
        // `relay_confirmed` below that (shouldn't happen) is clamped up; a
        // value above `total_sent` (also shouldn't happen) is clamped down.
        let relay_confirmed = relay_confirmed.clamp(self.confirmed, self.total_sent);
        let skip = (relay_confirmed - self.confirmed) as usize;
        self.unacked.iter().skip(skip).copied().collect()
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

/// How long the throwaway [`probe`] connection is allowed to take before it
/// is treated as an unreachable relay.
const PROBE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

/// Build the WebSocket client request for `url`, with the relay's auth
/// header and subprotocol. Shared by `run_session` and `probe` so both go
/// through the exact same handshake.
fn build_connect_request(
    url: &str,
    token: &str,
) -> Result<tokio_tungstenite::tungstenite::http::Request<()>, TunnelError> {
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
    Ok(request)
}

/// Open a throwaway connection to the relay to validate that a real session
/// would succeed (auth, permission, firewall, VM reachability). Returns Ok(())
/// once the relay sends CONNECT_SUCCESS_SID; maps handshake/transport failures
/// to TunnelError so the caller can fall back to gcloud.
pub async fn probe(target: &TunnelTarget, token: &str) -> Result<(), TunnelError> {
    match tokio::time::timeout(PROBE_TIMEOUT, probe_inner(target, token)).await {
        Ok(result) => result,
        Err(_elapsed) => Err(TunnelError::RelayUnreachable),
    }
}

async fn probe_inner(target: &TunnelTarget, token: &str) -> Result<(), TunnelError> {
    let request = build_connect_request(&connect_url(target), token)?;

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
        Err(e) => return Err(TunnelError::RelayUnreachable_from(e)),
    };

    let mut pending = Vec::<u8>::new();
    let result = loop {
        let message = match ws.next().await {
            None => {
                break Err(TunnelError::ProtocolError {
                    detail: "relay closed before CONNECT_SUCCESS_SID".to_string(),
                });
            }
            Some(Ok(m)) => m,
            Some(Err(e)) => break Err(TunnelError::RelayUnreachable_from(e)),
        };
        let bytes = match message {
            Message::Binary(b) => b,
            Message::Close(_) => {
                break Err(TunnelError::ProtocolError {
                    detail: "relay closed before CONNECT_SUCCESS_SID".to_string(),
                });
            }
            _ => continue,
        };
        pending.extend_from_slice(&bytes);

        let mut decoded = None;
        while let Some((parsed, consumed)) = frame::decode(&pending)
            .map_err(|e| TunnelError::ProtocolError { detail: format!("{:?}", e) })?
        {
            pending.drain(..consumed);
            if matches!(parsed, Frame::ConnectSuccessSid(_)) {
                decoded = Some(Ok(()));
                break;
            }
        }
        if let Some(result) = decoded {
            break result;
        }
    };

    let _ = ws.close(None).await;
    result
}

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
    // Lives outside the reconnect loop, like `pending`, so unacked outbound
    // bytes survive a reconnect and can be resent — it is NOT cleared on
    // reconnect (unlike `pending`, which holds inbound partial-frame state).
    let mut outbound = OutboundBuffer::new();

    loop {
        // `sid.is_some()` is exactly "this is a reconnect" — captured before
        // `pending` is cleared below, and passed into `pump` so it knows
        // whether to run the pre-loop resume phase (see `pump` doc comment).
        let is_reconnect = sid.is_some();
        if is_reconnect {
            // The relay will resend the DATA frame containing our last
            // acked byte in full, so any partial frame bytes left over from
            // the dropped connection would corrupt decoding if kept.
            pending.clear();
        }

        let url = match &sid {
            None => connect_url(&target),
            Some(sid) => reconnect_url(&target, sid, policy.total_received()),
        };

        let request = build_connect_request(&url, &token)?;

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
            &mut outbound,
            is_reconnect,
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

/// Outcome of the pre-loop resume phase (see [`resume_after_reconnect`]).
enum ResumeOutcome {
    /// `ReconnectSuccessAck` received, applied, and the unconfirmed tail
    /// resent — safe to enter the normal pump loop now.
    Resumed,
    /// The connection ended before resuming; `pump` should return this
    /// value directly (`true` = peer closed cleanly, `false` = dropped,
    /// caller should attempt another reconnect).
    Terminate(bool),
}

/// Read ONLY from the relay (no racing local reads) until
/// `Frame::ReconnectSuccessAck` is decoded, then apply it and resend the
/// outbound tail the relay never confirmed.
///
/// This exists to preserve outbound byte order across a reconnect. If the
/// normal `select!` loop (which also reads local data) were used here, a
/// client with buffered data ready to send would race the incoming
/// `ReconnectSuccessAck` and could send NEW data (stream position
/// >= total_sent) before the OLDER unconfirmed tail
/// (position in [relay_confirmed, total_sent)) gets resent. The relay
/// appends client->VM bytes in arrival order with no position field, so the
/// VM would see [new][old] instead of [old][new] — a corrupted stream. By
/// reading only from `ws` until the resend is complete, the unconfirmed
/// tail is always written to the socket before any new local bytes are.
///
/// Other frame types arriving during this phase are handled exactly as in
/// the normal loop, so nothing is dropped if e.g. a DATA frame precedes the
/// ReconnectSuccessAck.
async fn resume_after_reconnect(
    ws: &mut tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<TcpStream>,
    >,
    local_write: &mut tokio::net::tcp::OwnedWriteHalf,
    policy: &mut AckPolicy,
    sid: &mut Option<String>,
    pending: &mut Vec<u8>,
    outbound: &mut OutboundBuffer,
) -> Result<ResumeOutcome, TunnelError> {
    loop {
        let message = match ws.next().await {
            None => return Ok(ResumeOutcome::Terminate(false)),
            Some(Ok(m)) => m,
            Some(Err(e)) => {
                tracing::warn!(error = %e, "relay stream error while resuming after reconnect");
                return Ok(ResumeOutcome::Terminate(false));
            }
        };
        let bytes = match message {
            Message::Binary(b) => b,
            Message::Close(_) => return Ok(ResumeOutcome::Terminate(true)),
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
                        return Ok(ResumeOutcome::Terminate(true));
                    }
                    if let Some(ack) = policy.take_pending_ack() {
                        if let Err(e) = ws.send(Message::Binary(frame::encode_ack(ack))).await {
                            tracing::warn!(error = %e, "ack send failed, will attempt reconnect");
                            return Ok(ResumeOutcome::Terminate(false));
                        }
                    }
                }
                Frame::Ack(n) => {
                    outbound.on_relay_ack(n);
                }
                Frame::ReconnectSuccessAck(n) => {
                    outbound.on_relay_ack(n);
                    let resend = outbound.bytes_to_resend(n);
                    for chunk in frame::chunks(&resend) {
                        if let Err(e) = ws.send(Message::Binary(frame::encode_data(chunk))).await {
                            tracing::warn!(error = %e, "outbound resend failed, will attempt reconnect");
                            return Ok(ResumeOutcome::Terminate(false));
                        }
                    }
                    return Ok(ResumeOutcome::Resumed);
                }
                Frame::Unknown { tag } => {
                    tracing::debug!(tag, "ignoring unknown relay frame");
                }
            }
        }
    }
}

/// One connected lifetime. Returns Ok(true) when the peer closed cleanly.
///
/// `is_reconnect` is true whenever this connection is resuming a session
/// (i.e. we already have a `sid`) rather than establishing the first one. On
/// a reconnect, before reading any local data, we must wait for the relay's
/// `ReconnectSuccessAck` and resend the unconfirmed outbound tail — see
/// [`resume_after_reconnect`] for why. On the initial connect there is no
/// `ReconnectSuccessAck` and nothing to resend, so this phase is skipped
/// entirely and behavior is unchanged from before Fix C.
async fn pump(
    ws: &mut tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<TcpStream>,
    >,
    local_read: &mut tokio::net::tcp::OwnedReadHalf,
    local_write: &mut tokio::net::tcp::OwnedWriteHalf,
    policy: &mut AckPolicy,
    sid: &mut Option<String>,
    pending: &mut Vec<u8>,
    outbound: &mut OutboundBuffer,
    is_reconnect: bool,
) -> Result<bool, TunnelError> {
    let mut buf = vec![0u8; frame::MAX_DATA_FRAME_SIZE];

    if is_reconnect {
        match resume_after_reconnect(ws, local_write, policy, sid, pending, outbound).await? {
            ResumeOutcome::Resumed => {}
            ResumeOutcome::Terminate(result) => return Ok(result),
        }
    }

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
                    outbound.record_sent(chunk);
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
                        Frame::Ack(n) => {
                            outbound.on_relay_ack(n);
                        }
                        Frame::ReconnectSuccessAck(n) => {
                            // Normally this is only ever seen and handled in
                            // `resume_after_reconnect`, before this loop is
                            // entered (see `pump`'s `is_reconnect` gate).
                            // Handled defensively here too, in the same
                            // order (advance `confirmed` before resending),
                            // in case the relay ever sends a second one.
                            outbound.on_relay_ack(n);
                            let resend = outbound.bytes_to_resend(n);
                            for chunk in frame::chunks(&resend) {
                                if let Err(e) = ws.send(Message::Binary(frame::encode_data(chunk))).await {
                                    tracing::warn!(error = %e, "outbound resend failed, will attempt reconnect");
                                    return Ok(false);
                                }
                            }
                        }
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

    #[test]
    fn outbound_record_sent_accumulates_total_and_buffers_bytes() {
        let mut outbound = OutboundBuffer::new();
        outbound.record_sent(b"hello");
        outbound.record_sent(b"world");
        assert_eq!(outbound.total_sent, 10);
        assert_eq!(outbound.unacked.iter().copied().collect::<Vec<u8>>(), b"helloworld");
    }

    #[test]
    fn outbound_on_relay_ack_drops_confirmed_prefix() {
        let mut outbound = OutboundBuffer::new();
        outbound.record_sent(b"helloworld");
        outbound.on_relay_ack(5);
        assert_eq!(outbound.unacked.iter().copied().collect::<Vec<u8>>(), b"world");
        assert_eq!(outbound.confirmed, 5);
    }

    #[test]
    fn outbound_on_relay_ack_is_idempotent_for_stale_or_repeated_ack() {
        let mut outbound = OutboundBuffer::new();
        outbound.record_sent(b"helloworld");
        outbound.on_relay_ack(5);
        // Repeated ack at the same point: no-op.
        outbound.on_relay_ack(5);
        assert_eq!(outbound.unacked.iter().copied().collect::<Vec<u8>>(), b"world");
        // Stale ack (relay re-confirms an earlier, smaller total): no-op.
        outbound.on_relay_ack(2);
        assert_eq!(outbound.unacked.iter().copied().collect::<Vec<u8>>(), b"world");
        assert_eq!(outbound.confirmed, 5);
    }

    #[test]
    fn outbound_bytes_to_resend_returns_unconfirmed_tail_after_partial_ack() {
        let mut outbound = OutboundBuffer::new();
        outbound.record_sent(b"helloworld");
        outbound.on_relay_ack(5);
        assert_eq!(outbound.bytes_to_resend(5), b"world".to_vec());
    }

    #[test]
    fn outbound_bytes_to_resend_is_empty_after_full_ack() {
        let mut outbound = OutboundBuffer::new();
        outbound.record_sent(b"helloworld");
        outbound.on_relay_ack(10);
        assert_eq!(outbound.bytes_to_resend(10), Vec::<u8>::new());
    }
}
