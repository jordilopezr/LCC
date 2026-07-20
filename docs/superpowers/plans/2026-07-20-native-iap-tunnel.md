# Native IAP Tunnel Implementation Plan (27H1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Speak the IAP TCP forwarding protocol natively in Rust so tunnels no longer spawn a `gcloud compute start-iap-tunnel` child process, and introduce typed, localizable tunnel errors.

**Architecture:** New `native/src/iap_tunnel/` module in three layers — `frame.rs` (pure codec, no I/O), `session.rs` (WebSocket session: auth, ACKs, reconnect), `listener.rs` (local TcpListener bridging sockets to sessions). `native/src/tunnel.rs` becomes a facade that picks the native engine and falls back to gcloud on failure. Dart maps a stable error `code` to `.arb` keys.

**Tech Stack:** Rust (tokio, tokio-tungstenite, futures-util), flutter_rust_bridge 2.11.1, Flutter/Dart with gen-l10n.

**Spec:** `docs/superpowers/specs/2026-07-20-native-iap-tunnel-design.md`

## Global Constraints

- Branch: `27H1`. One commit per task; `cargo test` and `cargo build` must pass at every commit.
- Protocol constants (verbatim from spec, sourced from gcloud's own implementation):
  - URL: `wss://tunnel.cloudproxy.app/v4/connect`, reconnect: `wss://tunnel.cloudproxy.app/v4/reconnect`
  - Subprotocol: `relay.tunnel.cloudproxy.app`
  - `SUBPROTOCOL_TAG_LEN = 2`; header = tag + 4 bytes length; `SUBPROTOCOL_MAX_DATA_FRAME_SIZE = 16384`
  - Tags: `CONNECT_SUCCESS_SID = 0x0001`, `RECONNECT_SUCCESS_ACK = 0x0002`, `DATA = 0x0004`, `ACK = 0x0007`
  - Encoding is **big-endian**. `DATA` = `>H I <bytes>` (tag, u32 len, payload). `ACK` = `>H Q` (tag, u64 total bytes received).
  - Connect query params: `project`, `zone`, `instance`, `interface=nic0`, `port`, `newWebsocket=True`
  - Reconnect query params: `sid`, `ack`, `newWebsocket`, `zone`
  - ACK cadence: send when `total_received - total_acked > 2 * 16384`
- Access tokens come from the existing `GcpAuthClient::get_or_init()?.get_access_token().await` — do NOT implement OAuth.
- Reference implementation to consult when unsure (read-only, do not copy code):
  `/usr/lib/google-cloud-sdk/lib/googlecloudsdk/api_lib/compute/iap_tunnel_websocket_utils.py` and `iap_tunnel_websocket.py`
- Error `detail` strings are diagnostic and stay in English; only error *codes* get localized.
- i18n conventions (established in 26H2U2): keys camelCase with module prefix; cross-module strings use `common*`; every key must exist in BOTH `lib/l10n/app_en.arb` and `lib/l10n/app_es.arb`; Spanish uses neutral/impersonal register (usted, never tuteo); ellipsis is `…`.
- After editing `.arb` files run `flutter gen-l10n` and commit the regenerated `lib/l10n/gen/`.

---

### Task 1: Protocol codec (`frame.rs`)

**Files:**
- Create: `native/src/iap_tunnel/mod.rs`, `native/src/iap_tunnel/frame.rs`
- Modify: `native/src/lib.rs` (add `pub mod iap_tunnel;` after `pub mod tunnel;`)

**Interfaces:**
- Produces:
  - `pub const MAX_DATA_FRAME_SIZE: usize = 16384;`
  - `pub const TAG_CONNECT_SUCCESS_SID: u16 = 0x0001;` `TAG_RECONNECT_SUCCESS_ACK: u16 = 0x0002;` `TAG_DATA: u16 = 0x0004;` `TAG_ACK: u16 = 0x0007;`
  - `pub enum Frame { ConnectSuccessSid(Vec<u8>), ReconnectSuccessAck(u64), Data(Vec<u8>), Ack(u64), Unknown { tag: u16 } }`
  - `pub fn encode_data(payload: &[u8]) -> Vec<u8>`
  - `pub fn encode_ack(total_bytes: u64) -> Vec<u8>`
  - `pub fn decode(buf: &[u8]) -> Result<Option<(Frame, usize)>, FrameError>` — returns `Ok(None)` when more bytes are needed, otherwise the frame and how many bytes it consumed.
  - `pub enum FrameError { PayloadTooLarge { len: usize } }`

- [ ] **Step 1: Create the module skeleton**

`native/src/iap_tunnel/mod.rs`:
```rust
//! Native IAP TCP forwarding.
//!
//! Layers: `frame` (pure codec), `session` (WebSocket relay session),
//! `listener` (local TCP listener bridging sockets to sessions).

pub mod frame;
```

Add to `native/src/lib.rs`, right after the `pub mod tunnel;` line:
```rust
pub mod iap_tunnel;  // 27H1: native IAP TCP forwarding
```

- [ ] **Step 2: Write the failing tests**

Append to `native/src/iap_tunnel/frame.rs`:
```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn data_frame_round_trip() {
        let encoded = encode_data(b"hola");
        // tag(2) + len(4) + payload(4)
        assert_eq!(encoded.len(), 10);
        assert_eq!(&encoded[0..2], &[0x00, 0x04]);
        assert_eq!(&encoded[2..6], &[0, 0, 0, 4]);

        let (frame, consumed) = decode(&encoded).unwrap().unwrap();
        assert_eq!(consumed, 10);
        assert_eq!(frame, Frame::Data(b"hola".to_vec()));
    }

    #[test]
    fn ack_frame_round_trip() {
        let encoded = encode_ack(70_000);
        assert_eq!(encoded.len(), 10); // tag(2) + u64(8)
        assert_eq!(&encoded[0..2], &[0x00, 0x07]);

        let (frame, consumed) = decode(&encoded).unwrap().unwrap();
        assert_eq!(consumed, 10);
        assert_eq!(frame, Frame::Ack(70_000));
    }

    #[test]
    fn connect_success_sid_is_decoded() {
        let mut buf = vec![0x00, 0x01, 0, 0, 0, 3];
        buf.extend_from_slice(b"abc");
        let (frame, consumed) = decode(&buf).unwrap().unwrap();
        assert_eq!(consumed, 9);
        assert_eq!(frame, Frame::ConnectSuccessSid(b"abc".to_vec()));
    }

    #[test]
    fn reconnect_success_ack_is_decoded() {
        let mut buf = vec![0x00, 0x02];
        buf.extend_from_slice(&1234u64.to_be_bytes());
        let (frame, consumed) = decode(&buf).unwrap().unwrap();
        assert_eq!(consumed, 10);
        assert_eq!(frame, Frame::ReconnectSuccessAck(1234));
    }

    #[test]
    fn truncated_input_asks_for_more_bytes() {
        // Header says 4 bytes of payload but only 2 are present.
        let buf = vec![0x00, 0x04, 0, 0, 0, 4, b'h', b'o'];
        assert_eq!(decode(&buf).unwrap(), None);
        // Not even a full tag.
        assert_eq!(decode(&[0x00]).unwrap(), None);
        // Tag present, length truncated.
        assert_eq!(decode(&[0x00, 0x04, 0, 0]).unwrap(), None);
    }

    #[test]
    fn unknown_tag_is_reported_and_consumed_as_length_prefixed() {
        let buf = vec![0x00, 0x63, 0, 0, 0, 1, 0xFF];
        let (frame, consumed) = decode(&buf).unwrap().unwrap();
        assert_eq!(frame, Frame::Unknown { tag: 0x0063 });
        assert_eq!(consumed, 7);
    }

    #[test]
    fn oversized_payload_is_rejected() {
        let big = vec![0u8; MAX_DATA_FRAME_SIZE + 1];
        assert!(matches!(
            encode_data_checked(&big),
            Err(FrameError::PayloadTooLarge { .. })
        ));
    }

    #[test]
    fn chunking_splits_at_max_frame_size() {
        let payload = vec![7u8; MAX_DATA_FRAME_SIZE * 2 + 5];
        let chunks: Vec<&[u8]> = chunks(&payload).collect();
        assert_eq!(chunks.len(), 3);
        assert_eq!(chunks[0].len(), MAX_DATA_FRAME_SIZE);
        assert_eq!(chunks[1].len(), MAX_DATA_FRAME_SIZE);
        assert_eq!(chunks[2].len(), 5);
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd native && cargo test iap_tunnel::frame`
Expected: FAIL — compile errors, `encode_data` etc. not found.

- [ ] **Step 4: Implement the codec**

Write at the top of `native/src/iap_tunnel/frame.rs` (above the tests module):
```rust
//! IAP relay subprotocol codec. Pure functions, no I/O.
//!
//! Wire format (big-endian):
//!   DATA / CONNECT_SUCCESS_SID / unknown: tag(u16) + len(u32) + payload
//!   ACK / RECONNECT_SUCCESS_ACK:          tag(u16) + value(u64)

pub const MAX_DATA_FRAME_SIZE: usize = 16384;

pub const TAG_CONNECT_SUCCESS_SID: u16 = 0x0001;
pub const TAG_RECONNECT_SUCCESS_ACK: u16 = 0x0002;
pub const TAG_DATA: u16 = 0x0004;
pub const TAG_ACK: u16 = 0x0007;

const TAG_LEN: usize = 2;
const LEN_LEN: usize = 4;
const U64_LEN: usize = 8;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Frame {
    ConnectSuccessSid(Vec<u8>),
    ReconnectSuccessAck(u64),
    Data(Vec<u8>),
    Ack(u64),
    /// A tag we do not model. Consumed so the stream stays in sync.
    Unknown { tag: u16 },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FrameError {
    PayloadTooLarge { len: usize },
}

/// Split a payload into chunks that each fit in one DATA frame.
pub fn chunks(payload: &[u8]) -> impl Iterator<Item = &[u8]> {
    payload.chunks(MAX_DATA_FRAME_SIZE)
}

/// Encode one DATA frame. Panics in debug if the payload is oversized;
/// callers that cannot guarantee the size should use [`encode_data_checked`].
pub fn encode_data(payload: &[u8]) -> Vec<u8> {
    debug_assert!(payload.len() <= MAX_DATA_FRAME_SIZE);
    let mut out = Vec::with_capacity(TAG_LEN + LEN_LEN + payload.len());
    out.extend_from_slice(&TAG_DATA.to_be_bytes());
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    out.extend_from_slice(payload);
    out
}

pub fn encode_data_checked(payload: &[u8]) -> Result<Vec<u8>, FrameError> {
    if payload.len() > MAX_DATA_FRAME_SIZE {
        return Err(FrameError::PayloadTooLarge { len: payload.len() });
    }
    Ok(encode_data(payload))
}

pub fn encode_ack(total_bytes: u64) -> Vec<u8> {
    let mut out = Vec::with_capacity(TAG_LEN + U64_LEN);
    out.extend_from_slice(&TAG_ACK.to_be_bytes());
    out.extend_from_slice(&total_bytes.to_be_bytes());
    out
}

/// Decode the first frame in `buf`.
///
/// Returns `Ok(None)` when `buf` does not yet hold a complete frame — the
/// caller should read more bytes and retry with the same buffer.
pub fn decode(buf: &[u8]) -> Result<Option<(Frame, usize)>, FrameError> {
    if buf.len() < TAG_LEN {
        return Ok(None);
    }
    let tag = u16::from_be_bytes([buf[0], buf[1]]);
    let rest = &buf[TAG_LEN..];

    match tag {
        TAG_ACK | TAG_RECONNECT_SUCCESS_ACK => {
            if rest.len() < U64_LEN {
                return Ok(None);
            }
            let mut value = [0u8; U64_LEN];
            value.copy_from_slice(&rest[..U64_LEN]);
            let value = u64::from_be_bytes(value);
            let frame = if tag == TAG_ACK {
                Frame::Ack(value)
            } else {
                Frame::ReconnectSuccessAck(value)
            };
            Ok(Some((frame, TAG_LEN + U64_LEN)))
        }
        _ => {
            if rest.len() < LEN_LEN {
                return Ok(None);
            }
            let len = u32::from_be_bytes([rest[0], rest[1], rest[2], rest[3]]) as usize;
            let body = &rest[LEN_LEN..];
            if body.len() < len {
                return Ok(None);
            }
            let consumed = TAG_LEN + LEN_LEN + len;
            let payload = body[..len].to_vec();
            let frame = match tag {
                TAG_DATA => Frame::Data(payload),
                TAG_CONNECT_SUCCESS_SID => Frame::ConnectSuccessSid(payload),
                other => Frame::Unknown { tag: other },
            };
            Ok(Some((frame, consumed)))
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd native && cargo test iap_tunnel::frame`
Expected: PASS — 8 tests.

- [ ] **Step 6: Commit**

```bash
git add native/src/iap_tunnel native/src/lib.rs
git commit -m "feat(tunnel): IAP relay subprotocol codec"
```

---

### Task 2: Typed tunnel errors

**Files:**
- Create: `native/src/iap_tunnel/error.rs`
- Modify: `native/src/iap_tunnel/mod.rs` (add `pub mod error;`)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces:
  - `pub enum TunnelError { NotAuthenticated, PermissionDenied, InstanceNotFound { instance: String }, InstanceNotRunning, FirewallBlocked, RelayUnreachable, ProtocolError { detail: String }, LocalPortUnavailable { port: u16 } }`
  - `impl TunnelError { pub fn code(&self) -> &'static str; pub fn detail(&self) -> Option<String>; }`
  - `pub fn classify_http_status(status: u16, body: &str) -> TunnelError`
  - `impl std::fmt::Display for TunnelError` and `impl std::error::Error for TunnelError`

- [ ] **Step 1: Write the failing tests**

Append to `native/src/iap_tunnel/error.rs`:
```rust
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd native && cargo test iap_tunnel::error`
Expected: FAIL — module `error` not found / `TunnelError` undefined.

- [ ] **Step 3: Implement the error type**

Write above the tests in `native/src/iap_tunnel/error.rs`:
```rust
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
```

Add to `native/src/iap_tunnel/mod.rs`:
```rust
pub mod error;
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd native && cargo test iap_tunnel::error`
Expected: PASS — 4 tests.

- [ ] **Step 5: Commit**

```bash
git add native/src/iap_tunnel
git commit -m "feat(tunnel): typed TunnelError with stable codes"
```

---

### Task 3: URL builder + ACK policy

**Files:**
- Create: `native/src/iap_tunnel/session.rs` (URL + ACK policy only; the WebSocket loop arrives in Task 4)
- Modify: `native/src/iap_tunnel/mod.rs` (add `pub mod session;`)

**Interfaces:**
- Consumes: `frame::MAX_DATA_FRAME_SIZE` from Task 1.
- Produces:
  - `pub struct TunnelTarget { pub project: String, pub zone: String, pub instance: String, pub remote_port: u16, pub interface: String }`
  - `impl TunnelTarget { pub fn new(project: &str, zone: &str, instance: &str, remote_port: u16) -> Self }` (sets `interface: "nic0"`)
  - `pub fn connect_url(target: &TunnelTarget) -> String`
  - `pub fn reconnect_url(target: &TunnelTarget, sid: &str, ack: u64) -> String`
  - `pub struct AckPolicy { total_received: u64, total_acked: u64 }` with `pub fn new() -> Self`, `pub fn on_received(&mut self, bytes: usize)`, `pub fn take_pending_ack(&mut self) -> Option<u64>`, `pub fn total_received(&self) -> u64`

- [ ] **Step 1: Write the failing tests**

Append to `native/src/iap_tunnel/session.rs`:
```rust
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd native && cargo test iap_tunnel::session`
Expected: FAIL — module `session` not found.

- [ ] **Step 3: Implement URL building and ACK policy**

Write above the tests in `native/src/iap_tunnel/session.rs`:
```rust
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
```

Add to `native/src/iap_tunnel/mod.rs`:
```rust
pub mod session;
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd native && cargo test iap_tunnel::session`
Expected: PASS — 5 tests.

- [ ] **Step 5: Commit**

```bash
git add native/src/iap_tunnel
git commit -m "feat(tunnel): relay URL builder and ACK policy"
```

---

### Task 4: WebSocket session loop

**Files:**
- Modify: `native/src/iap_tunnel/session.rs` (add the connection loop)
- Modify: `native/Cargo.toml` (add dependencies)

**Interfaces:**
- Consumes: `TunnelTarget`, `connect_url`, `reconnect_url`, `AckPolicy` (Task 3); `frame::{decode, encode_data, encode_ack, chunks, Frame}` (Task 1); `TunnelError`, `classify_http_status` (Task 2).
- Produces:
  - `pub async fn run_session(target: TunnelTarget, local: tokio::net::TcpStream, token: String) -> Result<(), TunnelError>` — bridges one accepted local connection to the relay until either side closes.

- [ ] **Step 1: Add dependencies**

In `native/Cargo.toml`, extend the tokio features and add two crates:
```toml
tokio = { version = "1.48.0", features = ["rt", "time", "process", "io-util", "fs", "sync", "net", "macros"] }
tokio-tungstenite = { version = "0.24", features = ["rustls-tls-webpki-roots"] }
futures-util = "0.3"
```

Run: `cd native && cargo build`
Expected: compiles, new crates vendored.

- [ ] **Step 2: Implement the session loop**

Append to `native/src/iap_tunnel/session.rs` (before the `#[cfg(test)] mod tests` block):
```rust
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

        if closed_cleanly || sid.is_none() || reconnects >= MAX_RECONNECTS {
            return Ok(());
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
                    ws.send(Message::Binary(frame::encode_data(chunk)))
                        .await
                        .map_err(|e| TunnelError::ProtocolError {
                            detail: format!("relay send failed: {}", e),
                        })?;
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
                            local_write.write_all(&payload).await.map_err(|e| {
                                TunnelError::ProtocolError {
                                    detail: format!("local write failed: {}", e),
                                }
                            })?;
                            if let Some(ack) = policy.take_pending_ack() {
                                ws.send(Message::Binary(frame::encode_ack(ack)))
                                    .await
                                    .map_err(|e| TunnelError::ProtocolError {
                                        detail: format!("ack send failed: {}", e),
                                    })?;
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
```

Add this helper to `native/src/iap_tunnel/error.rs` (above the tests module) so the session can classify transport failures:
```rust
impl TunnelError {
    /// Classify a WebSocket transport failure. Anything that is not an HTTP
    /// status is treated as the relay being unreachable (DNS, TLS, proxy).
    #[allow(non_snake_case)]
    pub fn RelayUnreachable_from(err: tokio_tungstenite::tungstenite::Error) -> Self {
        tracing::warn!(error = %err, "IAP relay unreachable");
        TunnelError::RelayUnreachable
    }
}
```

- [ ] **Step 3: Verify it compiles and existing tests still pass**

Run: `cd native && cargo build && cargo test iap_tunnel`
Expected: build succeeds; the 17 tests from Tasks 1-3 pass.

- [ ] **Step 4: Commit**

```bash
git add native/Cargo.toml native/Cargo.lock native/src/iap_tunnel
git commit -m "feat(tunnel): WebSocket relay session loop with reconnect"
```

---

### Task 5: Local listener

**Files:**
- Create: `native/src/iap_tunnel/listener.rs`
- Modify: `native/src/iap_tunnel/mod.rs` (add `pub mod listener;` and re-export)

**Interfaces:**
- Consumes: `run_session`, `TunnelTarget` (Tasks 3-4); `TunnelError` (Task 2).
- Produces:
  - `pub struct NativeTunnel { pub local_port: u16, shutdown: tokio::sync::watch::Sender<bool>, handle: tokio::task::JoinHandle<()> }`
  - `impl NativeTunnel { pub fn stop(&self); pub fn is_running(&self) -> bool }`
  - `pub async fn start(target: TunnelTarget) -> Result<NativeTunnel, TunnelError>` — binds `127.0.0.1:0`, spawns the accept loop, returns as soon as the socket is listening.

- [ ] **Step 1: Write the failing test**

Create `native/src/iap_tunnel/listener.rs` with the tests module:
```rust
#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpStream as StdTcpStream;

    #[tokio::test]
    async fn start_binds_a_local_port_immediately() {
        let target = TunnelTarget::new("p", "z", "vm", 22);
        let tunnel = start(target).await.expect("listener starts");
        assert!(tunnel.local_port > 0);
        // The port must accept connections right away — no sleep/poll needed.
        StdTcpStream::connect(("127.0.0.1", tunnel.local_port))
            .expect("local port accepts connections");
        assert!(tunnel.is_running());
        tunnel.stop();
    }

    #[tokio::test]
    async fn stop_marks_the_tunnel_not_running() {
        let tunnel = start(TunnelTarget::new("p", "z", "vm", 22))
            .await
            .expect("listener starts");
        tunnel.stop();
        // Give the accept loop a tick to observe the shutdown signal.
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        assert!(!tunnel.is_running());
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd native && cargo test iap_tunnel::listener`
Expected: FAIL — `start` not found.

- [ ] **Step 3: Implement the listener**

Write above the tests in `native/src/iap_tunnel/listener.rs`:
```rust
//! Local TCP listener that bridges accepted connections to IAP relay sessions.

use crate::iap_tunnel::error::TunnelError;
use crate::iap_tunnel::session::{run_session, TunnelTarget};
use crate::gcp_rest_client::GcpAuthClient;
use tokio::net::TcpListener;
use tokio::sync::watch;

pub struct NativeTunnel {
    pub local_port: u16,
    shutdown: watch::Sender<bool>,
    handle: tokio::task::JoinHandle<()>,
}

impl NativeTunnel {
    /// Signal the accept loop to stop. Existing sessions end with their socket.
    pub fn stop(&self) {
        let _ = self.shutdown.send(true);
        self.handle.abort();
    }

    pub fn is_running(&self) -> bool {
        !self.handle.is_finished() && !*self.shutdown.borrow()
    }
}

/// Bind a local port and start accepting. Returns once the socket is listening,
/// so callers never have to poll for readiness.
pub async fn start(target: TunnelTarget) -> Result<NativeTunnel, TunnelError> {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .map_err(|_| TunnelError::LocalPortUnavailable { port: 0 })?;
    let local_port = listener
        .local_addr()
        .map_err(|_| TunnelError::LocalPortUnavailable { port: 0 })?
        .port();

    let (shutdown, mut rx) = watch::channel(false);

    let handle = tokio::spawn(async move {
        loop {
            let accepted = tokio::select! {
                _ = rx.changed() => break,
                accepted = listener.accept() => accepted,
            };
            let (socket, _peer) = match accepted {
                Ok(pair) => pair,
                Err(e) => {
                    tracing::warn!(error = %e, "accept failed on native tunnel");
                    continue;
                }
            };

            let target = target.clone();
            tokio::spawn(async move {
                let token = match fetch_token().await {
                    Ok(token) => token,
                    Err(err) => {
                        tracing::error!(error = %err, "no access token for tunnel session");
                        return;
                    }
                };
                if let Err(err) = run_session(target, socket, token).await {
                    tracing::error!(code = err.code(), detail = ?err.detail(), "tunnel session ended with error");
                }
            });
        }
    });

    Ok(NativeTunnel { local_port, shutdown, handle })
}

async fn fetch_token() -> Result<String, TunnelError> {
    let client = GcpAuthClient::get_or_init().map_err(|_| TunnelError::NotAuthenticated)?;
    client
        .get_access_token()
        .await
        .map_err(|_| TunnelError::NotAuthenticated)
}
```

Add to `native/src/iap_tunnel/mod.rs`:
```rust
pub mod listener;

pub use error::TunnelError;
pub use listener::{start, NativeTunnel};
pub use session::TunnelTarget;
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd native && cargo test iap_tunnel`
Expected: PASS — 19 tests (the two new ones bind real local sockets but never reach the relay).

- [ ] **Step 5: Commit**

```bash
git add native/src/iap_tunnel
git commit -m "feat(tunnel): local listener bridging to relay sessions"
```

---

### Task 6: Engine selection and gcloud fallback in `tunnel.rs`

**Files:**
- Modify: `native/src/tunnel.rs` (the `IapTunnel` struct at lines 18-21, `start_tunnel` at line 73, `stop_tunnel` at line 175, `check_tunnel_health` at line 198)

**Interfaces:**
- Consumes: `iap_tunnel::{start, NativeTunnel, TunnelTarget, TunnelError}` (Tasks 2-5).
- Produces: unchanged public functions `start_tunnel`, `stop_tunnel`, `check_tunnel_health`, `measure_tunnel_latency`, `cleanup_dead_tunnels`, `get_all_tunnels_status`, plus:
  - `pub enum TunnelEngine { Native, Gcloud }`
  - `pub fn selected_engine() -> Option<TunnelEngine>` — reads `LCC_TUNNEL_ENGINE`; `None` means "native first, fall back to gcloud".

- [ ] **Step 1: Write the failing test for engine selection**

Append to `native/src/tunnel.rs`:
```rust
#[cfg(test)]
mod engine_tests {
    use super::*;

    #[test]
    fn engine_defaults_to_none_when_unset() {
        std::env::remove_var("LCC_TUNNEL_ENGINE");
        assert!(selected_engine().is_none());
    }

    #[test]
    fn engine_can_be_forced() {
        std::env::set_var("LCC_TUNNEL_ENGINE", "native");
        assert!(matches!(selected_engine(), Some(TunnelEngine::Native)));
        std::env::set_var("LCC_TUNNEL_ENGINE", "gcloud");
        assert!(matches!(selected_engine(), Some(TunnelEngine::Gcloud)));
        std::env::set_var("LCC_TUNNEL_ENGINE", "nonsense");
        assert!(selected_engine().is_none());
        std::env::remove_var("LCC_TUNNEL_ENGINE");
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd native && cargo test engine_tests`
Expected: FAIL — `selected_engine` not found.

- [ ] **Step 3: Make `IapTunnel` hold either engine**

Replace the `IapTunnel` struct and its `stop`/`is_process_alive` methods in `native/src/tunnel.rs` (lines 18-40) with:
```rust
/// Which implementation is serving a tunnel.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TunnelEngine {
    Native,
    Gcloud,
}

/// Read `LCC_TUNNEL_ENGINE`. `None` = try native, fall back to gcloud.
/// Debug aid only; deliberately not exposed in Settings.
pub fn selected_engine() -> Option<TunnelEngine> {
    match std::env::var("LCC_TUNNEL_ENGINE").ok()?.as_str() {
        "native" => Some(TunnelEngine::Native),
        "gcloud" => Some(TunnelEngine::Gcloud),
        _ => None,
    }
}

enum Backend {
    Native(crate::iap_tunnel::NativeTunnel),
    Gcloud(Child),
}

pub struct IapTunnel {
    backend: Backend,
    pub local_port: u16,
}

impl IapTunnel {
    pub fn stop(&mut self) -> Result<()> {
        match &mut self.backend {
            Backend::Native(tunnel) => tunnel.stop(),
            Backend::Gcloud(process) => {
                let _ = process.kill();
                let _ = process.wait();
            }
        }
        Ok(())
    }

    /// Whether the tunnel's engine is still alive.
    pub fn is_process_alive(&mut self) -> bool {
        match &mut self.backend {
            Backend::Native(tunnel) => tunnel.is_running(),
            Backend::Gcloud(process) => matches!(process.try_wait(), Ok(None)),
        }
    }
}
```

`is_port_listening` and `is_healthy` (lines 41-62) stay exactly as they are — they only look at `local_port`.

- [ ] **Step 4: Rewrite `start_tunnel` to pick an engine**

Replace the body of `start_tunnel` in `native/src/tunnel.rs` from the `let port = get_free_port()?;` line through the end of the readiness-polling block with:
```rust
    let forced = selected_engine();

    // Native first unless gcloud was forced.
    if forced != Some(TunnelEngine::Gcloud) {
        match start_native(project, zone, instance, remote_port) {
            Ok(tunnel) => {
                let local_port = tunnel.local_port;
                let mut tunnels = TUNNELS.lock().map_err(|_| anyhow!("Tunnel lock poisoned"))?;
                tunnels.insert(make_tunnel_key(instance, remote_port), tunnel);
                tracing::info!(instance, remote_port, local_port, engine = "native", "Tunnel established");
                return Ok(local_port);
            }
            Err(err) => {
                if forced == Some(TunnelEngine::Native) {
                    return Err(err);
                }
                tracing::warn!(instance, error = %err, "Native tunnel failed, falling back to gcloud");
            }
        }
    }

    let tunnel = start_gcloud(project, zone, instance, remote_port)?;
    let local_port = tunnel.local_port;
    let mut tunnels = TUNNELS.lock().map_err(|_| anyhow!("Tunnel lock poisoned"))?;
    tunnels.insert(make_tunnel_key(instance, remote_port), tunnel);
    tracing::info!(instance, remote_port, local_port, engine = "gcloud", "Tunnel established");
    Ok(local_port)
}

/// Start the native engine on the shared tokio runtime.
fn start_native(project: &str, zone: &str, instance: &str, remote_port: u16) -> Result<IapTunnel> {
    let target = crate::iap_tunnel::TunnelTarget::new(project, zone, instance, remote_port);
    let native = crate::logging::block_on(crate::iap_tunnel::start(target))
        .map_err(|e| anyhow!("{}", e))?;
    Ok(IapTunnel { local_port: native.local_port, backend: Backend::Native(native) })
}

/// Legacy engine: spawn `gcloud compute start-iap-tunnel` and wait for the port.
fn start_gcloud(project: &str, zone: &str, instance: &str, remote_port: u16) -> Result<IapTunnel> {
    let port = get_free_port()?;
    let child = Command::new("gcloud")
        .args([
            "compute",
            "start-iap-tunnel",
            instance,
            &remote_port.to_string(),
            &format!("--local-host-port=localhost:{}", port),
            "--zone", zone,
            "--project", project,
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| anyhow!("Failed to spawn gcloud tunnel: {}", e))?;

    let mut tunnel = IapTunnel { local_port: port, backend: Backend::Gcloud(child) };
    std::thread::sleep(Duration::from_millis(1000));
    if !tunnel.is_process_alive() {
        return Err(anyhow!("Tunnel process died immediately after startup"));
    }
    for _ in 0..20 {
        if tunnel.is_port_listening() {
            return Ok(tunnel);
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    let _ = tunnel.stop();
    Err(anyhow!("gcloud tunnel port {} never started listening", port))
}
```

Keep the existing "tunnel already exists" early-return block at the top of `start_tunnel` untouched.

- [ ] **Step 5: Add the runtime helper**

The native engine is async but `start_tunnel` is sync (FFI). Add to `native/src/logging.rs`:
```rust
/// Shared multi-threaded runtime for async work called from sync FFI entry points.
static RUNTIME: std::sync::OnceLock<tokio::runtime::Runtime> = std::sync::OnceLock::new();

/// Run a future to completion on the shared runtime.
pub fn block_on<F: std::future::Future>(future: F) -> F::Output {
    RUNTIME
        .get_or_init(|| {
            tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .build()
                .expect("failed to build shared tokio runtime")
        })
        .block_on(future)
}
```

Add `"rt-multi-thread"` to the tokio features in `native/Cargo.toml`:
```toml
tokio = { version = "1.48.0", features = ["rt", "rt-multi-thread", "time", "process", "io-util", "fs", "sync", "net", "macros"] }
```

- [ ] **Step 6: Run the full Rust suite**

Run: `cd native && cargo test`
Expected: PASS — all tests including `engine_tests` and the `iap_tunnel` suites.

- [ ] **Step 7: Commit**

```bash
git add native/src/tunnel.rs native/src/logging.rs native/Cargo.toml native/Cargo.lock
git commit -m "feat(tunnel): native engine with automatic gcloud fallback"
```

---

### Task 7: Surface the error code across the bridge

**Files:**
- Modify: `native/src/api.rs` (the `start_connection` wrapper at line 189)
- Regenerate: `lib/src/bridge/api.dart/`
- Modify: `lib/src/features/gcloud_provider.dart` and `lib/src/features/tunnel_manager_dialog.dart` (call sites, only where the raw error string is shown)

**Interfaces:**
- Consumes: `TunnelError::code()` / `detail()` (Task 2), `start_tunnel` (Task 6).
- Produces:
  - Rust: `pub struct TunnelFailure { pub code: String, pub detail: Option<String> }`
  - Rust: `pub fn start_connection(project_id: String, zone: String, instance_name: String, remote_port: u16) -> Result<u16, TunnelFailure>` — signature preserved except for the error type.
  - Dart: generated `TunnelFailure` with `code` and `detail` fields.

- [ ] **Step 1: Add the bridge-facing failure type**

In `native/src/api.rs`, replace the `start_connection` wrapper (line 189-191) with:
```rust
/// Error crossing the bridge: a stable code plus untranslated diagnostic detail.
pub struct TunnelFailure {
    pub code: String,
    pub detail: Option<String>,
}

pub fn start_connection(
    project_id: String,
    zone: String,
    instance_name: String,
    remote_port: u16,
) -> Result<u16, TunnelFailure> {
    crate::tunnel::start_tunnel(&project_id, &zone, &instance_name, remote_port).map_err(|err| {
        match err.downcast_ref::<crate::iap_tunnel::TunnelError>() {
            Some(tunnel_error) => TunnelFailure {
                code: tunnel_error.code().to_string(),
                detail: tunnel_error.detail(),
            },
            None => TunnelFailure {
                code: "protocol_error".to_string(),
                detail: Some(err.to_string()),
            },
        }
    })
}
```

- [ ] **Step 2: Regenerate the bridge**

Run:
```bash
flutter_rust_bridge_codegen generate --rust-input "crate::api" --rust-root native --dart-output lib/src/bridge/api.dart
```
Expected: exits 0; `lib/src/bridge/api.dart/` now contains `TunnelFailure`.

- [ ] **Step 3: Fix Dart call sites**

Run: `flutter analyze`
Expected: errors where `startConnection` results are used. Fix each by catching `TunnelFailure` and keeping today's user-visible behaviour for now (Task 8 localizes it):
```dart
} on TunnelFailure catch (e) {
  state = state.copyWith(error: e.detail ?? e.code, errorCode: e.code);
}
```
Add an `errorCode` field to the state class only if the state already carries `error`; otherwise store the code alongside the existing message.

- [ ] **Step 4: Verify**

Run: `flutter analyze && cd native && cargo test`
Expected: 0 Dart errors; Rust suite green.

- [ ] **Step 5: Commit**

```bash
git add native/src/api.rs lib/src/bridge lib/src/features
git commit -m "feat(tunnel): expose typed tunnel failures across the bridge"
```

---

### Task 8: Localize tunnel errors

**Files:**
- Modify: `lib/l10n/app_en.arb`, `lib/l10n/app_es.arb`
- Modify: `lib/src/features/tunnel_manager_dialog.dart` (render the mapped message)
- Create: `test/tunnel_error_l10n_test.dart`

**Interfaces:**
- Consumes: `TunnelFailure.code` (Task 7).
- Produces: `String tunnelErrorMessage(AppLocalizations l10n, String code)` in `lib/src/features/tunnel_manager_dialog.dart`.

- [ ] **Step 1: Add the keys to both .arb files**

`lib/l10n/app_en.arb` (append before the closing brace, keeping the file's existing formatting):
```json
"tunnelErrorNotAuthenticated": "Not signed in to Google Cloud. Run 'gcloud auth login'.",
"tunnelErrorPermissionDenied": "Permission denied. The account needs the IAP-secured Tunnel User role.",
"tunnelErrorInstanceNotFound": "The instance no longer exists in this project and zone.",
"tunnelErrorInstanceNotRunning": "The instance is not running.",
"tunnelErrorFirewallBlocked": "A firewall rule is blocking IAP. Allow ingress from 35.235.240.0/20.",
"tunnelErrorRelayUnreachable": "Could not reach the IAP relay. Check the network or proxy settings.",
"tunnelErrorProtocolError": "Unexpected response from the IAP relay.",
"tunnelErrorLocalPortUnavailable": "No local port available for the tunnel.",
"tunnelErrorUnknown": "The tunnel could not be established."
```

`lib/l10n/app_es.arb` (same keys, neutral/impersonal register):
```json
"tunnelErrorNotAuthenticated": "No hay sesión iniciada en Google Cloud. Ejecute 'gcloud auth login'.",
"tunnelErrorPermissionDenied": "Permiso denegado. La cuenta necesita el rol de usuario de túnel protegido por IAP.",
"tunnelErrorInstanceNotFound": "La instancia ya no existe en este proyecto y zona.",
"tunnelErrorInstanceNotRunning": "La instancia no está en ejecución.",
"tunnelErrorFirewallBlocked": "Una regla de firewall está bloqueando IAP. Permita el tráfico de entrada desde 35.235.240.0/20.",
"tunnelErrorRelayUnreachable": "No se pudo contactar con el relay de IAP. Compruebe la red o la configuración del proxy.",
"tunnelErrorProtocolError": "Respuesta inesperada del relay de IAP.",
"tunnelErrorLocalPortUnavailable": "No hay ningún puerto local disponible para el túnel.",
"tunnelErrorUnknown": "No se pudo establecer el túnel."
```

- [ ] **Step 2: Write the failing test**

Create `test/tunnel_error_l10n_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linux_cloud_connector/l10n/gen/app_localizations.dart';
import 'package:linux_cloud_connector/src/features/tunnel_manager_dialog.dart';

/// Every code produced by Rust's TunnelError::code() must map to a message.
const _codes = <String>[
  'not_authenticated',
  'permission_denied',
  'instance_not_found',
  'instance_not_running',
  'firewall_blocked',
  'relay_unreachable',
  'protocol_error',
  'local_port_unavailable',
];

void main() {
  for (final locale in const [Locale('en'), Locale('es')]) {
    testWidgets('every tunnel error code maps to a message in $locale',
        (tester) async {
      late AppLocalizations l10n;
      await tester.pumpWidget(MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(builder: (context) {
          l10n = AppLocalizations.of(context);
          return const SizedBox();
        }),
      ));
      await tester.pumpAndSettle();

      for (final code in _codes) {
        final message = tunnelErrorMessage(l10n, code);
        expect(message, isNotEmpty, reason: 'no message for $code');
        expect(message, isNot(code), reason: '$code fell through to the raw code');
      }
      // An unknown code must not crash; it falls back to the generic message.
      expect(tunnelErrorMessage(l10n, 'something_new'),
          equals(l10n.tunnelErrorUnknown));
    });
  }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `flutter gen-l10n && flutter test test/tunnel_error_l10n_test.dart`
Expected: FAIL — `tunnelErrorMessage` is not defined.

- [ ] **Step 4: Implement the mapper**

Add to `lib/src/features/tunnel_manager_dialog.dart` (top level, after the imports):
```dart
/// Map a Rust `TunnelError::code()` to a localized message.
///
/// Unknown codes fall back to the generic message so a new Rust error can never
/// surface a raw identifier to the user.
String tunnelErrorMessage(AppLocalizations l10n, String code) {
  switch (code) {
    case 'not_authenticated':
      return l10n.tunnelErrorNotAuthenticated;
    case 'permission_denied':
      return l10n.tunnelErrorPermissionDenied;
    case 'instance_not_found':
      return l10n.tunnelErrorInstanceNotFound;
    case 'instance_not_running':
      return l10n.tunnelErrorInstanceNotRunning;
    case 'firewall_blocked':
      return l10n.tunnelErrorFirewallBlocked;
    case 'relay_unreachable':
      return l10n.tunnelErrorRelayUnreachable;
    case 'protocol_error':
      return l10n.tunnelErrorProtocolError;
    case 'local_port_unavailable':
      return l10n.tunnelErrorLocalPortUnavailable;
    default:
      return l10n.tunnelErrorUnknown;
  }
}
```

Ensure the file imports `package:linux_cloud_connector/l10n/gen/app_localizations.dart`.

- [ ] **Step 5: Use it where tunnel errors are shown**

In `lib/src/features/tunnel_manager_dialog.dart`, wherever the state's tunnel error is rendered, replace the raw string with `tunnelErrorMessage(l10n, state.errorCode)`. Keep `detail` out of the primary message; if the dialog already shows a secondary/diagnostic line, put `detail` there.

- [ ] **Step 6: Verify**

Run: `flutter gen-l10n && flutter analyze && flutter test`
Expected: 0 analyzer errors; all tests pass, including the new mapping test and the existing `es_overflow_test.dart`.

- [ ] **Step 7: Commit**

```bash
git add lib/l10n lib/src/features test/tunnel_error_l10n_test.dart
git commit -m "feat(tunnel): localize tunnel error codes (EN/ES)"
```

---

### Task 9: Docs and manual verification checklist

**Files:**
- Modify: `docs/SSOT.md`, `README.md`

- [ ] **Step 1: Full gate**

Run:
```bash
cd native && cargo test && cargo build --release && cd ..
flutter gen-l10n && flutter analyze && flutter test && flutter build linux --debug
python3 -c "import json;a=json.load(open('lib/l10n/app_en.arb'));b=json.load(open('lib/l10n/app_es.arb'));ka={k for k in a if not k.startswith('@')};kb={k for k in b if not k.startswith('@')};print(sorted(ka^kb) or 'PARITY OK')"
```
Expected: Rust tests pass, release build succeeds, 0 Dart analyzer errors, all Flutter tests pass, `PARITY OK`.

- [ ] **Step 2: Update the docs**

In `docs/SSOT.md`, under the roadmap, record that native IAP tunnelling ships in 27H1 with a gcloud fallback, that `LCC_TUNNEL_ENGINE` selects the engine for debugging, and that tunnel errors are the first module using typed codes — with `doctor.rs`, `sftp.rs`, `snapshots.rs` and `gcloud.rs` still pending.

In `README.md`, add to the tunnel feature section that tunnels are established natively without spawning `gcloud`, falling back automatically when the native path fails.

- [ ] **Step 3: Write the manual verification checklist**

Create `docs/superpowers/plans/2026-07-20-native-iap-tunnel-manual-qa.md` listing what the developer must confirm against a real instance, since the relay cannot be exercised in tests:
```markdown
# Manual QA — native IAP tunnel (27H1)

Run each check with `LCC_TUNNEL_ENGINE=native` so a silent fallback cannot mask a failure.

- [ ] SSH session over the tunnel opens and stays usable for several minutes.
- [ ] RDP session to a Windows VM connects and renders.
- [ ] SFTP browser lists, uploads and downloads a file.
- [ ] Large transfer (>50 MB, e.g. `scp`) completes with a correct checksum — exercises chunking and ACKs.
- [ ] Briefly drop the network (disable Wi-Fi ~5 s): the session resumes without restarting the tunnel.
- [ ] Tunnel Manager shows the tunnel healthy, and Disconnect actually closes the local port.
- [ ] Force an error: revoke the IAP role or target a stopped VM, and confirm the dialog shows the localized message (check both English and Spanish) rather than a raw code.
- [ ] Compare with `LCC_TUNNEL_ENGINE=gcloud` that behaviour is equivalent.
```

- [ ] **Step 4: Commit**

```bash
git add docs README.md
git commit -m "docs: native IAP tunnel in 27H1 + manual QA checklist"
```

---

## Self-Review (done at write time)

- **Spec coverage:** §1 architecture → Tasks 1, 3, 4, 5; §2 data flow → Tasks 4, 5; §3 typed errors → Tasks 2, 7, 8; §4 fallback and `LCC_TUNNEL_ENGINE` → Task 6; §5 testing → unit tests in Tasks 1-3, 5, 6, 8 plus the manual checklist in Task 9. The spec's bridge-regeneration note → Task 7. No gaps.
- **Placeholders:** none — every code step carries the code to write. Task 7 Step 3 and Task 8 Step 5 depend on call sites that only the regenerated bridge reveals, so they state the exact pattern to apply rather than inventing line numbers.
- **Type consistency:** `TunnelError` (Task 2) is used by name in Tasks 4, 5, 6, 7; `TunnelTarget::new` (Task 3) is called in Tasks 5-6 with the same four arguments; `NativeTunnel::{local_port, stop, is_running}` (Task 5) match their uses in Task 6; `TunnelFailure.{code, detail}` (Task 7) match the Dart test in Task 8; `frame::MAX_DATA_FRAME_SIZE` is the single source of the 16384 constant.
