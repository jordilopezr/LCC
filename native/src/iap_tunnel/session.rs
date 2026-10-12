//! IAP relay session: target description, URL building and ACK accounting.

use crate::iap_tunnel::frame::MAX_DATA_FRAME_SIZE;

const RELAY_HOST: &str = "tunnel.cloudproxy.app";
/// Origin the IAP relay requires on the WebSocket handshake. Not a URL: it is
/// the literal identifier gcloud's own tunnel client sends, and the relay
/// closes the connection with 4021 "invalid origin" for anything else.
const ORIGIN: &str = "bot:iap-tunneler";

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

/// How long each half of the throwaway [`probe`] is allowed to take. It is
/// applied twice, deliberately: once to reaching the relay and once to the
/// relay reaching the VM. Those two are different failures with different
/// fixes, and a single timeout around both cannot tell them apart.
const PROBE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

/// Relay close code for "failed to connect to backend": the relay saying, in
/// its own words, what a handshake timeout only implies.
const CLOSE_BACKEND_UNREACHABLE: u16 = 4003;

/// The relay connection a probe holds between its two timed halves.
type RelayStream =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<TcpStream>>;

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
    // The relay accepts the WebSocket and only then closes it with 4021
    // "invalid origin" if this is missing, which is why its absence read as a
    // protocol error rather than a missing header. gcloud's own IAP tunnel
    // client sends the same value.
    request
        .headers_mut()
        .insert("Origin", ORIGIN.parse().unwrap());
    Ok(request)
}

/// Open a throwaway connection to the relay to validate that a real session
/// would succeed (auth, permission, firewall, VM reachability). Returns Ok(())
/// once the relay sends CONNECT_SUCCESS_SID; maps handshake/transport failures
/// to TunnelError so the caller can fall back to gcloud.
/// Install the process-wide rustls crypto provider before the first TLS
/// handshake.
///
/// `tokio-tungstenite`'s rustls feature enables no provider, and rustls 0.23
/// refuses to pick one on its own: without this, `connect_async` panics with
/// "Could not automatically determine the process-level CryptoProvider from
/// Rustls crate features". That is exactly how the native tunnel failed for
/// every user — silently, since a panic across the bridge surfaces only as a
/// generic "tunnel could not be established".
///
/// Idempotent and cheap: the `Once` collapses repeated calls, and a losing
/// race is ignored because any installed provider satisfies rustls.
pub(crate) fn ensure_crypto_provider() {
    static INIT: std::sync::Once = std::sync::Once::new();
    INIT.call_once(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
    });
}

pub async fn probe(target: &TunnelTarget, token: &str) -> Result<(), TunnelError> {
    let mut ws = match tokio::time::timeout(PROBE_TIMEOUT, probe_connect(target, token)).await {
        Ok(result) => result?,
        Err(_elapsed) => {
            tracing::warn!(
                seconds = PROBE_TIMEOUT.as_secs(),
                "timed out reaching the IAP relay"
            );
            return Err(TunnelError::RelayUnreachable);
        }
    };

    let result = await_connect_success_within(&mut ws, target, PROBE_TIMEOUT).await;

    let _ = ws.close(None).await;
    result
}

/// [`await_connect_success`] under its own deadline.
///
/// Split out from [`probe`] only so the deadline can be made short in tests:
/// a relay that answers and then says nothing is exactly the blocked-port case,
/// and it must not be reported as an unreachable relay.
async fn await_connect_success_within(
    ws: &mut RelayStream,
    target: &TunnelTarget,
    deadline: std::time::Duration,
) -> Result<(), TunnelError> {
    match tokio::time::timeout(deadline, await_connect_success(ws, target)).await {
        Ok(result) => result,
        Err(_elapsed) => {
            tracing::warn!(
                seconds = deadline.as_secs(),
                port = target.remote_port,
                instance = %target.instance,
                "the IAP relay answered but never confirmed the session: it did not reach the VM's port"
            );
            Err(TunnelError::BackendUnreachable { port: target.remote_port })
        }
    }
}

/// First half of the probe: reach the relay and complete the WebSocket
/// upgrade. Everything that fails here is between this machine and Google —
/// DNS, TLS, a proxy, or the relay's own answer.
async fn probe_connect(target: &TunnelTarget, token: &str) -> Result<RelayStream, TunnelError> {
    ensure_crypto_provider();
    let request = build_connect_request(&connect_url(target), token)?;

    match tokio_tungstenite::connect_async(request).await {
        Ok((ws, _)) => Ok(ws),
        Err(tokio_tungstenite::tungstenite::Error::Http(resp)) => {
            let status = resp.status().as_u16();
            let body = resp
                .body()
                .as_ref()
                .map(|b| String::from_utf8_lossy(b).to_string())
                .unwrap_or_default();
            Err(classify_http_status(status, &body))
        }
        Err(e) => Err(TunnelError::RelayUnreachable_from(e)),
    }
}

/// Second half of the probe: wait for the relay to confirm it reached the VM's
/// port. Failures here are on the *far* side of the relay — in the user's own
/// project — which is why the caller times this separately.
async fn await_connect_success(
    ws: &mut RelayStream,
    target: &TunnelTarget,
) -> Result<(), TunnelError> {
    let mut pending = Vec::<u8>::new();
    loop {
        let message = match ws.next().await {
            None => {
                return Err(TunnelError::ProtocolError {
                    detail: "relay closed before CONNECT_SUCCESS_SID".to_string(),
                });
            }
            Some(Ok(m)) => m,
            Some(Err(e)) => return Err(TunnelError::RelayUnreachable_from(e)),
        };
        let bytes = match message {
            Message::Binary(b) => b,
            Message::Close(frame) => {
                // The relay explains itself in the close frame (code + reason):
                // wrong port, no listener on the VM, IAP policy, backend
                // unreachable. Discarding it — as this arm used to — reduced
                // every one of those to the same opaque "relay closed" string.
                let code = frame.as_ref().map(|f| u16::from(f.code));
                let reason = frame
                    .map(|f| format!("{} ({})", f.reason, f.code))
                    .unwrap_or_else(|| "no close frame".to_string());
                tracing::error!(reason = %reason, "IAP relay closed the tunnel before CONNECT_SUCCESS_SID");
                return Err(close_code_to_error(code, &reason, target.remote_port));
            }
            _ => continue,
        };
        pending.extend_from_slice(&bytes);

        while let Some((parsed, consumed)) = frame::decode(&pending)
            .map_err(|e| TunnelError::ProtocolError { detail: format!("{:?}", e) })?
        {
            pending.drain(..consumed);
            if matches!(parsed, Frame::ConnectSuccessSid(_)) {
                return Ok(());
            }
        }
    }
}

/// Classify a relay close frame received before `CONNECT_SUCCESS_SID`.
///
/// Only 4003 carries a cause the user can act on; everything else stays a
/// protocol error with the relay's own words attached.
fn close_code_to_error(code: Option<u16>, reason: &str, remote_port: u16) -> TunnelError {
    if code == Some(CLOSE_BACKEND_UNREACHABLE) {
        return TunnelError::BackendUnreachable { port: remote_port };
    }
    TunnelError::ProtocolError {
        detail: format!("relay closed before CONNECT_SUCCESS_SID: {}", reason),
    }
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

        // The session loop can outlive the probe (and reconnects run for the
        // tunnel's whole lifetime), so it must not assume the probe already
        // installed the provider.
        ensure_crypto_provider();
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

/// A scripted stand-in for the IAP relay, shared by this module's tests and
/// the listener's: no network, no TLS, no token.
#[cfg(test)]
pub(crate) mod test_relay {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;

    /// A connected client/server `RelayStream` pair over loopback. Lets the
    /// probe's second half be driven with a scripted relay — no network, no TLS.
    pub(crate) async fn relay_pair() -> (RelayStream, RelayStream) {
        use tokio_tungstenite::tungstenite::protocol::Role;
        use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let (client, accepted) = tokio::join!(tokio::net::TcpStream::connect(addr), listener.accept());
        let client = WebSocketStream::from_raw_socket(
            MaybeTlsStream::Plain(client.unwrap()),
            Role::Client,
            None,
        )
        .await;
        let server = WebSocketStream::from_raw_socket(
            MaybeTlsStream::Plain(accepted.unwrap().0),
            Role::Server,
            None,
        )
        .await;
        (client, server)
    }

    /// A scripted relay on the server half of `relay_pair`: confirms the
    /// session, then echoes every DATA payload back. Returns when the client
    /// side of the WebSocket goes away, reporting how it went.
    pub(crate) async fn echo_relay(mut server: RelayStream) -> &'static str {
        let mut sid = Vec::new();
        sid.extend_from_slice(&frame::TAG_CONNECT_SUCCESS_SID.to_be_bytes());
        sid.extend_from_slice(&3u32.to_be_bytes());
        sid.extend_from_slice(b"sid");
        server.send(Message::Binary(sid)).await.unwrap();

        let mut pending = Vec::new();
        loop {
            let bytes = match server.next().await {
                None => return "stream ended",
                Some(Err(_)) => return "stream error",
                Some(Ok(Message::Close(_))) => return "close frame",
                Some(Ok(Message::Binary(b))) => b,
                Some(Ok(_)) => continue,
            };
            pending.extend_from_slice(&bytes);
            while let Some((parsed, consumed)) = frame::decode(&pending).unwrap() {
                pending.drain(..consumed);
                if let Frame::Data(payload) = parsed {
                    if server.send(Message::Binary(frame::encode_data(&payload))).await.is_err() {
                        return "send failed";
                    }
                }
            }
        }
    }

    /// Serve one accepted local socket the way `run_session` does — the real
    /// `pump` — but against `echo_relay` instead of Google's. `relay_closed`
    /// flips when the relay side sees its WebSocket end.
    pub(crate) async fn serve_with_echo_relay(socket: TcpStream, relay_closed: Arc<AtomicBool>) {
        let (mut client_ws, server_ws) = relay_pair().await;
        tokio::spawn(async move {
            echo_relay(server_ws).await;
            relay_closed.store(true, Ordering::SeqCst);
        });
        let (mut local_read, mut local_write) = socket.into_split();
        let mut policy = AckPolicy::new();
        let mut sid = None;
        let mut pending = Vec::new();
        let mut outbound = OutboundBuffer::new();
        let _ = pump(
            &mut client_ws,
            &mut local_read,
            &mut local_write,
            &mut policy,
            &mut sid,
            &mut pending,
            &mut outbound,
            false,
        )
        .await;
    }
}

#[cfg(test)]
mod tests {
    use super::test_relay::{echo_relay, relay_pair};
    use super::*;

    /// Regression guard for the defect that made every native tunnel fail.
    ///
    /// `tokio-tungstenite`'s rustls feature enables no crypto provider, so
    /// rustls 0.23 panicked on the first handshake to the relay. Nothing caught
    /// it: the probe is the only code path that opens TLS, and the unit tests
    /// deliberately bypass it (`start_without_probe`) because it needs a live
    /// relay. This asserts the provider without any network at all — exactly
    /// the check that was missing.
    #[test]
    fn a_crypto_provider_is_installed_for_tls() {
        ensure_crypto_provider();
        assert!(
            rustls::crypto::CryptoProvider::get_default().is_some(),
            "no rustls CryptoProvider installed: every TLS handshake to the IAP relay would panic"
        );
    }

    fn target() -> TunnelTarget {
        TunnelTarget::new("my-proj", "us-central1-a", "vm-1", 22)
    }

    /// Regression guard: the relay rejects the handshake without an `Origin`,
    /// closing with code 4021 "invalid origin" *after* accepting the WebSocket
    /// — so the failure looked like a protocol error rather than a missing
    /// header, and no test covered the headers we actually send.
    #[test]
    fn connect_request_carries_the_relay_handshake_headers() {
        let request = build_connect_request(&connect_url(&target()), "tok-123")
            .expect("request builds");
        let headers = request.headers();

        assert_eq!(
            headers.get("Origin").map(|v| v.to_str().unwrap()),
            Some(ORIGIN),
            "the IAP relay closes with 4021 'invalid origin' when Origin is absent"
        );
        assert_eq!(
            headers.get("Sec-WebSocket-Protocol").map(|v| v.to_str().unwrap()),
            Some("relay.tunnel.cloudproxy.app")
        );
        assert_eq!(
            headers.get("Authorization").map(|v| v.to_str().unwrap()),
            Some("Bearer tok-123")
        );
    }

    /// The defect this splits the probe timeout to fix: a relay that answers
    /// and then never confirms is a port the relay could not reach — the user's
    /// own firewall or a dead service — not an unreachable relay. A single
    /// timeout around the whole probe reported both as `relay_unreachable`,
    /// pointing every such report at the network instead of the fixable cause.
    #[tokio::test]
    async fn a_silent_relay_is_backend_unreachable_not_relay_unreachable() {
        // `_server` stays alive: dropping it would close the socket and turn
        // this into a different failure.
        let (mut client, _server) = relay_pair().await;
        let target = TunnelTarget::new("my-proj", "us-central1-a", "vm-1", 3000);

        let err = await_connect_success_within(
            &mut client,
            &target,
            std::time::Duration::from_millis(100),
        )
        .await
        .expect_err("a relay that never confirms the session must fail");

        assert_eq!(err, TunnelError::BackendUnreachable { port: 3000 });
        assert_ne!(err.code(), TunnelError::RelayUnreachable.code());
    }

    /// 4003 is the relay stating the same cause outright.
    #[tokio::test]
    async fn a_relay_close_4003_names_the_unreachable_port() {
        use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
        use tokio_tungstenite::tungstenite::protocol::CloseFrame;

        let (mut client, mut server) = relay_pair().await;
        server
            .send(Message::Close(Some(CloseFrame {
                code: CloseCode::Library(CLOSE_BACKEND_UNREACHABLE),
                reason: "failed to connect to backend".into(),
            })))
            .await
            .unwrap();

        let target = TunnelTarget::new("my-proj", "us-central1-a", "vm-1", 5900);
        let err = await_connect_success_within(
            &mut client,
            &target,
            std::time::Duration::from_secs(5),
        )
        .await
        .expect_err("a 4003 close must fail the probe");

        assert_eq!(err, TunnelError::BackendUnreachable { port: 5900 });
    }

    #[test]
    fn other_close_codes_stay_protocol_errors() {
        // 4021 ("invalid origin") is ours to fix, not the user's: it must not
        // be dressed up as an unreachable port.
        assert_eq!(
            close_code_to_error(Some(4021), "invalid origin (4021)", 3000).code(),
            "protocol_error"
        );
        assert_eq!(
            close_code_to_error(None, "no close frame", 3000).code(),
            "protocol_error"
        );
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

    /// Nothing inside a session bounds its life but its client: held open it
    /// keeps forwarding, closed it ends at once and tells the relay. That is
    /// why `NativeTunnel::stop()` has to cut sessions itself — see its doc.
    #[tokio::test]
    async fn a_session_lives_until_its_local_client_closes() {
        use std::time::Duration;

        let (mut client_ws, server_ws) = relay_pair().await;
        let relay = tokio::spawn(echo_relay(server_ws));

        let local_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = local_listener.local_addr().unwrap();
        let (app, accepted) = tokio::join!(TcpStream::connect(addr), local_listener.accept());
        let mut app = app.unwrap();
        let (local, _) = accepted.unwrap();

        let session = tokio::spawn(async move {
            let (mut local_read, mut local_write) = local.into_split();
            let mut policy = AckPolicy::new();
            let mut sid = None;
            let mut pending = Vec::new();
            let mut outbound = OutboundBuffer::new();
            pump(
                &mut client_ws,
                &mut local_read,
                &mut local_write,
                &mut policy,
                &mut sid,
                &mut pending,
                &mut outbound,
                false,
            )
            .await
        });

        async fn round_trip(app: &mut TcpStream, msg: &[u8]) -> Vec<u8> {
            app.write_all(msg).await.unwrap();
            let mut buf = vec![0u8; msg.len()];
            tokio::time::timeout(Duration::from_secs(2), app.read_exact(&mut buf))
                .await
                .expect("no echo within 2 s")
                .unwrap();
            buf
        }

        assert_eq!(round_trip(&mut app, b"hola").await, b"hola");

        tokio::time::sleep(Duration::from_millis(500)).await;
        assert!(!session.is_finished(), "an idle session ended while its client held it open");
        assert_eq!(round_trip(&mut app, b"sigo").await, b"sigo");

        drop(app);
        let ended = tokio::time::timeout(Duration::from_secs(2), session)
            .await
            .expect("the session outlived its client")
            .unwrap();
        assert!(matches!(ended, Ok(true)), "a client closing is a clean end, not a drop to reconnect from");
        let relay_saw = tokio::time::timeout(Duration::from_secs(2), relay).await.unwrap().unwrap();
        assert_eq!(relay_saw, "close frame", "the relay must be told, not left to time out");
    }
}
