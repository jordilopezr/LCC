# Tunnel Listener Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bound the exposure window of the local IAP tunnel port (threat T1) by reaping tunnels that have no active connection, without theater and without breaking live sessions.

**Architecture:** Add a per-tunnel `last_active` timestamp; a background reaper thread polls every 30s, refreshes `last_active` for tunnels with an ESTABLISHED loopback connection (parsed from `/proc/net/tcp`+`tcp6`), and stops any tunnel idle beyond 120s. The connection-detection and reap-decision logic are pure, unit-tested functions; the thread and `/proc` reads are thin wrappers.

**Tech Stack:** Rust (std threads, `/proc/net/tcp` parsing), existing `lazy_static` `TUNNELS` map.

## Global Constraints

- Branch `security/loopback-listener`. Rust changes in `native/src/tunnel.rs`; docs in `docs/THREAT_MODEL.md`.
- **Do NOT change branches** during execution; commit on `security/loopback-listener` only.
- Constants (verbatim from the spec): `IDLE_TIMEOUT = 120s`, `POLL_INTERVAL = 30s`.
- The reaper stops ONLY tunnels with **zero** ESTABLISHED loopback connections whose local port matches (a live session keeps the connection ESTABLISHED, so it is never reaped). If `/proc/net/tcp` cannot be read at all, the reaper does nothing (conservative — never reap on missing data).
- No new crate dependencies. No changes to the tunnel mechanism or default engine. No address/port randomization (rejected as theater in the spec).
- `cargo build && cargo build --release` must both succeed; `cargo test` stays green (the 2 pre-existing `gcp_rest_client::tests::test_get_access_token`/`test_list_projects` failures need live gcloud auth and are unrelated — ignore only those two). No bridge regen (internal only; no `api.rs` signature change).

---

## File Structure

- `native/src/tunnel.rs` — MODIFY: add `last_active` to `IapTunnel`; add pure `port_has_active_connection`/`should_reap` + loopback helpers + unit tests (Task 1); add the reaper thread, `/proc` reader, and lazy start wired into `start_tunnel` (Task 2).
- `docs/THREAT_MODEL.md` — MODIFY: rewrite T1 with the reaper mitigation and the honest residual reasoning (Task 3).

---

## Task 1: Connection-detection core + `last_active` field

**Files:**
- Modify: `native/src/tunnel.rs`
- Test: `#[cfg(test)]` in `native/src/tunnel.rs`

**Interfaces:**
- Produces: `IapTunnel` gains `pub last_active: std::time::Instant`; `pub fn port_has_active_connection(proc_tcp: &str, proc_tcp6: &str, port: u16) -> bool`; `pub fn should_reap(last_active: Instant, now: Instant, idle_timeout: Duration) -> bool`; private `is_loopback_v4_hex`/`is_loopback_v6_hex`.

- [ ] **Step 1: Write the failing unit tests**

Add this test module at the end of `native/src/tunnel.rs`:
```rust
#[cfg(test)]
mod reaper_tests {
    use super::*;

    // Realistic /proc/net/tcp lines. Column layout: sl local rem st ...
    // 1F90 = port 8080; 0100007F = 127.0.0.1; st 01 = ESTABLISHED, 0A = LISTEN.
    const EST_V4_8080: &str = "\
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:1F90 0100007F:C1A2 01 00000000:00000000 00:00000000 00000000  1000        0 12345 1 0 0 0 0 0";
    const LISTEN_V4_8080: &str = "\
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   1: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 12346 1 0 0 0 0 0";
    // ::1 loopback, ESTABLISHED, port 8080
    const EST_V6_8080: &str = "\
  sl  local_address                         remote_address                        st ...
   2: 00000000000000000000000001000000:1F90 00000000000000000000000001000000:C1A2 01 00000000:00000000 00:00000000 00000000  1000 0 12347 1 0 0 0 0 0";

    #[test]
    fn established_v4_loopback_on_port_is_active() {
        assert!(port_has_active_connection(EST_V4_8080, "", 8080));
    }

    #[test]
    fn listen_only_is_not_active() {
        assert!(!port_has_active_connection(LISTEN_V4_8080, "", 8080));
    }

    #[test]
    fn absent_port_is_not_active() {
        assert!(!port_has_active_connection(EST_V4_8080, "", 9999));
        assert!(!port_has_active_connection("", "", 8080));
    }

    #[test]
    fn established_v6_loopback_on_port_is_active() {
        assert!(port_has_active_connection("", EST_V6_8080, 8080));
    }

    #[test]
    fn should_reap_respects_timeout() {
        let now = Instant::now();
        let idle = Duration::from_secs(120);
        assert!(should_reap(now - Duration::from_secs(121), now, idle));
        assert!(!should_reap(now - Duration::from_secs(60), now, idle));
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd native && cargo test reaper_tests 2>&1 | tail -15`
Expected: FAIL to COMPILE — `port_has_active_connection`/`should_reap` don't exist.

- [ ] **Step 3: Add the `last_active` field**

In `native/src/tunnel.rs`, change the `IapTunnel` struct (currently lines 18-21):
```rust
pub struct IapTunnel {
    process: Child,
    pub local_port: u16,
    /// Last time an active loopback connection to `local_port` was observed
    /// (set at creation and refreshed by the idle reaper).
    pub last_active: std::time::Instant,
}
```
And in `start_tunnel`, change the construction (currently line 112 `let mut tunnel = IapTunnel { process: child, local_port: port };`) to:
```rust
    let mut tunnel = IapTunnel { process: child, local_port: port, last_active: Instant::now() };
```

- [ ] **Step 4: Add the pure detection functions**

Add these functions to `native/src/tunnel.rs` (near the bottom, before the test module):
```rust
/// True if any ESTABLISHED loopback TCP connection has `port` as its LOCAL
/// port — i.e. the server side of the tunnel's accepted connection. A live
/// RDP/VNC/SSH/SFTP session keeps this connection ESTABLISHED even while idle,
/// so its presence means the tunnel is in use. Parses the raw contents of
/// `/proc/net/tcp` (IPv4) and `/proc/net/tcp6` (IPv6).
pub fn port_has_active_connection(proc_tcp: &str, proc_tcp6: &str, port: u16) -> bool {
    const ESTABLISHED: &str = "01";
    for (contents, v6) in [(proc_tcp, false), (proc_tcp6, true)] {
        for line in contents.lines().skip(1) {
            let mut f = line.split_whitespace();
            let _sl = f.next();
            let local = match f.next() {
                Some(l) => l,
                None => continue,
            };
            let _rem = f.next();
            let state = match f.next() {
                Some(s) => s,
                None => continue,
            };
            if state != ESTABLISHED {
                continue;
            }
            let (ip_hex, port_hex) = match local.split_once(':') {
                Some(x) => x,
                None => continue,
            };
            let lport = match u16::from_str_radix(port_hex, 16) {
                Ok(p) => p,
                Err(_) => continue,
            };
            if lport != port {
                continue;
            }
            let loopback = if v6 {
                is_loopback_v6_hex(ip_hex)
            } else {
                is_loopback_v4_hex(ip_hex)
            };
            if loopback {
                return true;
            }
        }
    }
    false
}

/// `/proc/net/tcp` stores the IPv4 address as a little-endian hex u32, so the
/// first octet (127 = 0x7F for loopback) is the LAST byte of the 8-char string.
fn is_loopback_v4_hex(ip_hex: &str) -> bool {
    ip_hex.len() == 8 && ip_hex[6..8].eq_ignore_ascii_case("7f")
}

/// IPv6 loopback: `::1` or the v4-mapped `::ffff:127.0.0.1`.
fn is_loopback_v6_hex(ip_hex: &str) -> bool {
    ip_hex.eq_ignore_ascii_case("00000000000000000000000001000000") // ::1
        || (ip_hex.len() == 32 && ip_hex[24..32].eq_ignore_ascii_case("0100007f")) // ::ffff:127.0.0.1
}

/// Whether a tunnel idle since `last_active` should be reaped at `now`.
pub fn should_reap(last_active: Instant, now: Instant, idle_timeout: Duration) -> bool {
    now.duration_since(last_active) > idle_timeout
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd native && cargo test reaper_tests 2>&1 | tail -15`
Expected: PASS (5 tests). Also `cargo build` succeeds.

- [ ] **Step 6: Commit**

```bash
git add native/src/tunnel.rs
git commit -m "feat(security): tunnel connection-detection core + last_active field"
```

---

## Task 2: Idle reaper thread + wiring

**Files:**
- Modify: `native/src/tunnel.rs`

**Interfaces:**
- Consumes: `port_has_active_connection`, `should_reap`, `IapTunnel.last_active`, `TUNNELS`, `IapTunnel::stop` (Task 1 + existing).
- Produces: `reap_idle_tunnels_once()`, `start_reaper_once()` (private); constants `IDLE_TIMEOUT`, `POLL_INTERVAL`.

- [ ] **Step 1: Add constants, the `/proc` reader, and the reaper pass**

Add to `native/src/tunnel.rs` (after the pure functions from Task 1):
```rust
const IDLE_TIMEOUT: Duration = Duration::from_secs(120);
const POLL_INTERVAL: Duration = Duration::from_secs(30);

/// Reads /proc/net/tcp and /proc/net/tcp6; empty strings if unavailable.
fn read_proc_net_tcp() -> (String, String) {
    (
        std::fs::read_to_string("/proc/net/tcp").unwrap_or_default(),
        std::fs::read_to_string("/proc/net/tcp6").unwrap_or_default(),
    )
}

/// One reaper pass: refresh `last_active` for tunnels with an active
/// connection, then stop tunnels idle beyond `IDLE_TIMEOUT`. Killing happens
/// AFTER releasing the `TUNNELS` lock to keep the critical section short.
fn reap_idle_tunnels_once() {
    let (v4, v6) = read_proc_net_tcp();
    // Conservative: if we can't read /proc at all, never reap (avoid closing
    // tunnels that may be in use).
    if v4.is_empty() && v6.is_empty() {
        return;
    }
    let now = Instant::now();
    let mut reaped: Vec<(String, IapTunnel)> = Vec::new();
    {
        let mut tunnels = match TUNNELS.lock() {
            Ok(t) => t,
            Err(_) => return,
        };
        // Refresh last_active for active tunnels; collect idle keys.
        let mut idle_keys: Vec<String> = Vec::new();
        for (key, tunnel) in tunnels.iter_mut() {
            if port_has_active_connection(&v4, &v6, tunnel.local_port) {
                tunnel.last_active = now;
            } else if should_reap(tunnel.last_active, now, IDLE_TIMEOUT) {
                idle_keys.push(key.clone());
            }
        }
        for key in idle_keys {
            if let Some(t) = tunnels.remove(&key) {
                reaped.push((key, t));
            }
        }
    } // TUNNELS lock released here

    for (key, mut tunnel) in reaped {
        tracing::info!(
            tunnel = %key,
            local_port = tunnel.local_port,
            "Reaping idle tunnel (no active connection for >{}s)",
            IDLE_TIMEOUT.as_secs()
        );
        let _ = tunnel.stop();
    }
}

/// Starts the background reaper thread exactly once for the process.
fn start_reaper_once() {
    static STARTED: std::sync::Once = std::sync::Once::new();
    STARTED.call_once(|| {
        std::thread::spawn(|| loop {
            std::thread::sleep(POLL_INTERVAL);
            reap_idle_tunnels_once();
        });
    });
}
```

- [ ] **Step 2: Wire the reaper start into `start_tunnel`**

In `start_tunnel`, right after the successful insert into `TUNNELS` (currently `tunnels.insert(tunnel_key, tunnel);` at line 170, before `Ok(port)`), add:
```rust
    drop(tunnels); // release the lock before (idempotently) starting the reaper
    start_reaper_once();
```
(If `tunnels` is not otherwise used after the insert, `drop(tunnels)` simply releases the lock early; `start_reaper_once` is a no-op after the first call.)

- [ ] **Step 3: Verify it compiles and existing tests pass**

Run: `cd native && cargo build && cargo build --release && cargo test 2>&1 | tail -6`
Expected: both builds succeed; tests pass except the 2 pre-existing `gcp_rest_client` auth failures. No new warnings in `tunnel.rs`.

- [ ] **Step 4: Commit**

```bash
git add native/src/tunnel.rs
git commit -m "feat(security): idle-tunnel reaper thread (bounds T1 exposure window)"
```

---

## Task 3: Threat-model documentation

**Files:**
- Modify: `docs/THREAT_MODEL.md`

- [ ] **Step 1: Rewrite the T1 entry**

In `docs/THREAT_MODEL.md`, replace the entire **### T1 …** block (from its heading up to but not including the `### T2` heading) with:
```markdown
### T1 — Same-UID process connects to the local tunnel listener  *(residual: bounded)*
The tunnel is a `127.0.0.1` TCP socket. TCP has **no per-process ACL**, so any
process running as the same UID can `connect()` to the port and reach the
authenticated VM path while the tunnel is open. For the default (gcloud) engine
LCC does not even own the socket — `gcloud … --local-host-port=localhost:PORT`
binds it — so LCC cannot substitute a Unix-domain socket or add a per-connection
token. Randomizing the loopback address/port is **not** a control here: a
same-UID attacker simply enumerates listeners via `ss` / `/proc/net/tcp`.
- *Current mitigations:* loopback interface only (not routable off-host);
  ephemeral random port; explicit teardown on disconnect; tunnel startup aborts
  and cleans up if the port never listens (`native/src/tunnel.rs`, `start_tunnel`).
- *Idle reaper:* a background thread closes any tunnel with **zero** ESTABLISHED
  loopback connections for more than 120s (`native/src/tunnel.rs`,
  `reap_idle_tunnels_once`). This bounds the window for tunnels whose client
  exited, never connected (failed launch), or was forgotten. A live session
  keeps its TCP connection ESTABLISHED, so it is never reaped.
- *Residual:* a hostile same-UID process during the (now bounded) lifetime of a
  tunnel that is actually in use.
- *Out of scope / future:* real isolation via a private **network namespace**
  (the only control that stops a same-UID process reaching the port) is heavy,
  likely requires elevated setup, and is best coupled with the native Rust
  tunnel engine; it is deferred.
```

- [ ] **Step 2: Verify the doc is coherent**

Run: `grep -n "### T1\|### T2\|Idle reaper\|reap_idle_tunnels_once" docs/THREAT_MODEL.md`
Expected: the T1 block now mentions the idle reaper and precedes T2; no duplicate T1.

- [ ] **Step 3: Commit**

```bash
git add docs/THREAT_MODEL.md
git commit -m "docs(security): document tunnel idle reaper + bounded T1 residual"
```

---

## Self-Review (done at write time)

- **Spec coverage:** §1 idle reaper → Tasks 1 (core + field) + 2 (thread + wiring); §1.1 pure detection (`port_has_active_connection`, `should_reap`, v4/v6, ESTABLISHED-only, loopback) → Task 1 with fixture tests; §2 launch-failure teardown → covered by the existing `start_tunnel` port-listen teardown (documented in T1) plus the reaper as the backstop for client-never-connected (no fragile new wiring — the launch fns carry only the port, not the tunnel key, and the reaper closes such tunnels within ≤120s); §3 documentation → Task 3; §4 verification → Task 1 unit tests + Tasks 2/3 build/manual. Out-of-scope items (netns, randomization) are not implemented and are documented in T1. No gaps.
- **Placeholder scan:** every code step carries complete code; the `/proc` fixtures are real column layouts; the T1 replacement text is complete.
- **Type consistency:** `IapTunnel.last_active: Instant`, `port_has_active_connection(&str, &str, u16) -> bool`, `should_reap(Instant, Instant, Duration) -> bool`, `IDLE_TIMEOUT`/`POLL_INTERVAL: Duration`, `reap_idle_tunnels_once()`, `start_reaper_once()` — used consistently across Tasks 1-2. `Instant`/`Duration` are already imported in `tunnel.rs` (line 6).
