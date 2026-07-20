//! Local TCP listener that bridges accepted connections to IAP relay sessions.

use crate::gcp_rest_client::GcpAuthClient;
use crate::iap_tunnel::error::TunnelError;
use crate::iap_tunnel::session::{probe, run_session, TunnelTarget};
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
pub async fn start(target: TunnelTarget) -> Result<NativeTunnel, TunnelError> {
    let listener = bind_local_port().await?;
    let local_port = listener
        .local_addr()
        .map_err(|_| TunnelError::LocalPortUnavailable { port: 0 })?
        .port();

    let token = fetch_token().await?;
    probe(&target, &token).await?;

    Ok(spawn_accept_loop(target, listener, local_port))
}

async fn bind_local_port() -> Result<TcpListener, TunnelError> {
    TcpListener::bind("127.0.0.1:0")
        .await
        .map_err(|_| TunnelError::LocalPortUnavailable { port: 0 })
}

/// Bind a local port and start accepting WITHOUT the eager relay probe.
///
/// Only used by tests: the probe requires a live relay, real credentials and
/// a real GCP instance to succeed, none of which are available in a unit
/// test sandbox. Production code always goes through [`start`], which
/// probes before spawning the accept loop.
#[cfg(test)]
async fn start_without_probe(target: TunnelTarget) -> Result<NativeTunnel, TunnelError> {
    let listener = bind_local_port().await?;
    let local_port = listener
        .local_addr()
        .map_err(|_| TunnelError::LocalPortUnavailable { port: 0 })?
        .port();
    Ok(spawn_accept_loop(target, listener, local_port))
}

fn spawn_accept_loop(target: TunnelTarget, listener: TcpListener, local_port: u16) -> NativeTunnel {
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
                    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
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

    NativeTunnel { local_port, shutdown, handle }
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
}
