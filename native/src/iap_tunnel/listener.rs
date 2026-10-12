//! Local TCP listener that bridges accepted connections to IAP relay sessions.

use crate::gcp_rest_client::GcpAuthClient;
use crate::iap_tunnel::error::TunnelError;
use crate::iap_tunnel::session::{probe, run_session, TunnelTarget};
use std::future::Future;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::watch;
use tokio::task::JoinSet;

pub struct NativeTunnel {
    pub local_port: u16,
    shutdown: watch::Sender<bool>,
    handle: tokio::task::JoinHandle<()>,
}

impl NativeTunnel {
    /// Stop accepting AND cut every session that is live right now.
    ///
    /// Sessions belong to the accept loop's own `JoinSet`, so aborting the
    /// loop drops the set and the set aborts them all: each local socket is
    /// closed under its client and each relay WebSocket is dropped.
    ///
    /// It used to leave live sessions running until their client closed. LCC
    /// never closes Remmina or the VNC viewer on disconnect, so that meant an
    /// authenticated path to the VM that outlived the order to close it,
    /// indefinitely, with no tunnel entry or sweep left that could see it. It
    /// also made the same "disconnect" mean two things: the gcloud engine has
    /// always cut its sessions (SIGKILL to the process group).
    ///
    /// The cut is abrupt: the relay sees its TCP connection drop, not a
    /// WebSocket Close frame — the same thing it sees when gcloud is killed.
    /// Whether Google releases the VM side of the session as promptly for a
    /// dropped connection as for a Close frame cannot be measured locally. If
    /// sessions are ever seen lingering on the VM after a disconnect, the fix
    /// is to have `pump` watch the shutdown signal and send the Close frame
    /// itself (bounded by a short timeout), keeping this abort as the fallback
    /// for the token, connect and resume phases.
    pub fn stop(&self) {
        let _ = self.shutdown.send(true);
        self.handle.abort();
    }

    pub fn is_running(&self) -> bool {
        !self.handle.is_finished() && !*self.shutdown.borrow()
    }
}

/// Bind a local port, probe the relay, and start accepting. Returns once the
/// socket is listening AND a throwaway probe connection has proven that a
/// real session would succeed (auth, permission, firewall, VM reachability) —
/// mirroring gcloud's own start-iap-tunnel validation before it prints
/// "Listening". If the probe fails, the (already-bound) listener is dropped,
/// freeing the port, and the probe's typed error is returned so callers such
/// as `tunnel.rs::start_native` can fall back to gcloud.
///
/// Cost: the first tunnel open now makes a probe connection to the relay in
/// addition to the real per-client connection. This matches gcloud's own
/// behavior and is the whole point of the fix — session failures that used
/// to be silently logged from inside a spawned per-connection task now
/// surface before `start` returns.
pub async fn start(target: TunnelTarget, local_port: Option<u16>) -> Result<NativeTunnel, TunnelError> {
    let listener = bind_local_port(local_port).await?;
    let local_port = listener
        .local_addr()
        .map_err(|_| TunnelError::LocalPortUnavailable { port: 0 })?
        .port();

    let token = fetch_token().await?;
    if let Err(err) = probe(&target, &token).await {
        // The caller turns this into an opaque anyhow error and the UI shows a
        // generic "tunnel could not be established", so this is the only place
        // the failure is attributable to a target and a cause.
        tracing::error!(
            code = err.code(),
            detail = ?err.detail(),
            project = %target.project,
            zone = %target.zone,
            instance = %target.instance,
            remote_port = target.remote_port,
            "native IAP tunnel probe failed"
        );
        return Err(err);
    }

    tracing::info!(
        project = %target.project,
        instance = %target.instance,
        remote_port = target.remote_port,
        local_port,
        "native IAP tunnel probe succeeded"
    );
    Ok(spawn_accept_loop(target, listener, local_port))
}

async fn bind_local_port(local_port: Option<u16>) -> Result<TcpListener, TunnelError> {
    let requested = local_port.unwrap_or(0);
    TcpListener::bind(("127.0.0.1", requested))
        .await
        .map_err(|_| TunnelError::LocalPortUnavailable { port: requested })
}

/// Bind a local port and start accepting WITHOUT the eager relay probe.
///
/// Only used by tests: the probe requires a live relay, real credentials and
/// a real GCP instance to succeed, none of which are available in a unit
/// test sandbox. Production code always goes through [`start`], which
/// probes before spawning the accept loop.
#[cfg(test)]
async fn start_without_probe(target: TunnelTarget) -> Result<NativeTunnel, TunnelError> {
    let listener = bind_local_port(None).await?;
    let local_port = listener
        .local_addr()
        .map_err(|_| TunnelError::LocalPortUnavailable { port: 0 })?
        .port();
    Ok(spawn_accept_loop(target, listener, local_port))
}

fn spawn_accept_loop(target: TunnelTarget, listener: TcpListener, local_port: u16) -> NativeTunnel {
    spawn_accept_loop_with(listener, local_port, move |socket| serve_connection(target.clone(), socket))
}

/// The accept loop, with what to do for each accepted socket passed in, so
/// the loop's own lifecycle can be exercised without a token or a relay.
fn spawn_accept_loop_with<F, Fut>(listener: TcpListener, local_port: u16, serve: F) -> NativeTunnel
where
    F: Fn(TcpStream) -> Fut + Send + 'static,
    Fut: Future<Output = ()> + Send + 'static,
{
    let (shutdown, mut rx) = watch::channel(false);

    let handle = tokio::spawn(async move {
        // Owned by this task, so the sessions die with it: `stop()` aborts
        // this task, which drops the set, which aborts every session in it.
        // The `break` below ends up in the same place.
        let mut sessions: JoinSet<()> = JoinSet::new();
        loop {
            let accepted = tokio::select! {
                _ = rx.changed() => break,
                // Reap finished sessions so the set does not grow for the
                // tunnel's whole lifetime. NOT COVERED BY ANY TEST (checked by
                // mutation): deleting this arm leaves every test green, since
                // an unreaped set is only a slow leak of one entry per
                // finished connection, invisible from outside. The
                // `is_empty` guard is not load-bearing either: on an empty
                // set `join_next` yields `None`, which `select!` treats as a
                // disabled arm; the guard just skips that pointless poll.
                Some(_) = sessions.join_next(), if !sessions.is_empty() => continue,
                accepted = listener.accept() => accepted,
            };
            let (socket, _peer) = match accepted {
                Ok(pair) => pair,
                Err(e) => {
                    tracing::warn!(error = %e, "accept failed on native tunnel");
                    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                    continue;
                }
            };

            sessions.spawn(serve(socket));
        }
    });

    NativeTunnel { local_port, shutdown, handle }
}

/// One accepted local connection: a fresh token, then a relay session until
/// either side closes.
async fn serve_connection(target: TunnelTarget, socket: TcpStream) {
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
}

async fn fetch_token() -> Result<String, TunnelError> {
    let client = GcpAuthClient::get_or_init().map_err(|_| TunnelError::NotAuthenticated)?;
    client
        .get_access_token()
        .await
        .map_err(|_| TunnelError::NotAuthenticated)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpStream as StdTcpStream;

    // These exercise the bind/accept-loop mechanics only. `start` itself now
    // also probes the relay (auth + permission + firewall + VM reachability)
    // before returning, which needs a live relay and a real GCP instance —
    // neither available in a unit test sandbox. `start_without_probe` skips
    // just the probe step; everything else (bind, accept loop, shutdown) is
    // identical to production code.
    #[tokio::test]
    async fn start_binds_a_local_port_immediately() {
        let target = TunnelTarget::new("p", "z", "vm", 22);
        let tunnel = start_without_probe(target).await.expect("listener starts");
        assert!(tunnel.local_port > 0);
        // The port must accept connections right away — no sleep/poll needed.
        StdTcpStream::connect(("127.0.0.1", tunnel.local_port))
            .expect("local port accepts connections");
        assert!(tunnel.is_running());
        tunnel.stop();
    }

    #[tokio::test]
    async fn stop_marks_the_tunnel_not_running() {
        let tunnel = start_without_probe(TunnelTarget::new("p", "z", "vm", 22))
            .await
            .expect("listener starts");
        tunnel.stop();
        // Give the accept loop a tick to observe the shutdown signal.
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        assert!(!tunnel.is_running());
    }

    #[tokio::test]
    async fn bind_local_port_honors_a_specific_free_port() {
        let probe = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = probe.local_addr().unwrap().port();
        drop(probe);
        let listener = super::bind_local_port(Some(port)).await.unwrap();
        assert_eq!(listener.local_addr().unwrap().port(), port);
    }

    #[tokio::test]
    async fn bind_local_port_reports_unavailable_when_taken() {
        let held = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = held.local_addr().unwrap().port();
        let err = super::bind_local_port(Some(port)).await.unwrap_err();
        assert!(matches!(err, TunnelError::LocalPortUnavailable { port: p } if p == port));
    }

    use crate::iap_tunnel::session::test_relay::serve_with_echo_relay;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use std::time::{Duration, Instant};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    /// A tunnel whose every accepted socket is served by the real `pump`
    /// against `echo_relay`. One flag per session, in accept order, flips
    /// when that session's relay WebSocket ends.
    async fn echo_tunnel() -> (NativeTunnel, Arc<std::sync::Mutex<Vec<Arc<AtomicBool>>>>) {
        let listener = bind_local_port(None).await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let flags: Arc<std::sync::Mutex<Vec<Arc<AtomicBool>>>> = Arc::default();
        let registry = flags.clone();
        let tunnel = spawn_accept_loop_with(listener, port, move |socket| {
            let closed = Arc::new(AtomicBool::new(false));
            registry.lock().unwrap().push(closed.clone());
            serve_with_echo_relay(socket, closed)
        });
        (tunnel, flags)
    }

    async fn echoes(app: &mut TcpStream, msg: &[u8]) -> bool {
        if app.write_all(msg).await.is_err() {
            return false;
        }
        let mut buf = vec![0u8; msg.len()];
        matches!(
            tokio::time::timeout(Duration::from_secs(2), app.read_exact(&mut buf)).await,
            Ok(Ok(_))
        ) && buf == msg
    }

    async fn wait_for(flag: &AtomicBool, within: Duration) -> bool {
        let t0 = Instant::now();
        while !flag.load(Ordering::SeqCst) {
            if t0.elapsed() > within {
                return false;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        true
    }

    /// The defect: "disconnect" stopped accepting but left every live session
    /// forwarding, its relay WebSocket open, for as long as the client kept its
    /// socket — and LCC never closes Remmina or the VNC viewer, so that was
    /// indefinitely, with no tunnel entry left to show for it. The gcloud
    /// engine already cut them (SIGKILL to the process group).
    #[tokio::test(flavor = "multi_thread")]
    async fn stop_cuts_the_sessions_that_are_live() {
        let (tunnel, relay_closed) = echo_tunnel().await;
        let mut app = TcpStream::connect(("127.0.0.1", tunnel.local_port)).await.unwrap();
        assert!(echoes(&mut app, b"hola").await, "the session never worked");

        tunnel.stop();

        let closed = relay_closed.lock().unwrap()[0].clone();
        assert!(
            wait_for(&closed, Duration::from_secs(2)).await,
            "the relay WebSocket stayed open after stop()"
        );
        assert!(
            !echoes(&mut app, b"tras-stop").await,
            "the session kept forwarding after stop()"
        );
    }

    /// The other direction: while the tunnel runs, one client leaving must
    /// not take anyone else's session with it.
    #[tokio::test(flavor = "multi_thread")]
    async fn one_client_leaving_does_not_end_the_other_sessions() {
        let (tunnel, relay_closed) = echo_tunnel().await;
        let mut first = TcpStream::connect(("127.0.0.1", tunnel.local_port)).await.unwrap();
        let mut second = TcpStream::connect(("127.0.0.1", tunnel.local_port)).await.unwrap();
        assert!(echoes(&mut first, b"uno").await);
        assert!(echoes(&mut second, b"dos").await);

        drop(first);
        let first_closed = relay_closed.lock().unwrap()[0].clone();
        assert!(wait_for(&first_closed, Duration::from_secs(2)).await, "the first session never ended");
        // Give the accept loop time to notice the finished session.
        tokio::time::sleep(Duration::from_millis(100)).await;

        assert!(echoes(&mut second, b"sigo").await, "the second session died with the first");
        assert!(tunnel.is_running());
        tunnel.stop();
    }
}
