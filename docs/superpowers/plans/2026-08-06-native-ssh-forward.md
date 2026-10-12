# Native ssh2 SSH Port Forward Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in native ssh2 SSH port-forward engine (`LCC_SSH_FORWARD_ENGINE=native`) that replaces `gcloud compute ssh -L` with a native iap_tunnel-to-:22 + ssh2 session + a per-forward non-blocking `channel_direct_tcpip` reactor; gcloud stays the default.

**Architecture:** Reuse SFTP's `create_ssh_session` (extracted to a shared `ssh_session.rs`). A new `ssh_forward.rs` owns a `NativeSshForward` handle whose `start` brings up a native IAP transport to :22, an authenticated ssh2 session, a local `TcpListener`, and a dedicated reactor thread. `start_ssh_forward` in `tunnel.rs` dispatches to it via a new `Backend::NativeSshForward` variant, integrating with the existing `TUNNELS` map, reaper, and Tunnel Manager unchanged.

**Tech Stack:** Rust, `ssh2` 0.9.5 (libssh2), `std::net`, `std::thread`. Spec: `docs/superpowers/specs/2026-08-06-native-ssh-forward-design.md`.

## Global Constraints

- **Rust-only.** No bridge regen, no Dart, no new crate dependency (round-robin readiness, no `polling`/`mio`). Do NOT run `dart format`.
- **Opt-in:** `LCC_SSH_FORWARD_ENGINE=native` selects the native engine; unset / `gcloud` keeps the current `gcloud compute ssh -L` path (default). Mirror `selected_engine()`.
- IAP transport to :22 uses the **native** `iap_tunnel::start` (no gcloud). Username comes from `crate::sftp::get_current_username()` (no bridge). Auth reuses `create_ssh_session` — no key auto-provisioning.
- The chosen local port (`Option<u16>`, already threaded through `start_ssh_forward`) applies to the forward's **local listener**; the :22 IAP transport uses an auto port.
- Each task must leave `cargo build` warning-clean for touched items and `cargo test` green. Rebuild BOTH `cargo build` and `cargo build --release` before finishing.
- Commits touching code must NOT carry the `Co-Authored-By: Claude` trailer (docs commits only). Branch: `27H1-Preview`.

---

### Task 1: Extract `create_ssh_session` into a shared `ssh_session.rs`

**Files:**
- Create: `native/src/ssh_session.rs`
- Modify: `native/src/sftp.rs`, `native/src/lib.rs`

**Interfaces:**
- Produces (used by Task 3): `pub(crate) fn create_ssh_session(host: &str, port: u16, username: &str) -> anyhow::Result<ssh2::Session>`.

- [ ] **Step 1: Create `ssh_session.rs` with the moved function**

Create `native/src/ssh_session.rs`. Move the **entire** existing `create_ssh_session` function from `native/src/sftp.rs` (currently `fn create_ssh_session(host: &str, port: u16, username: &str) -> Result<Session>`, the doc comment `/// Create SSH session and authenticate` through its closing brace) **verbatim** into this new file, changing only: the visibility to `pub(crate)`, the return type to `anyhow::Result<ssh2::Session>` (spell out `ssh2::Session`), and add the imports it needs at the top of the new file:

```rust
use anyhow::{anyhow, Result};
use ssh2::Session;
use std::net::TcpStream;
```
(The function body already uses `dirs::home_dir()`, `tracing`, `TcpStream`, `Session` — all available via these imports plus the `dirs`/`tracing` crates already in the dependency tree.)

- [ ] **Step 2: Register the module**

In `native/src/lib.rs`, add `mod ssh_session;` alongside the other `mod` declarations (e.g. next to `mod sftp;`).

- [ ] **Step 3: Point `sftp.rs` at the shared helper**

In `native/src/sftp.rs`, delete the moved `create_ssh_session` function, and add near the top imports:

```rust
use crate::ssh_session::create_ssh_session;
```
Its ~9 existing call sites (`create_ssh_session(&host, port, &username)`) are unchanged. If removing the function leaves an import unused in `sftp.rs` (analyze/build will flag it — e.g. an import only the moved code used), remove it; do not remove imports still used elsewhere in `sftp.rs`.

- [ ] **Step 4: Build and test**

Run: `cd native && cargo build 2>&1 | tail -15`
Expected: builds with no errors and no new warnings.

Run: `cd native && cargo test 2>&1 | tail -15`
Expected: existing suite green (SFTP tests use the moved-but-identical helper).

- [ ] **Step 5: Commit**

```bash
cd /home/jlopezre/GitHub/LCC
git add native/src/ssh_session.rs native/src/sftp.rs native/src/lib.rs
git commit -m "refactor(ssh): extract create_ssh_session into shared ssh_session module"
```

---

### Task 2: `ssh_forward_engine()` flag + widen local-port helpers

**Files:**
- Modify: `native/src/tunnel.rs`

**Interfaces:**
- Consumes: existing `enum TunnelEngine { Native, Gcloud }`.
- Produces (used by Task 3): `pub fn ssh_forward_engine() -> Option<TunnelEngine>`; `pub(crate) fn ensure_local_port_available(port: u16) -> Result<()>`; `pub(crate) fn get_free_port() -> Result<u16>`.

- [ ] **Step 1: Write the failing test for the flag parser**

In the `#[cfg(test)] mod tests` block of `native/src/tunnel.rs`, add:

```rust
#[test]
fn ssh_forward_engine_parses_env_value() {
    use super::{parse_ssh_forward_engine, TunnelEngine};
    assert_eq!(parse_ssh_forward_engine(Some("native")), Some(TunnelEngine::Native));
    assert_eq!(parse_ssh_forward_engine(Some("gcloud")), Some(TunnelEngine::Gcloud));
    assert_eq!(parse_ssh_forward_engine(Some("bogus")), None);
    assert_eq!(parse_ssh_forward_engine(None), None);
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd native && cargo test ssh_forward_engine_parses_env_value 2>&1 | tail -15`
Expected: FAIL to compile — `cannot find function parse_ssh_forward_engine`.

- [ ] **Step 3: Add the pure parser + the env wrapper**

In `native/src/tunnel.rs`, next to `selected_engine()` (around line 29), add:

```rust
/// Pure parse of the SSH-forward engine selector (testable without env).
fn parse_ssh_forward_engine(val: Option<&str>) -> Option<TunnelEngine> {
    match val {
        Some("native") => Some(TunnelEngine::Native),
        Some("gcloud") => Some(TunnelEngine::Gcloud),
        _ => None,
    }
}

/// Read `LCC_SSH_FORWARD_ENGINE`. `None`/`gcloud` use the default gcloud
/// `gcloud compute ssh -L` path; `native` opts into the experimental native
/// ssh2 forward. Debug aid only; deliberately not exposed in Settings.
pub fn ssh_forward_engine() -> Option<TunnelEngine> {
    parse_ssh_forward_engine(std::env::var("LCC_SSH_FORWARD_ENGINE").ok().as_deref())
}
```

- [ ] **Step 4: Widen the local-port helpers to `pub(crate)`**

In `native/src/tunnel.rs`, change `fn ensure_local_port_available(port: u16) -> Result<()>` to `pub(crate) fn ensure_local_port_available(...)`, and `fn get_free_port() -> Result<u16>` to `pub(crate) fn get_free_port() -> Result<u16>` (bodies unchanged — Task 3's `ssh_forward.rs` reuses them).

- [ ] **Step 5: Run tests**

Run: `cd native && cargo test 2>&1 | tail -15`
Expected: `ssh_forward_engine_parses_env_value` passes; existing suite green. `cargo build` warning-clean (`ssh_forward_engine` is `pub`, so no dead-code warning before Task 3 uses it — mirrors `selected_engine`).

- [ ] **Step 6: Commit**

```bash
cd /home/jlopezre/GitHub/LCC
git add native/src/tunnel.rs
git commit -m "feat(tunnel): LCC_SSH_FORWARD_ENGINE flag + pub(crate) local-port helpers"
```

---

### Task 3: Native forward module + reactor + integration

Everything lands together so the crate compiles warning-clean (the module, its consumer in `tunnel.rs`, and the `Backend` variant reference each other). This is the feature's core; the reactor is the delicate part.

**Files:**
- Create: `native/src/ssh_forward.rs`
- Modify: `native/src/tunnel.rs`, `native/src/lib.rs`

**Interfaces:**
- Consumes: `crate::ssh_session::create_ssh_session` (Task 1); `ssh_forward_engine()`, `ensure_local_port_available`, `get_free_port` (Task 2); `crate::iap_tunnel::{start, TunnelTarget, NativeTunnel}`; `crate::sftp::get_current_username`; `crate::logging::block_on`; `tunnel.rs` `Backend`/`IapTunnel`/`TUNNELS`/`make_ssh_forward_key`.
- Produces: `pub struct NativeSshForward` with `pub fn local_port(&self) -> u16`, `pub fn is_running(&self) -> bool`, `pub fn stop(&mut self) -> Result<()>`; `pub(crate) fn start(project: &str, zone: &str, instance: &str, remote_port: u16, local_port: Option<u16>) -> Result<NativeSshForward>`.

- [ ] **Step 1: Create `ssh_forward.rs` — imports, handle, start**

Create `native/src/ssh_forward.rs`:

```rust
//! Native (ssh2/libssh2) SSH local port-forward, opt-in via
//! `LCC_SSH_FORWARD_ENGINE=native`. Brings up a native IAP transport to the
//! VM's :22, an authenticated ssh2 session, a local TCP listener, and a
//! dedicated non-blocking reactor thread that forwards each accepted
//! connection to `localhost:<remote_port>` inside the VM via
//! `channel_direct_tcpip` (the `-L` equivalent). No gcloud.

use anyhow::{anyhow, Result};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::Duration;

/// Handle for a running native SSH forward. Owns the reactor thread and the
/// underlying native IAP transport to :22; both are torn down by `stop`.
pub struct NativeSshForward {
    local_port: u16,
    shutdown: Arc<AtomicBool>,
    reactor: Option<JoinHandle<()>>,
    iap: crate::iap_tunnel::NativeTunnel,
}

impl NativeSshForward {
    pub fn local_port(&self) -> u16 {
        self.local_port
    }

    pub fn is_running(&self) -> bool {
        !self.shutdown.load(Ordering::Relaxed)
            && self.reactor.as_ref().map(|h| !h.is_finished()).unwrap_or(false)
    }

    pub fn stop(&mut self) -> Result<()> {
        self.shutdown.store(true, Ordering::Relaxed);
        if let Some(h) = self.reactor.take() {
            let _ = h.join();
        }
        self.iap.stop();
        Ok(())
    }
}

/// Start a native SSH forward: native IAP to :22 → ssh2 session → local
/// listener → reactor thread. `local_port == None` auto-assigns the listener
/// port; `Some(p)` binds exactly p (pre-checked for a clean error).
pub(crate) fn start(
    project: &str,
    zone: &str,
    instance: &str,
    remote_port: u16,
    local_port: Option<u16>,
) -> Result<NativeSshForward> {
    let username = crate::sftp::get_current_username()?;

    // 1) Native IAP transport to :22 (auto internal port).
    let target = crate::iap_tunnel::TunnelTarget::new(project, zone, instance, 22);
    let iap = crate::logging::block_on(crate::iap_tunnel::start(target, None))
        .map_err(anyhow::Error::new)?;
    let ssh_port = iap.local_port;

    // 2) Authenticated ssh2 session over the IAP transport.
    let sess = crate::ssh_session::create_ssh_session("127.0.0.1", ssh_port, &username)?;

    // 3) Local listener on the chosen (or auto) port.
    let bind_port = match local_port {
        Some(p) => {
            crate::tunnel::ensure_local_port_available(p)?;
            p
        }
        None => crate::tunnel::get_free_port()?,
    };
    let listener = TcpListener::bind(("127.0.0.1", bind_port))
        .map_err(|e| anyhow!("Failed to bind local port {}: {}", bind_port, e))?;
    listener
        .set_nonblocking(true)
        .map_err(|e| anyhow!("Failed to set listener non-blocking: {}", e))?;

    // 4) Reactor thread owns the session (non-blocking) and the listener.
    let shutdown = Arc::new(AtomicBool::new(false));
    let shutdown_thread = shutdown.clone();
    let reactor = std::thread::spawn(move || {
        run_reactor(sess, listener, remote_port, shutdown_thread);
    });

    tracing::info!(instance, remote_port, local_port = bind_port, "Native SSH forward established");
    Ok(NativeSshForward {
        local_port: bind_port,
        shutdown,
        reactor: Some(reactor),
        iap,
    })
}
```

- [ ] **Step 2: Add the reactor + per-connection pump to `ssh_forward.rs`**

Append the reactor. **Verify the non-blocking ssh2 0.9.5 semantics as you implement** — specifically that `channel_direct_tcpip` returns a `libssh2 EAGAIN` error while the channel open is in flight (retry), and that `Channel`'s `Read`/`Write` return `io::ErrorKind::WouldBlock` in non-blocking mode. If unsure of the exact EAGAIN discriminant, consult the ssh2 crate docs (e.g. via context7) rather than guessing; the `is_would_block_ssh` helper below centralizes that check. Iterate against the Task 4 manual QA.

```rust
const BUF: usize = 32 * 1024;

/// A live forwarded connection: a local socket paired with its ssh2 channel.
struct Conn {
    sock: TcpStream,
    chan: ssh2::Channel,
    done: bool,
}

/// True if an ssh2 error is a non-blocking "would block / try again" (EAGAIN).
fn is_would_block_ssh(e: &ssh2::Error) -> bool {
    // libssh2 LIBSSH2_ERROR_EAGAIN == -37. Verify against ssh2 0.9.5:
    // `e.code()` is `ssh2::ErrorCode`; the session variant carries the raw code.
    matches!(e.code(), ssh2::ErrorCode::Session(-37))
}

fn run_reactor(
    sess: ssh2::Session,
    listener: TcpListener,
    remote_port: u16,
    shutdown: Arc<AtomicBool>,
) {
    sess.set_blocking(false);
    let mut conns: Vec<Conn> = Vec::new();
    let mut pending: Vec<TcpStream> = Vec::new(); // accepted, awaiting channel open

    while !shutdown.load(Ordering::Relaxed) {
        let mut did_work = false;

        // Accept new local connections (non-blocking).
        match listener.accept() {
            Ok((sock, _)) => {
                let _ = sock.set_nonblocking(true);
                pending.push(sock);
                did_work = true;
            }
            Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(e) => tracing::warn!(error = %e, "ssh forward: accept error"),
        }

        // Open a channel for each pending socket (non-blocking open may EAGAIN).
        let mut still_pending = Vec::new();
        for sock in pending.drain(..) {
            match sess.channel_direct_tcpip("localhost", remote_port, None) {
                Ok(chan) => {
                    conns.push(Conn { sock, chan, done: false });
                    did_work = true;
                }
                Err(ref e) if is_would_block_ssh(e) => still_pending.push(sock),
                Err(e) => tracing::warn!(error = %e, "ssh forward: channel open failed"),
            }
        }
        pending = still_pending;

        // Pump each live connection both ways.
        for c in &mut conns {
            if pump(c) {
                did_work = true;
            }
        }
        conns.retain(|c| !c.done);

        if !did_work {
            std::thread::sleep(Duration::from_millis(2));
        }
    }

    // Teardown: close channels; the local sockets drop with `conns`.
    for c in &mut conns {
        let _ = c.chan.send_eof();
        let _ = c.chan.close();
    }
}

/// Move bytes both directions for one connection, non-blocking. Returns true if
/// any byte moved. Sets `c.done` on either side closing.
fn pump(c: &mut Conn) -> bool {
    let mut moved = false;
    let mut buf = [0u8; BUF];

    // local socket -> ssh channel
    match c.sock.read(&mut buf) {
        Ok(0) => {
            let _ = c.chan.send_eof();
            c.done = true;
        }
        Ok(n) => {
            if c.chan.write_all(&buf[..n]).is_err() {
                c.done = true;
            }
            moved = true;
        }
        Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
        Err(_) => c.done = true,
    }

    // ssh channel -> local socket
    match c.chan.read(&mut buf) {
        Ok(0) => {
            if c.chan.eof() {
                c.done = true;
            }
        }
        Ok(n) => {
            if c.sock.write_all(&buf[..n]).is_err() {
                c.done = true;
            }
            moved = true;
        }
        Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
        Err(_) => c.done = true,
    }

    moved
}
```

- [ ] **Step 3: Register the module and add the `Backend` variant + arms**

In `native/src/lib.rs`, add `mod ssh_forward;` alongside the other modules.

In `native/src/tunnel.rs`, extend the `Backend` enum:

```rust
enum Backend {
    Native(crate::iap_tunnel::NativeTunnel),
    Gcloud(Child),
    NativeSshForward(crate::ssh_forward::NativeSshForward),
}
```

In `IapTunnel::stop`, add the arm:

```rust
            Backend::NativeSshForward(f) => {
                let _ = f.stop();
            }
```

In `IapTunnel::is_process_alive`, add the arm:

```rust
            Backend::NativeSshForward(f) => f.is_running(),
```

(`is_port_listening` uses `local_port` and needs no change; the reactor's listener binds `local_port`.)

- [ ] **Step 4: Dispatch in `start_ssh_forward`**

In `native/src/tunnel.rs`, in `start_ssh_forward`, replace the `let tunnel = spawn_ssh_forward(project, zone, instance, remote_port, local_port)?;` line with the engine dispatch:

```rust
    let tunnel = if ssh_forward_engine() == Some(TunnelEngine::Native) {
        let f = crate::ssh_forward::start(project, zone, instance, remote_port, local_port)?;
        IapTunnel {
            local_port: f.local_port(),
            backend: Backend::NativeSshForward(f),
            last_active: Instant::now(),
        }
    } else {
        spawn_ssh_forward(project, zone, instance, remote_port, local_port)?
    };
```
(the surrounding dedup, `TUNNELS` insert, `start_reaper_once`, and the success log stay unchanged; `local` for the log is `tunnel.local_port`).

- [ ] **Step 5: Build (both profiles) + test**

Run: `cd native && cargo build 2>&1 | tail -20`
Expected: builds; no new warnings on the touched items (the `Backend` variant is constructed in the dispatch and its methods called in the arms — no dead code).

Run: `cd native && cargo test 2>&1 | tail -15`
Expected: existing suite + the Task 2 flag test green.

Run: `cd native && cargo build --release 2>&1 | tail -5`
Expected: release build succeeds.

- [ ] **Step 6: Commit**

```bash
cd /home/jlopezre/GitHub/LCC
git add native/src/ssh_forward.rs native/src/tunnel.rs native/src/lib.rs
git commit -m "feat(tunnel): native ssh2 SSH port-forward engine (opt-in)"
```

---

### Task 4: Gate + manual QA checklist

The reactor requires a live SSH+IAP path, so its correctness is verified manually.

**Files:**
- Create: `docs/superpowers/plans/2026-08-06-native-ssh-forward-manual-qa.md`

- [ ] **Step 1: Full Rust gate**

Run: `cd native && cargo test 2>&1 | tail -8` — Expected: all pass.
Run: `cd native && cargo build 2>&1 | tail -5` and `cd native && cargo build --release 2>&1 | tail -5` — Expected: both succeed (release `.so` is what the app loads).

- [ ] **Step 2: Write the manual QA checklist**

Create `docs/superpowers/plans/2026-08-06-native-ssh-forward-manual-qa.md`:

```markdown
# Manual QA — Native ssh2 SSH port forward (opt-in)

Launch the app with `LCC_SSH_FORWARD_ENGINE=native` and a reachable GCP VM whose
SSH key is already accepted (the same key SFTP uses). Compare against the
default (unset) gcloud path.

- [ ] Default (env unset): SSH-forward mode still works via `gcloud compute ssh -L` (no regression).
- [ ] `native`: open an SSH forward (Custom Tunnel → SSH forward) to a service on the VM (e.g. a DB on 5432 or a localhost-only web UI). It connects on the local port (chosen or auto).
- [ ] Data flows correctly through the forward (query the DB / load the page) — no truncation or hangs.
- [ ] Multiple concurrent connections through the same forward work (e.g. two DB clients).
- [ ] Choosing a fixed local port binds exactly that port; an occupied port gives a clean error.
- [ ] The forward appears in the Tunnel Manager and Disconnect stops it (port released; no leaked thread/process).
- [ ] Idle: after the reaper timeout with no active connection, the forward is reaped and its port freed.
- [ ] A VM whose key is NOT accepted → the forward fails with the ssh2 auth error (documented limitation: native does not auto-provision keys).
```

- [ ] **Step 3: Commit**

```bash
cd /home/jlopezre/GitHub/LCC
git add docs/superpowers/plans/2026-08-06-native-ssh-forward-manual-qa.md
git commit -m "docs(qa): manual QA checklist for native ssh2 SSH forward"
```

---

## Self-Review

**1. Spec coverage:**
- Extract `create_ssh_session` → `ssh_session.rs`, sftp uses it → Task 1. ✓
- `LCC_SSH_FORWARD_ENGINE` flag mirroring `selected_engine` → Task 2. ✓
- `pub(crate)` `ensure_local_port_available`/`get_free_port` → Task 2 Step 4. ✓
- `ssh_forward.rs`: `NativeSshForward` handle + `start` (native iap_tunnel :22 + create_ssh_session + listener + reactor thread) → Task 3 Step 1. ✓
- Non-blocking round-robin reactor (accept + channel_direct_tcpip + bidirectional pump + shutdown), no new dep → Task 3 Step 2. ✓
- `Backend::NativeSshForward` + stop/is_process_alive arms + dispatch + lib.rs mods → Task 3 Steps 3-4. ✓
- Username via `crate::sftp::get_current_username` (no bridge) → Task 3 Step 1. ✓
- Chosen local port applies to the listener; :22 auto → Task 3 Step 1 (bind_port vs iap auto). ✓
- Auth limitation (no auto-provision) → Task 4 QA note. ✓
- Rust-only, rebuild both profiles → Task 3 Step 5 + Task 4. ✓
- Manual-QA verification of the reactor → Task 4. ✓

**2. Placeholder scan:** No TBD/TODO. The reactor is complete code; the one explicit "verify against ssh2 0.9.5 docs" note concerns the non-blocking EAGAIN discriminant (`is_would_block_ssh`) — a correctness check the implementer must confirm, not a gap in the plan. The `create_ssh_session` move points at the exact source span (verbatim move, not re-transcribed).

**3. Type consistency:** `NativeSshForward` methods (`local_port`/`is_running`/`stop`) match the `Backend` arms in Task 3 Steps 3-4. `ssh_forward::start(project, zone, instance, remote_port, local_port: Option<u16>) -> Result<NativeSshForward>` matches the dispatch in Step 4. `create_ssh_session(host, port, username)` signature matches Task 1 and its use in Task 3 Step 1. `iap_tunnel::start(target, None)` matches the (post-local-port-feature) `start(target, local_port: Option<u16>)` signature. `ensure_local_port_available`/`get_free_port` are `pub(crate)` (Task 2) as used in Task 3. ✓
