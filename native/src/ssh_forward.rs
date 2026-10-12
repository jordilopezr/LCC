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
use std::time::{Duration, Instant};

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
///
/// `username` is the caller's job to resolve (via `ssh_access::probe_ssh_access`
/// / `provision_ssh_access`), not this function's: under OS Login it is a
/// POSIX account that can differ from `$USER`, and authenticating as the
/// wrong one is exactly the failure this module must not reintroduce.
///
/// `identity_file` comes from the same place and is the key file that already
/// authenticated against this VM. Presenting only it matters because LCC's own
/// key lives outside `~/.ssh` and is offered LAST by the candidate ladder: a
/// user with a loaded agent and a couple of `~/.ssh` keys can exhaust `sshd`'s
/// default `MaxAuthTries` of 6 before it is ever reached, and the forward would
/// fail moments after provisioning reported success. `None` means the agent
/// authenticated, and the ladder is the right behaviour.
pub(crate) fn start(
    project: &str,
    zone: &str,
    instance: &str,
    remote_port: u16,
    local_port: Option<u16>,
    username: &str,
    identity_file: Option<&str>,
) -> Result<NativeSshForward> {
    // 1) Native IAP transport to :22 (auto internal port).
    let target = crate::iap_tunnel::TunnelTarget::new(project, zone, instance, 22);
    let iap = crate::logging::block_on(crate::iap_tunnel::start(target, None))
        .map_err(anyhow::Error::new)?;
    let ssh_port = iap.local_port;

    // Everything past this point is fallible. `NativeTunnel` has no `Drop`, so a
    // bare drop of `iap` on an early return would *detach* its background
    // accept-loop task and leak the relay port for the process lifetime (the idle
    // reaper can't help — this transport was never registered in TUNNELS). Only
    // `iap.stop()` tears it down. Run the remaining setup in a closure so the
    // first `?` short-circuits into the single `iap.stop()` cleanup below; the
    // closure needs only `ssh_port`, so `iap` is not moved and stays available to
    // hand to the returned handle on success.
    let setup = (|| -> Result<(ssh2::Session, u16, TcpListener)> {
        // 2) Authenticated ssh2 session over the IAP transport.
        let sess = crate::ssh_session::create_ssh_session_maybe_with_key(
            "127.0.0.1",
            ssh_port,
            username,
            identity_file.map(std::path::Path::new),
        )?;

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

        Ok((sess, bind_port, listener))
    })();

    let (sess, bind_port, listener) = match setup {
        Ok(parts) => parts,
        Err(e) => {
            // Tear down the IAP transport before propagating; otherwise its task
            // and bound port leak.
            iap.stop();
            return Err(e);
        }
    };

    // 4) Reactor thread owns the session (non-blocking) and the listener.
    let shutdown = Arc::new(AtomicBool::new(false));
    let shutdown_thread = shutdown.clone();
    let reactor = std::thread::spawn(move || {
        run_reactor(sess, listener, remote_port, shutdown_thread, KEEPALIVE_EVERY);
    });

    tracing::info!(instance, remote_port, local_port = bind_port, "Native SSH forward established");
    Ok(NativeSshForward {
        local_port: bind_port,
        shutdown,
        reactor: Some(reactor),
        iap,
    })
}

const BUF: usize = 32 * 1024;

/// The local half of a forwarded connection.
///
/// Abstracted over `TcpStream` so the pump's byte-shuffling — partial writes,
/// backpressure, per-side EOF — can be exercised without a live SSH server.
/// Those three properties were documented and untested until SP-2.
trait LocalEnd: Read + Write {
    /// Propagate a write-side FIN so the peer sees the far end close.
    fn shutdown_write(&mut self) -> std::io::Result<()>;
}

/// The remote half: an ssh2 channel in production, a double in tests.
trait RemoteEnd: Read + Write {
    /// Tell the far end we will send no more.
    fn send_eof(&mut self) -> std::io::Result<()>;
}

impl LocalEnd for TcpStream {
    fn shutdown_write(&mut self) -> std::io::Result<()> {
        self.shutdown(std::net::Shutdown::Write)
    }
}

impl RemoteEnd for ssh2::Channel {
    fn send_eof(&mut self) -> std::io::Result<()> {
        ssh2::Channel::send_eof(self).map_err(std::io::Error::other)
    }
}

/// A live forwarded connection: a local socket paired with its ssh2 channel.
///
/// Both endpoints are non-blocking, so a write may only partially drain. Each
/// direction owns a pending buffer holding bytes that were read from the source
/// but not yet accepted by the destination; the pump flushes these first and
/// applies backpressure (won't read a source while its destination buffer is
/// non-empty). EOF is tracked per side so a half-close on one direction does not
/// tear down the other.
struct Conn<L: LocalEnd, R: RemoteEnd> {
    sock: L,
    chan: R,
    /// Bytes read from `sock`, awaiting write to `chan` (local -> remote).
    to_chan: Vec<u8>,
    /// Bytes read from `chan`, awaiting write to `sock` (remote -> local).
    to_sock: Vec<u8>,
    /// Local socket reached EOF / read error; stop reading `sock`.
    sock_eof: bool,
    /// ssh channel reached EOF / read error; stop reading `chan`.
    chan_eof: bool,
    /// Write-side FIN propagated to the local peer after channel EOF; fired once.
    sock_fin_sent: bool,
    done: bool,
}

// Raw libssh2 error codes (libssh2.h). `ssh2::ErrorCode::Session` carries the
// number and nothing else, so they are named here. Checked against the
// versions Cargo.lock pins: ssh2 0.9.5 / libssh2-sys 0.3.1.
const EAGAIN: i32 = -37;
const SOCKET_NONE: i32 = -1;
const SOCKET_SEND: i32 = -7;
const SOCKET_DISCONNECT: i32 = -13;
const SOCKET_RECV: i32 = -43;

/// What a failed session operation means for the forward as a whole.
///
/// Two operations ask: opening a channel for an accepted socket, and sending
/// an idle keepalive. They share this one verdict on purpose — two places each
/// deciding "the session is dead" would sooner or later disagree.
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
enum SshFailure {
    /// libssh2 would block; try the same thing on a later tick.
    Retry,
    /// Whatever failed, the session is still standing and so is the forward.
    /// For a channel open, only that one socket is lost — most often the VM
    /// refused the channel because nothing listens on the remote port. For a
    /// keepalive, nothing is lost at all.
    ForwardSurvives,
    /// The socket under the session is gone. Every future operation fails the
    /// same way, so the forward has nothing left to forward.
    SessionGone,
}

/// Tell a dead session apart from everything else that can fail on it.
///
/// Getting this backwards in either direction is a real failure: calling a
/// refusal "dead" tears down a healthy forward whenever the user aims it at a
/// service that has not started yet, and calling a dead session "refused" is
/// the zombie this classifier exists to end — the reactor looping forever over
/// a transport that went away, with the listener still accepting and every
/// accepted socket dropped in silence.
///
/// Only the enumerated socket errors kill the forward. Anything unclassified
/// keeps it alive, so a code nobody has seen yet costs the old behaviour rather
/// than a working forward.
fn classify_ssh_failure(e: &ssh2::Error) -> SshFailure {
    match e.code() {
        ssh2::ErrorCode::Session(EAGAIN) => SshFailure::Retry,
        ssh2::ErrorCode::Session(SOCKET_NONE | SOCKET_SEND | SOCKET_DISCONNECT | SOCKET_RECV) => {
            SshFailure::SessionGone
        }
        _ => SshFailure::ForwardSurvives,
    }
}

/// How often an idle forward proves its session is still there.
///
/// A dead transport shows up as a failed send, and it usually takes two: the
/// first write after the IAP relay drops our socket still lands in the kernel
/// buffer and only draws the RST; the next one fails (`SOCKET_SEND`, seen in
/// `live_sshd_tests`). So detection costs up to two intervals — about 30 s —
/// and Dart's sweep adds under 30 s more. The price is one packet of about
/// 50 bytes per interval, and only while idle.
///
/// What this does NOT catch, and leaves exactly as it was before:
/// - A transport that dies while a forwarded connection stays open because
///   its local client never closes after the FIN it is sent. The keepalive
///   waits for the connections to end (see `should_send_keepalive`), so the
///   forward looks alive for as long as that connection lives.
/// - A relay WebSocket that goes half-open and silent. Our writes keep
///   landing in the relay's local socket; the failure only surfaces when the
///   relay's own TCP connection gives up retransmitting — minutes, set by the
///   kernel, not by this interval. Still better than before: without the
///   keepalive's traffic a silent half-open connection is never noticed.
const KEEPALIVE_EVERY: Duration = Duration::from_secs(15);

/// The smallest interval libssh2 accepts (it turns 1 into 2). `KeepaliveClock`
/// is the only authority on when a keepalive goes out; handing libssh2 our own
/// 15 s would give it a second, coarser gate — it counts whole seconds from
/// `time()` — that could silently skip a send our clock believes it made.
const LIBSSH2_KEEPALIVE_FLOOR_SECS: u32 = 2;

// Our interval below libssh2's floor would let libssh2's gate skip sends our
// clock believes it made — detection would stall with every test still green,
// since the tests bring their own interval.
const _: () = assert!(KEEPALIVE_EVERY.as_secs() >= LIBSSH2_KEEPALIVE_FLOOR_SECS as u64);

/// Decides when the next idle keepalive is due. Pure, so the "is it time
/// yet?" half of the liveness check is testable without a network.
struct KeepaliveClock {
    interval: Duration,
    next_due: Instant,
}

impl KeepaliveClock {
    fn new(start: Instant, interval: Duration) -> Self {
        Self { interval, next_due: start + interval }
    }

    /// True once `interval` has passed since the last time it said true (or
    /// since `start`). Saying true schedules the next one a full interval from
    /// `now`, not from the missed deadline, so a keepalive held back by
    /// traffic fires once rather than in a catch-up burst.
    fn due(&mut self, now: Instant) -> bool {
        if now < self.next_due {
            return false;
        }
        self.next_due = now + self.interval;
        true
    }
}

/// Whether this tick may send an idle keepalive.
///
/// The two vetoes are not caution; without either one a keepalive can freeze
/// a HEALTHY forward. libssh2's `keepalive_send` swallows EAGAIN. When the
/// socket's send buffer is nearly full it writes the keepalive packet only in
/// part, reports success, and leaves the unsent tail recorded against the
/// address of a buffer on its own stack (`session->packet.odata`). From then
/// on `send_existing()` answers EAGAIN to every other write — every channel
/// write, every window adjust — because their address differs. Only a later
/// `keepalive_send` from the same stack depth can finish that packet. A
/// saturated upload is exactly when the buffer is full, so a keepalive sent
/// under traffic can hang the forward for a whole interval, or for good.
///
/// - `channels_open`: no keepalive while any forwarded connection is live.
///   Those connections already probe the transport on every tick — each
///   `chan.read` is a `recv()` on the session's socket — so a dead transport
///   surfaces as a read error that ends them, and once none are left this
///   check runs again.
/// - `blocked`: no keepalive while libssh2 holds a half-sent packet (the
///   outbound direction is blocked). It would be swallowed, not sent.
///   Inbound-only blocking is the ordinary idle state and does not veto.
///
/// The clock is consulted last, so a vetoed tick does not spend the slot.
fn should_send_keepalive(
    clock: &mut KeepaliveClock,
    now: Instant,
    channels_open: bool,
    blocked: ssh2::BlockDirections,
) -> bool {
    use ssh2::BlockDirections::{Both, Outbound};
    if channels_open || matches!(blocked, Outbound | Both) {
        return false;
    }
    clock.due(now)
}

/// Whether a failed idle keepalive means the forward is over.
///
/// Only a dead socket does, by the same classifier a failed channel open
/// uses. Unlike that path there is no socket to retry or drop here, so both
/// `Retry` and `ForwardSurvives` mean the same thing: leave the forward up.
fn keepalive_ends_forward(e: &ssh2::Error) -> bool {
    classify_ssh_failure(e) == SshFailure::SessionGone
}

fn run_reactor(
    sess: ssh2::Session,
    listener: TcpListener,
    remote_port: u16,
    shutdown: Arc<AtomicBool>,
    keepalive_every: Duration,
) {
    sess.set_blocking(false);
    // want_reply = false: while idle nobody reads the transport, so replies
    // would only pile up unread; a dead transport shows on the send side.
    sess.set_keepalive(false, LIBSSH2_KEEPALIVE_FLOOR_SECS);
    let mut keepalive = KeepaliveClock::new(Instant::now(), keepalive_every);
    let mut conns: Vec<Conn<TcpStream, ssh2::Channel>> = Vec::new();
    let mut pending: Vec<TcpStream> = Vec::new(); // accepted, awaiting channel open

    // Single reusable read buffer, shared across every connection and tick, so
    // the hot pump path never re-zeroes a 32 KiB stack array per call.
    let mut scratch = vec![0u8; BUF];

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
        //
        // NOTE: libssh2 tracks channel-open progress in *session*-level state, so
        // only one direct-tcpip open is truly in flight at a time. If the first
        // open here returns EAGAIN and a later iteration calls
        // `channel_direct_tcpip` again, that second call re-enters the same
        // session-level open handshake. This is safe *only* because every open in
        // this reactor targets the identical destination ("localhost", remote_port)
        // — same host/port/no source — so an interleaved retry cannot open the
        // wrong channel. Do not generalize this loop to heterogeneous destinations
        // without serializing opens (retain the EAGAIN socket at the head and open
        // one at a time).
        let mut still_pending = Vec::new();
        let mut session_gone = false;
        for sock in pending.drain(..) {
            match sess.channel_direct_tcpip("localhost", remote_port, None) {
                Ok(chan) => {
                    conns.push(Conn {
                        sock,
                        chan,
                        to_chan: Vec::new(),
                        to_sock: Vec::new(),
                        sock_eof: false,
                        chan_eof: false,
                        sock_fin_sent: false,
                        done: false,
                    });
                    did_work = true;
                }
                Err(e) => match classify_ssh_failure(&e) {
                    SshFailure::Retry => still_pending.push(sock),
                    // The socket still closes — there is nothing to forward it
                    // to — but the log now names the likely cause instead of
                    // leaving the user with a connection that was accepted and
                    // dropped without a word.
                    SshFailure::ForwardSurvives => tracing::warn!(
                        error = %e,
                        remote_port,
                        "ssh forward: the VM refused this connection; is anything listening on the remote port?"
                    ),
                    SshFailure::SessionGone => {
                        tracing::error!(
                            error = %e,
                            remote_port,
                            "ssh forward: the SSH session's transport is gone; shutting the forward down"
                        );
                        session_gone = true;
                        break;
                    }
                },
            }
        }
        pending = still_pending;

        // Leaving the loop drops the listener, so the local port closes and a
        // client gets a clean refusal instead of the silent accept-and-drop
        // that made a dead forward look alive. `is_running()` follows for free:
        // it already asks whether this thread has finished.
        if session_gone {
            break;
        }

        // Pump each live connection both ways.
        for c in &mut conns {
            if pump(c, &mut scratch) {
                did_work = true;
            }
        }
        conns.retain(|c| !c.done);

        // Idle liveness. Without it a transport that dies while nobody is
        // connected is only discovered by the next user who tries the forward.
        // Same verdict, and same exit, as a failed channel open above.
        //
        // NOT COVERED BY ANY TEST — verified by mutation, each left green:
        // - Passing `BlockDirections::None` instead of `sess.block_directions()`.
        //   The pure veto is tested; this wiring is not, because no test can
        //   deterministically leave libssh2 holding a half-sent packet. If you
        //   touch this call, reread `should_send_keepalive` first: without the
        //   real value a keepalive can wedge a saturated upload.
        // - Replacing `keepalive_ends_forward(&e)` below with a looser test of
        //   `e`. The verdict itself is tested; against a live sshd a healthy
        //   keepalive never fails, so nothing exercises a non-fatal error
        //   through this line. Keep the decision in that function.
        // - `set_keepalive(true, ..)` above. want_reply = false is a decision;
        //   with true, replies pile up unread in the socket's receive buffer
        //   for as long as the forward stays idle, and nothing notices.
        if should_send_keepalive(
            &mut keepalive,
            Instant::now(),
            !conns.is_empty(),
            sess.block_directions(),
        ) {
            if let Err(e) = sess.keepalive_send() {
                if keepalive_ends_forward(&e) {
                    tracing::error!(
                        error = %e,
                        remote_port,
                        "ssh forward: an idle keepalive found the SSH session's transport gone; shutting the forward down"
                    );
                    break;
                }
                // Anything else leaves the forward up. The clock bounds this
                // line to one per interval.
                tracing::warn!(error = %e, remote_port, "ssh forward: keepalive failed; keeping the forward up");
            }
        }

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
/// any byte moved on this tick.
///
/// Correctness on non-blocking endpoints (finding 1 & 2):
///   - Writes use `write` (not `write_all`): a partial write / `WouldBlock`
///     leaves the un-accepted tail in the pending buffer for the next tick
///     instead of tearing the connection down and losing the tail.
///   - Reads are gated on the destination buffer being empty (backpressure),
///     which bounds memory to one `scratch` fill per direction and preserves
///     byte order.
///   - EOF is per side: a local (or remote) half-close shuts down only that
///     direction. Local EOF sends `chan.send_eof()` once; channel EOF, once
///     `to_sock` is drained, propagates a write-side FIN to the local socket
///     once (`shutdown(Write)`) so the peer closes and the connection can
///     finish. The connection is `done` only when *both* sides are EOF and
///     *both* pending buffers are drained — or a real (non-`WouldBlock`) write
///     error occurs.
///
/// `scratch` is a reusable read buffer owned by the reactor (finding 4).
fn pump<L: LocalEnd, R: RemoteEnd>(c: &mut Conn<L, R>, scratch: &mut [u8]) -> bool {
    let mut moved = false;

    // 1) Flush pending local -> remote first (drain the accepted prefix).
    if !c.to_chan.is_empty() {
        match c.chan.write(&c.to_chan) {
            Ok(n) if n > 0 => {
                c.to_chan.drain(..n);
                moved = true;
            }
            Ok(_) => {}
            Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(_) => c.done = true,
        }
    }

    // 2) Flush pending remote -> local first.
    if !c.to_sock.is_empty() {
        match c.sock.write(&c.to_sock) {
            Ok(n) if n > 0 => {
                c.to_sock.drain(..n);
                moved = true;
            }
            Ok(_) => {}
            Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(_) => c.done = true,
        }
    }

    // 3) Read local socket -> to_chan, only once its destination buffer is empty.
    if !c.sock_eof && c.to_chan.is_empty() {
        match c.sock.read(scratch) {
            Ok(0) => {
                // Local half-close: signal EOF to the channel once, but keep
                // pumping remote -> local until the channel also reaches EOF.
                let _ = RemoteEnd::send_eof(&mut c.chan);
                c.sock_eof = true;
            }
            Ok(n) => {
                c.to_chan.extend_from_slice(&scratch[..n]);
                moved = true;
            }
            Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(_) => c.sock_eof = true,
        }
    }

    // 4) Read ssh channel -> to_sock, only once its destination buffer is empty.
    if !c.chan_eof && c.to_sock.is_empty() {
        match c.chan.read(scratch) {
            Ok(0) => {
                // Channel half-close: mark EOF, but keep flushing any buffered
                // remote -> local bytes; the FIN is propagated in step 5 only
                // after `to_sock` fully drains.
                c.chan_eof = true;
            }
            Ok(n) => {
                c.to_sock.extend_from_slice(&scratch[..n]);
                moved = true;
            }
            Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(_) => c.chan_eof = true,
        }
    }

    // 5) Propagate channel EOF to the local peer as a write-side FIN, once, and
    // only after every buffered remote byte has reached the socket. This mirrors
    // the local-EOF path (step 3 sends `chan.send_eof()` once): a well-behaved
    // client responds to the FIN by closing its own write half, so `sock.read`
    // then returns `Ok(0)`, `sock_eof` flips, and the connection reaches `done`
    // below — instead of blocking forever in `read` for protocols where the
    // server closes to delimit the response (e.g. HTTP `Connection: close`).
    if c.chan_eof && c.to_sock.is_empty() && !c.sock_fin_sent {
        let _ = LocalEnd::shutdown_write(&mut c.sock);
        c.sock_fin_sent = true;
    }

    // 6) Done only when both directions have fully finished (EOF + drained).
    if c.sock_eof && c.to_chan.is_empty() && c.chan_eof && c.to_sock.is_empty() {
        c.done = true;
    }

    moved
}

#[cfg(test)]
mod failure_tests {
    use super::*;
    use ssh2::ErrorCode;

    fn err(code: i32) -> ssh2::Error {
        ssh2::Error::new(ErrorCode::Session(code), "test")
    }

    /// The zombie this fixes: when the transport under the session dies, every
    /// future channel open fails, but the reactor kept looping and the listener
    /// kept accepting. The user saw a forward that was "up" and forwarded
    /// nothing. These four codes are libssh2 saying the socket is gone.
    #[test]
    fn a_dead_transport_takes_the_whole_forward_down() {
        for code in [SOCKET_NONE, SOCKET_SEND, SOCKET_DISCONNECT, SOCKET_RECV] {
            assert_eq!(
                classify_ssh_failure(&err(code)),
                SshFailure::SessionGone,
                "libssh2 {} means the session's socket is gone",
                code
            );
        }
    }

    /// And the failure that must NOT kill anything: the VM answered and refused
    /// this one channel, which is what happens when nothing listens on the
    /// remote port. Treating it as a dead session would tear down a perfectly
    /// healthy forward every time the user aimed it at a service that had not
    /// started yet.
    #[test]
    fn a_refused_connection_leaves_the_forward_alone() {
        const CHANNEL_FAILURE: i32 = -21;
        assert_eq!(
            classify_ssh_failure(&err(CHANNEL_FAILURE)),
            SshFailure::ForwardSurvives
        );
    }

    /// Unknown codes take the conservative direction. Being wrong here costs
    /// the old behaviour — a forward that stays up — never a healthy forward
    /// torn down by a code nobody has classified yet.
    #[test]
    fn an_unknown_code_does_not_kill_the_forward() {
        assert_eq!(classify_ssh_failure(&err(-999)), SshFailure::ForwardSurvives);
        assert_eq!(
            classify_ssh_failure(&ssh2::Error::new(ErrorCode::SFTP(4), "test")),
            SshFailure::ForwardSurvives
        );
    }

    /// EAGAIN is not a failure at all: libssh2 is mid-handshake and the socket
    /// waits for a later tick. This is the behaviour `is_would_block_ssh` used
    /// to carry on its own.
    #[test]
    fn eagain_still_means_retry_this_socket() {
        assert_eq!(classify_ssh_failure(&err(EAGAIN)), SshFailure::Retry);
    }
}

#[cfg(test)]
mod keepalive_tests {
    use super::*;
    use ssh2::BlockDirections;
    use std::time::{Duration, Instant};

    const EVERY: Duration = Duration::from_secs(15);

    /// The reactor ticks every 2 ms. A clock that said "due" on every tick
    /// would put a packet on the wire 500 times a second on an idle forward.
    #[test]
    fn nothing_is_due_before_a_full_interval_has_passed() {
        let t0 = Instant::now();
        let mut clock = KeepaliveClock::new(t0, EVERY);

        assert!(!clock.due(t0));
        assert!(!clock.due(t0 + Duration::from_millis(2)));
        assert!(!clock.due(t0 + Duration::from_millis(14_999)));
    }

    #[test]
    fn a_keepalive_is_due_exactly_when_the_interval_is_up() {
        let t0 = Instant::now();
        let mut clock = KeepaliveClock::new(t0, EVERY);

        assert!(clock.due(t0 + Duration::from_secs(15)));
    }

    /// Once one goes out, the next waits a whole interval again.
    #[test]
    fn after_firing_the_next_one_waits_another_interval() {
        let t0 = Instant::now();
        let mut clock = KeepaliveClock::new(t0, EVERY);

        assert!(clock.due(t0 + Duration::from_secs(15)));
        assert!(!clock.due(t0 + Duration::from_millis(15_002)));
        assert!(!clock.due(t0 + Duration::from_millis(29_999)));
        assert!(clock.due(t0 + Duration::from_secs(30)));
    }

    /// A keepalive held back for minutes by live traffic fires once when the
    /// forward goes quiet, not once per interval it missed. Rescheduling from
    /// the old deadline instead of from "now" would fire on every 2 ms tick
    /// until it caught up: a burst of twenty keepalives after five minutes of
    /// traffic.
    #[test]
    fn a_late_keepalive_does_not_trigger_a_catch_up_burst() {
        let t0 = Instant::now();
        let mut clock = KeepaliveClock::new(t0, EVERY);
        let late = t0 + Duration::from_secs(300);

        assert!(clock.due(late));
        assert!(!clock.due(late + Duration::from_millis(2)));
        assert!(!clock.due(late + Duration::from_millis(14_999)));
        assert!(clock.due(late + Duration::from_secs(15)));
    }

    /// The whole point: an idle forward, clock up, nothing half-sent.
    #[test]
    fn an_idle_forward_sends_when_the_clock_is_up() {
        let t0 = Instant::now();
        let mut clock = KeepaliveClock::new(t0, EVERY);

        assert!(should_send_keepalive(&mut clock, t0 + EVERY, false, BlockDirections::None));
    }

    /// Inbound-blocked is the normal resting state of an idle session: libssh2
    /// last tried to read and there was nothing to read. It says nothing about
    /// a half-sent packet. Treating it as a veto would mean an idle forward
    /// never sends a keepalive at all — the one case this exists for.
    #[test]
    fn a_session_waiting_to_read_still_gets_its_keepalive() {
        let t0 = Instant::now();
        let mut clock = KeepaliveClock::new(t0, EVERY);

        assert!(should_send_keepalive(&mut clock, t0 + EVERY, false, BlockDirections::Inbound));
    }

    /// See `should_send_keepalive`: a keepalive interleaved with channel
    /// traffic can wedge every later write on a healthy forward.
    #[test]
    fn no_keepalive_while_a_channel_is_open() {
        let t0 = Instant::now();
        let mut clock = KeepaliveClock::new(t0, EVERY);

        assert!(!should_send_keepalive(&mut clock, t0 + EVERY, true, BlockDirections::None));
    }

    /// A packet already half-written means the transport is busy and the
    /// keepalive would only be swallowed; `Both` includes that outbound half.
    #[test]
    fn no_keepalive_while_a_packet_is_half_sent() {
        let t0 = Instant::now();
        for blocked in [BlockDirections::Outbound, BlockDirections::Both] {
            let mut clock = KeepaliveClock::new(t0, EVERY);
            assert!(
                !should_send_keepalive(&mut clock, t0 + EVERY, false, blocked),
                "a pending outbound packet must hold the keepalive back"
            );
        }
    }

    fn err(code: i32) -> ssh2::Error {
        ssh2::Error::new(ssh2::ErrorCode::Session(code), "test")
    }

    /// A failed keepalive ends the forward only when the socket is gone.
    #[test]
    fn a_keepalive_that_hits_a_dead_socket_ends_the_forward() {
        for code in [SOCKET_NONE, SOCKET_SEND, SOCKET_DISCONNECT, SOCKET_RECV] {
            assert!(keepalive_ends_forward(&err(code)), "libssh2 {} means the socket is gone", code);
        }
    }

    /// Everything else leaves a working forward alone — including EAGAIN.
    /// libssh2 swallows EAGAIN inside `keepalive_send` today, but if a future
    /// version surfaced it, "the write would block" on a busy healthy session
    /// must not read as "dead". Nor must a code nobody has classified.
    #[test]
    fn any_other_keepalive_failure_keeps_the_forward_up() {
        const CHANNEL_FAILURE: i32 = -21;
        const KEX_FAILURE: i32 = -5;
        for code in [EAGAIN, CHANNEL_FAILURE, KEX_FAILURE, -999] {
            assert!(!keepalive_ends_forward(&err(code)), "libssh2 {} must not end a forward", code);
        }
    }

    /// Being held back must not spend the slot. If a busy tick consumed the
    /// clock, a forward that is busy whenever the clock comes up would go a
    /// whole extra interval — or indefinitely — without a keepalive.
    #[test]
    fn a_held_back_keepalive_goes_out_on_the_first_quiet_tick() {
        let t0 = Instant::now();
        let mut clock = KeepaliveClock::new(t0, EVERY);
        let up = t0 + EVERY;

        assert!(!should_send_keepalive(&mut clock, up, true, BlockDirections::None));
        assert!(!should_send_keepalive(&mut clock, up, false, BlockDirections::Outbound));
        assert!(should_send_keepalive(
            &mut clock,
            up + Duration::from_millis(2),
            false,
            BlockDirections::None
        ));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};

    /// A local endpoint that hands out queued chunks and accepts only
    /// `accept_per_write` bytes at a time, so partial writes can be forced.
    struct FakeLocal {
        to_read: Vec<Vec<u8>>,
        written: Vec<u8>,
        accept_per_write: usize,
        fin_sent: usize,
    }

    impl FakeLocal {
        fn new(to_read: Vec<Vec<u8>>, accept_per_write: usize) -> Self {
            Self { to_read, written: Vec::new(), accept_per_write, fin_sent: 0 }
        }
    }

    impl Read for FakeLocal {
        fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
            if self.to_read.is_empty() {
                return Err(std::io::Error::new(std::io::ErrorKind::WouldBlock, "nothing queued"));
            }
            let chunk = self.to_read.remove(0);
            let n = chunk.len().min(buf.len());
            buf[..n].copy_from_slice(&chunk[..n]);
            Ok(n)
        }
    }

    impl Write for FakeLocal {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            let n = buf.len().min(self.accept_per_write);
            self.written.extend_from_slice(&buf[..n]);
            Ok(n)
        }
        fn flush(&mut self) -> std::io::Result<()> { Ok(()) }
    }

    impl LocalEnd for FakeLocal {
        fn shutdown_write(&mut self) -> std::io::Result<()> {
            self.fin_sent += 1;
            Ok(())
        }
    }

    /// A remote endpoint with the same shape, plus a count of `send_eof` calls.
    struct FakeRemote {
        to_read: Vec<Vec<u8>>,
        written: Vec<u8>,
        accept_per_write: usize,
        eof_sent: usize,
    }

    impl FakeRemote {
        fn new(to_read: Vec<Vec<u8>>, accept_per_write: usize) -> Self {
            Self { to_read, written: Vec::new(), accept_per_write, eof_sent: 0 }
        }
    }

    impl Read for FakeRemote {
        fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
            if self.to_read.is_empty() {
                return Err(std::io::Error::new(std::io::ErrorKind::WouldBlock, "nothing queued"));
            }
            let chunk = self.to_read.remove(0);
            let n = chunk.len().min(buf.len());
            buf[..n].copy_from_slice(&chunk[..n]);
            Ok(n)
        }
    }

    impl Write for FakeRemote {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            let n = buf.len().min(self.accept_per_write);
            self.written.extend_from_slice(&buf[..n]);
            Ok(n)
        }
        fn flush(&mut self) -> std::io::Result<()> { Ok(()) }
    }

    impl RemoteEnd for FakeRemote {
        fn send_eof(&mut self) -> std::io::Result<()> {
            self.eof_sent += 1;
            Ok(())
        }
    }

    fn conn(sock: FakeLocal, chan: FakeRemote) -> Conn<FakeLocal, FakeRemote> {
        Conn {
            sock,
            chan,
            to_chan: Vec::new(),
            to_sock: Vec::new(),
            sock_eof: false,
            chan_eof: false,
            sock_fin_sent: false,
            done: false,
        }
    }

    /// The property the module's own doc comment claims and nothing verified:
    /// a partial write keeps the un-accepted tail instead of losing it. Without
    /// this, a forward silently corrupts every transfer larger than one write.
    #[test]
    fn a_partial_write_keeps_the_tail_and_flushes_it_next_tick() {
        // The remote accepts 4 bytes per write; 10 bytes arrive from the local side.
        let mut c = conn(
            FakeLocal::new(vec![b"0123456789".to_vec()], 64),
            FakeRemote::new(Vec::new(), 4),
        );
        let mut scratch = [0u8; 32];

        for _ in 0..5 {
            pump(&mut c, &mut scratch);
        }

        assert_eq!(
            c.chan.written, b"0123456789",
            "se perdieron bytes en una escritura parcial: {:?}",
            String::from_utf8_lossy(&c.chan.written)
        );
    }

    /// Backpressure: a source is not read while its destination still holds
    /// unwritten bytes. Without it the pending buffer grows without bound.
    #[test]
    fn a_source_is_not_read_while_its_destination_is_backed_up() {
        // The remote accepts nothing, so `to_chan` can never drain.
        let mut c = conn(
            FakeLocal::new(vec![b"aaaa".to_vec(), b"bbbb".to_vec(), b"cccc".to_vec()], 64),
            FakeRemote::new(Vec::new(), 0),
        );
        let mut scratch = [0u8; 32];

        for _ in 0..5 {
            pump(&mut c, &mut scratch);
        }

        assert_eq!(
            c.to_chan.len(), 4,
            "el buffer creció pese al backpressure: {:?}",
            String::from_utf8_lossy(&c.to_chan)
        );
    }

    /// A local half-close ends ONE direction. The remote must be told once, and
    /// remote -> local traffic must keep flowing: closing both is how a forward
    /// truncates a response the server is still sending.
    #[test]
    fn a_local_half_close_does_not_tear_down_the_other_direction() {
        let mut c = conn(
            FakeLocal::new(vec![Vec::new()], 64),           // immediate EOF
            FakeRemote::new(vec![b"respuesta".to_vec()], 64),
        );
        let mut scratch = [0u8; 32];

        for _ in 0..4 {
            pump(&mut c, &mut scratch);
        }

        assert_eq!(c.chan.eof_sent, 1, "send_eof debe enviarse exactamente una vez");
        assert_eq!(
            c.sock.written, b"respuesta",
            "se perdió el tráfico remoto -> local tras el half-close: {:?}",
            String::from_utf8_lossy(&c.sock.written)
        );
    }
}

/// The reactor against a real `sshd`, through a proxy that stands in for the
/// native IAP relay and can be killed mid-session.
///
/// `#[ignore]` because it needs `/usr/sbin/sshd` and `ssh-keygen`: a test
/// that skipped itself when they are missing would report green having proved
/// nothing. Run it explicitly:
///
/// ```text
/// cargo test --lib ssh_forward::live_sshd_tests -- --ignored --nocapture
/// ```
///
/// The two tests only mean something together. The first alone would pass
/// with a keepalive that killed every forward; the second alone would pass
/// with no keepalive at all.
#[cfg(test)]
mod live_sshd_tests {
    use super::*;
    use std::net::Shutdown;
    use std::path::{Path, PathBuf};
    use std::process::{Child, Command, Stdio};
    use std::sync::atomic::AtomicUsize;
    use std::sync::Mutex;

    /// Short, so the tests take seconds. Not below the libssh2 floor: with
    /// our clock at >= 2 s, libssh2's whole-second gate always agrees.
    const TEST_EVERY: Duration = Duration::from_secs(2);

    fn free_port() -> u16 {
        TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
    }

    /// An unprivileged `sshd` on a high port, in a scratch directory with its
    /// own host key and a single authorised client key.
    struct Sshd {
        child: Child,
        dir: PathBuf,
        port: u16,
        client_key: PathBuf,
    }

    impl Sshd {
        fn start() -> Sshd {
            let dir = std::env::temp_dir().join(format!(
                "lcc-ssh-forward-test-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
            std::fs::create_dir_all(&dir).unwrap();
            let keygen = |name: &str| {
                let status = Command::new("ssh-keygen")
                    .args(["-q", "-t", "ed25519", "-N", "", "-f"])
                    .arg(dir.join(name))
                    .status()
                    .expect("ssh-keygen must be installed to run this test");
                assert!(status.success(), "ssh-keygen failed for {}", name);
            };
            keygen("host_key");
            keygen("client_key");
            std::fs::copy(dir.join("client_key.pub"), dir.join("authorized_keys")).unwrap();

            let port = free_port();
            let config = format!(
                "Port {port}\nListenAddress 127.0.0.1\nHostKey {d}/host_key\n\
                 AuthorizedKeysFile {d}/authorized_keys\nPidFile {d}/sshd.pid\n\
                 StrictModes no\nUsePAM no\nPasswordAuthentication no\n\
                 KbdInteractiveAuthentication no\nPubkeyAuthentication yes\n\
                 AllowTcpForwarding yes\n",
                d = dir.display()
            );
            std::fs::write(dir.join("sshd_config"), config).unwrap();

            let child = Command::new("/usr/sbin/sshd")
                .args(["-D", "-e", "-f"])
                .arg(dir.join("sshd_config"))
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .expect("/usr/sbin/sshd must be installed to run this test");
            let sshd = Sshd { child, client_key: dir.join("client_key"), dir, port };

            let deadline = Instant::now() + Duration::from_secs(10);
            while TcpStream::connect(("127.0.0.1", port)).is_err() {
                assert!(Instant::now() < deadline, "sshd never started listening");
                std::thread::sleep(Duration::from_millis(50));
            }
            sshd
        }
    }

    impl Drop for Sshd {
        fn drop(&mut self) {
            let _ = self.child.kill();
            let _ = self.child.wait();
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }

    /// Stands in for the IAP relay: one accepted connection bridged to sshd.
    /// Killing it closes that connection outright, as `run_session` does when
    /// it gives up on the relay and drops its local `TcpStream`.
    struct KillableProxy {
        port: u16,
        sockets: Arc<Mutex<Vec<TcpStream>>>,
        threads: Arc<Mutex<Vec<JoinHandle<()>>>>,
        /// Bytes that went client -> sshd: the keepalives show up here.
        upstream_bytes: Arc<AtomicUsize>,
    }

    impl KillableProxy {
        fn start(to_port: u16) -> KillableProxy {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let port = listener.local_addr().unwrap().port();
            let sockets = Arc::new(Mutex::new(Vec::new()));
            let threads = Arc::new(Mutex::new(Vec::new()));
            let upstream_bytes = Arc::new(AtomicUsize::new(0));

            let (s, t, up) = (sockets.clone(), threads.clone(), upstream_bytes.clone());
            let acceptor = std::thread::spawn(move || {
                let (client, _) = listener.accept().unwrap();
                let server = TcpStream::connect(("127.0.0.1", to_port)).unwrap();
                s.lock().unwrap().extend([client.try_clone().unwrap(), server.try_clone().unwrap()]);
                let copy = |mut from: TcpStream, mut to: TcpStream, count: Option<Arc<AtomicUsize>>| {
                    std::thread::spawn(move || {
                        let mut buf = [0u8; 16 * 1024];
                        while let Ok(n) = from.read(&mut buf) {
                            if n == 0 || to.write_all(&buf[..n]).is_err() {
                                break;
                            }
                            if let Some(c) = &count {
                                c.fetch_add(n, Ordering::SeqCst);
                            }
                        }
                        let _ = to.shutdown(Shutdown::Both);
                    })
                };
                let a = copy(client.try_clone().unwrap(), server.try_clone().unwrap(), Some(up));
                let b = copy(server, client, None);
                t.lock().unwrap().extend([a, b]);
            });
            threads.lock().unwrap().push(acceptor);
            KillableProxy { port, sockets, threads, upstream_bytes }
        }

        fn upstream_bytes(&self) -> usize {
            self.upstream_bytes.load(Ordering::SeqCst)
        }

        /// Shut both sockets down, then wait until every copy thread has
        /// exited, so that every clone of each socket is dropped and the file
        /// descriptors are really closed — later writes from the SSH side draw
        /// an RST, exactly as against a relay task that went away.
        fn kill(&self) {
            for s in self.sockets.lock().unwrap().drain(..) {
                let _ = s.shutdown(Shutdown::Both);
            }
            loop {
                let next = self.threads.lock().unwrap().pop();
                match next {
                    Some(h) => {
                        let _ = h.join();
                    }
                    None => break,
                }
            }
        }
    }

    struct Reactor {
        local_port: u16,
        shutdown: Arc<AtomicBool>,
        handle: Option<JoinHandle<()>>,
    }

    impl Reactor {
        fn finished(&self) -> bool {
            self.handle.as_ref().map(|h| h.is_finished()).unwrap_or(true)
        }
    }

    impl Drop for Reactor {
        fn drop(&mut self) {
            self.shutdown.store(true, Ordering::Relaxed);
            if let Some(h) = self.handle.take() {
                let _ = h.join();
            }
        }
    }

    /// An authenticated session to `sshd` through `proxy`, handed to the real
    /// reactor exactly as `start` does. The forward targets sshd's own port,
    /// so a working forward answers with sshd's banner.
    fn start_reactor(sshd: &Sshd, proxy: &KillableProxy) -> Reactor {
        let user = std::env::var("USER").expect("USER must be set");
        let sess = crate::ssh_session::create_ssh_session_with_key(
            "127.0.0.1",
            proxy.port,
            &user,
            Path::new(&sshd.client_key),
        )
        .expect("authenticating against the test sshd");
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let local_port = listener.local_addr().unwrap().port();
        let shutdown = Arc::new(AtomicBool::new(false));
        let (flag, remote_port) = (shutdown.clone(), sshd.port);
        let handle = std::thread::spawn(move || {
            run_reactor(sess, listener, remote_port, flag, TEST_EVERY);
        });
        Reactor { local_port, shutdown, handle: Some(handle) }
    }

    fn wait_until_finished(r: &Reactor, within: Duration) -> Option<Duration> {
        let t0 = Instant::now();
        while t0.elapsed() < within {
            if r.finished() {
                return Some(t0.elapsed());
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        None
    }

    /// Nobody connects. The transport dies. The reactor must notice by itself.
    #[test]
    #[ignore = "needs /usr/sbin/sshd and ssh-keygen; run with --ignored"]
    fn an_idle_forward_notices_its_transport_died() {
        let sshd = Sshd::start();
        let proxy = KillableProxy::start(sshd.port);
        let reactor = start_reactor(&sshd, &proxy);

        std::thread::sleep(TEST_EVERY + Duration::from_millis(500));
        assert!(!reactor.finished(), "the forward died before anything went wrong");

        proxy.kill();
        let limit = TEST_EVERY * 3 + Duration::from_secs(2);
        let took = wait_until_finished(&reactor, limit);
        eprintln!("transport killed; reactor finished after {:?} (limit {:?})", took, limit);
        assert!(took.is_some(), "an idle forward over a dead transport kept pretending to be up");
    }

    /// The false-positive guard: a healthy idle forward survives many
    /// keepalives, and still forwards afterwards.
    #[test]
    #[ignore = "needs /usr/sbin/sshd and ssh-keygen; run with --ignored"]
    fn a_healthy_idle_forward_survives_its_keepalives_and_still_forwards() {
        let sshd = Sshd::start();
        let proxy = KillableProxy::start(sshd.port);
        let reactor = start_reactor(&sshd, &proxy);

        let before = proxy.upstream_bytes();
        std::thread::sleep(TEST_EVERY * 4 + Duration::from_millis(500));
        let sent_while_idle = proxy.upstream_bytes() - before;
        eprintln!("bytes sent upstream during 4 idle intervals: {}", sent_while_idle);

        assert!(!reactor.finished(), "a healthy idle forward was torn down");
        assert!(
            sent_while_idle > 0,
            "no keepalive went out while idle, so this test proved nothing"
        );

        let mut client = TcpStream::connect(("127.0.0.1", reactor.local_port)).unwrap();
        client.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut banner = [0u8; 8];
        client.read_exact(&mut banner).expect("the forward did not forward after idling");
        assert_eq!(&banner, b"SSH-2.0-", "expected sshd's banner through the forward");
    }
}
