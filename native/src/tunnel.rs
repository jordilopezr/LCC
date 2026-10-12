use std::process::{Command, Child, ChildStderr, Stdio};
use std::net::{TcpListener, TcpStream};
use anyhow::{Result, anyhow};
use std::sync::Mutex;
use std::collections::HashMap;
use std::time::{Duration, Instant};
use std::io::Read;
use lazy_static::lazy_static;
use tracing;
use crate::validation::{validate_project_id, validate_zone, validate_instance_name, validate_username};

/// Which implementation is serving a tunnel.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TunnelEngine {
    Native,
    Gcloud,
}

impl From<crate::engine_pref::Engine> for TunnelEngine {
    fn from(e: crate::engine_pref::Engine) -> Self {
        match e {
            crate::engine_pref::Engine::Native => TunnelEngine::Native,
            crate::engine_pref::Engine::Gcloud => TunnelEngine::Gcloud,
        }
    }
}

impl From<TunnelEngine> for crate::engine_pref::Engine {
    fn from(e: TunnelEngine) -> Self {
        match e {
            TunnelEngine::Native => crate::engine_pref::Engine::Native,
            TunnelEngine::Gcloud => crate::engine_pref::Engine::Gcloud,
        }
    }
}

impl TunnelEngine {
    /// The engine's name, from the one vocabulary `engine_pref` owns.
    pub fn as_str(self) -> &'static str {
        crate::engine_pref::Engine::from(self).as_str()
    }
}

/// A tunnel or forward that is up, and the engine holding it.
pub struct Started {
    pub local_port: u16,
    pub engine: TunnelEngine,
}

/// A start that failed, and the engine that was trying, if any got that far.
///
/// `None` is the truth for a failure before an engine was chosen — invalid
/// input, a poisoned lock — so the UI names no engine rather than an innocent
/// one. Every `?` on an `anyhow` result converts to `None`; the one place an
/// engine can fail attaches it explicitly, right after the engine is chosen.
///
/// Coverage, precisely: the `None` side is tested (an invalid project), and so
/// is the conversion back to `anyhow`. The two `map_err(|error| StartFailure {
/// engine: Some(engine), error })` — one in `start_tunnel`, one in
/// `start_ssh_forward` — have no test: making an engine fail on purpose needs
/// a relay or a gcloud to fail against. Dropping the engine there (or turning
/// that `map_err` back into a bare `?`, which converts to `None`) compiles and
/// keeps every test green. Whoever edits those two has to read them.
#[derive(Debug)]
pub struct StartFailure {
    pub engine: Option<TunnelEngine>,
    pub error: anyhow::Error,
}

impl From<anyhow::Error> for StartFailure {
    fn from(error: anyhow::Error) -> Self {
        StartFailure { engine: None, error }
    }
}

/// Back to the original error, for callers that only speak `anyhow`
/// (`ssh_access`). It is the error itself, not a wrapper, so a `downcast` to
/// `TunnelError` still finds it.
impl From<StartFailure> for anyhow::Error {
    fn from(failure: StartFailure) -> Self {
        failure.error
    }
}

/// The slot each accessor below resolves. Named so a test can assert the two
/// are distinct and point at the right environment variable, without having
/// to call the accessors (which would mean mutating the process environment
/// to tell them apart — see `sshfs_mount/utils.rs:441`).
const TUNNEL_SLOT: crate::engine_pref::EngineSlot = crate::engine_pref::EngineSlot::Tunnel;
const SSH_FORWARD_SLOT: crate::engine_pref::EngineSlot = crate::engine_pref::EngineSlot::SshForward;

/// Which engine opens IAP tunnels. Native is the default; `gcloud` opts out to
/// the legacy engine. Selectable in Settings under Advanced since SG-E, and
/// still forceable with `LCC_TUNNEL_ENGINE`, which outranks the stored choice.
pub fn tunnel_engine() -> TunnelEngine {
    crate::engine_pref::engine_for(TUNNEL_SLOT).into()
}

/// Which engine opens SSH port forwards. Native is the default since SP-2. The
/// gcloud forward is **kept**, not retired: the 2026-08-21 decision keeps it as
/// a selectable escape hatch for environments the native one cannot serve.
pub fn ssh_forward_engine() -> TunnelEngine {
    crate::engine_pref::engine_for(SSH_FORWARD_SLOT).into()
}

enum Backend {
    Native(crate::iap_tunnel::NativeTunnel),
    Gcloud(Child),
    NativeSshForward(crate::ssh_forward::NativeSshForward),
}

impl Backend {
    /// The engine holding this entry — read off what is actually running, so
    /// it stays right after the selected engine changes.
    ///
    /// Coverage, precisely: only the `Gcloud` arm is exercised by a test
    /// (`a_gcloud_backend_reports_the_gcloud_engine`). The two native arms,
    /// `Backend::Native(_) => TunnelEngine::Native` and
    /// `Backend::NativeSshForward(_) => TunnelEngine::Native`, have no test:
    /// neither backend can be built from this module without a live relay.
    /// The exhaustive match forces a NEW variant to be handled, but nothing
    /// catches one of those two arms being changed to `Gcloud`. Whoever edits
    /// them has to read them.
    fn engine(&self) -> TunnelEngine {
        match self {
            Backend::Native(_) => TunnelEngine::Native,
            Backend::Gcloud(_) => TunnelEngine::Gcloud,
            Backend::NativeSshForward(_) => TunnelEngine::Native,
        }
    }
}

/// The shell wrapper that turns the kernel's parent-death notice into the
/// death of the whole process group.
///
/// `PR_SET_PDEATHSIG` reaches only the direct child. `gcloud` is a wrapper: the
/// process that actually binds the local port is its grandchild. Measured on
/// this machine — parent killed with SIGKILL, no cleanup possible — the direct
/// child died and the grandchild survived, still holding the port. Re-signalling
/// the group from a trap is what closes that gap; `kill 0` names the group this
/// shell leads, which is exactly the tunnel and everything it forked.
///
/// Arguments arrive as `"$@"`, never interpolated into the script text.
#[cfg(unix)]
const DEATH_TRAP: &str = r#"trap 'kill 0' TERM; "$@" & wait"#;

/// Build the command for a child whose life is bound to this process's.
#[cfg(unix)]
fn supervised_command(program: &std::path::Path, args: &[String]) -> Command {
    use std::os::unix::process::CommandExt;

    let parent = std::process::id();
    let mut cmd = Command::new("/bin/sh");
    cmd.arg("-c").arg(DEATH_TRAP).arg("sh").arg(program).args(args);
    cmd.process_group(0);
    // SAFETY: runs between fork and exec, so it may only call async-signal-safe
    // functions. `prctl` and `getppid` are; the `_exit` on the race below is the
    // one legal way out of that window.
    unsafe {
        cmd.pre_exec(move || {
            if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM) != 0 {
                return Err(std::io::Error::last_os_error());
            }
            // The parent can die in the gap between fork and the line above, in
            // which case the notice we just armed will never be sent and this
            // child would outlive the app anyway. Having missed it, leave.
            if libc::getppid() as u32 != parent {
                libc::_exit(1);
            }
            Ok(())
        });
    }
    cmd
}

/// Windows has no parent-death signal; Job Objects are its equivalent and are
/// not wired up. A child there still outlives an abrupt exit.
#[cfg(not(unix))]
fn supervised_command(program: &std::path::Path, args: &[String]) -> Command {
    let mut cmd = Command::new(program);
    cmd.args(args);
    cmd
}

/// Spawn on one long-lived thread, never on the caller's.
///
/// `PR_SET_PDEATHSIG` is documented to fire when *the thread* that forked the
/// child terminates — not when the process does. Tunnels are started from
/// short-lived bridge worker threads, so a child forked on one could be killed
/// seconds after it started. Measured on Linux 6.12 the signal did not arrive
/// on thread exit, but the documented contract is the one that has to hold on
/// every kernel this ships to, and "tunnels die at random" is worth a thread to
/// rule out.
#[cfg(unix)]
fn spawn_supervised(cmd: Command) -> std::io::Result<Child> {
    use std::sync::mpsc::{channel, Sender};
    type Job = (Command, Sender<std::io::Result<Child>>);
    static SPAWNER: std::sync::OnceLock<std::sync::Mutex<Sender<Job>>> = std::sync::OnceLock::new();

    let spawner = SPAWNER.get_or_init(|| {
        let (tx, rx) = channel::<Job>();
        std::thread::Builder::new()
            .name("lcc-child-spawner".to_string())
            .spawn(move || {
                while let Ok((mut cmd, reply)) = rx.recv() {
                    let _ = reply.send(cmd.spawn());
                }
            })
            .expect("the child spawner thread must exist for tunnels to start");
        std::sync::Mutex::new(tx)
    });

    let (reply_tx, reply_rx) = channel();
    spawner
        .lock()
        .map_err(|_| std::io::Error::other("child spawner channel poisoned"))?
        .send((cmd, reply_tx))
        .map_err(|_| std::io::Error::other("child spawner thread is gone"))?;
    reply_rx
        .recv()
        .map_err(|_| std::io::Error::other("child spawner thread died mid-spawn"))?
}

#[cfg(not(unix))]
fn spawn_supervised(mut cmd: Command) -> std::io::Result<Child> {
    cmd.spawn()
}

/// Kill a spawned child together with everything it forked, then reap it.
fn kill_process_group(process: &mut Child) {
    #[cfg(unix)]
    {
        let pid = process.id() as i32;
        // SAFETY: a negative pid signals the whole process group, which is the
        // point. `pid` names our own child, still unreaped (the `wait()` below
        // is the only reap), so the number cannot have been recycled onto an
        // unrelated process. A child that is not a group leader — the
        // `supervised_command` fallback on non-Unix — yields ESRCH here and is
        // killed directly instead.
        if unsafe { libc::kill(-pid, libc::SIGKILL) } != 0 {
            let _ = process.kill();
        }
    }
    #[cfg(not(unix))]
    {
        let _ = process.kill();
    }
    let _ = process.wait();
}

pub struct IapTunnel {
    backend: Backend,
    pub local_port: u16,
    /// Last time an active loopback connection to `local_port` was observed
    /// (set at creation and refreshed by the idle reaper).
    pub last_active: std::time::Instant,
}

impl IapTunnel {
    /// What a start call reports for this entry. Every return path of
    /// `start_tunnel` and `start_ssh_forward` goes through here, including the
    /// one that reuses an existing entry — so the engine reported is always
    /// the entry's own, never whatever is selected right now.
    fn started(&self) -> Started {
        Started { local_port: self.local_port, engine: self.backend.engine() }
    }

    pub fn stop(&mut self) -> Result<()> {
        match &mut self.backend {
            Backend::Native(tunnel) => tunnel.stop(),
            Backend::Gcloud(process) => kill_process_group(process),
            Backend::NativeSshForward(f) => {
                let _ = f.stop();
            }
        }
        Ok(())
    }

    /// Whether the tunnel's engine is still alive.
    pub fn is_process_alive(&mut self) -> bool {
        match &mut self.backend {
            Backend::Native(tunnel) => tunnel.is_running(),
            Backend::Gcloud(process) => matches!(process.try_wait(), Ok(None)),
            Backend::NativeSshForward(f) => f.is_running(),
        }
    }

    /// Whether *somebody* is listening on the local port.
    ///
    /// Not whether that somebody is ours: a successful connect says only that
    /// the port answers. Every caller must pair it with a liveness check on the
    /// engine that is supposed to own the port — see [`wait_for_listener`].
    pub fn is_port_listening(&self) -> bool {
        let addr = format!("127.0.0.1:{}", self.local_port);
        // Try to connect to the port
        // Note: parse() should never fail for "127.0.0.1:port" format, but we handle it gracefully
        match addr.parse() {
            Ok(socket_addr) => TcpStream::connect_timeout(&socket_addr, Duration::from_millis(500)).is_ok(),
            Err(e) => {
                tracing::error!(
                    address = %addr,
                    error = %e,
                    "Failed to parse socket address (unexpected error)"
                );
                false
            }
        }
    }

    /// Comprehensive health check
    pub fn is_healthy(&mut self) -> bool {
        self.is_process_alive() && self.is_port_listening()
    }
}

lazy_static! {
    static ref TUNNELS: Mutex<HashMap<String, IapTunnel>> = Mutex::new(HashMap::new());
}

/// Creates a unique key for tunnel identification: "instance:port"
fn make_tunnel_key(instance: &str, remote_port: u16) -> String {
    format!("{}:{}", instance, remote_port)
}

/// TUNNELS key for an SSH port-forward, distinct from IAP tunnels so both can
/// coexist for the same instance:port.
fn make_ssh_forward_key(instance: &str, remote_port: u16) -> String {
    format!("sshfwd:{}:{}", instance, remote_port)
}

/// gcloud args for an IAP-tunneled SSH local port forward
/// (`-L <local>:localhost:<remote> -N`). Pure, for testability.
fn ssh_forward_args(instance: &str, zone: &str, project: &str, local: u16, remote: u16) -> Vec<String> {
    vec![
        "compute".to_string(),
        "ssh".to_string(),
        instance.to_string(),
        "--tunnel-through-iap".to_string(),
        format!("--zone={}", zone),
        format!("--project={}", project),
        "--".to_string(),
        "-L".to_string(),
        format!("{}:localhost:{}", local, remote),
        "-N".to_string(),
    ]
}

pub fn start_tunnel(project: &str, zone: &str, instance: &str, remote_port: u16, local_port: Option<u16>) -> Result<Started, StartFailure> {
    // SECURITY: Validate all inputs before passing to gcloud command
    validate_project_id(project)?;
    validate_zone(zone)?;
    validate_instance_name(instance)?;

    // Scope para el lock
    {
        let tunnel_key = make_tunnel_key(instance, remote_port);
        let mut tunnels = TUNNELS.lock().map_err(|_| anyhow!("Tunnel lock poisoned"))?;
        if let Some(tunnel) = tunnels.get_mut(&tunnel_key) {
            tracing::info!(
                instance = instance,
                remote_port = remote_port,
                local_port = tunnel.local_port,
                "Tunnel already exists, returning existing local port"
            );
            // Refresh the idle timer: a caller reusing this tunnel is active
            // "now", even if the tunnel had gone quiet for a while. Without
            // this, a reconnect on a stale-but-not-yet-reaped tunnel could
            // race the reaper (see security/loopback-listener finding #2).
            tunnel.last_active = Instant::now();
            return Ok(tunnel.started());
        }
    }

    // Native is the default IAP-tunnel engine. `gcloud compute start-iap-tunnel`
    // is reachable only as an explicit opt-out via LCC_TUNNEL_ENGINE=gcloud. A
    // native failure surfaces as a tunnel error (no silent fallback).
    // Resolved once: the engine that is tried is the engine a failure names.
    let engine = tunnel_engine();
    let tunnel = match engine {
        TunnelEngine::Native => start_native(project, zone, instance, remote_port, local_port),
        TunnelEngine::Gcloud => start_gcloud(project, zone, instance, remote_port, local_port),
    }
    .map_err(|error| StartFailure { engine: Some(engine), error })?;
    let started = tunnel.started();
    let mut tunnels = TUNNELS.lock().map_err(|_| anyhow!("Tunnel lock poisoned"))?;
    tunnels.insert(make_tunnel_key(instance, remote_port), tunnel);
    drop(tunnels); // release the lock before (idempotently) starting the reaper
    start_reaper_once();
    tracing::info!(instance, remote_port, local_port = started.local_port, engine = started.engine.as_str(), "Tunnel established");
    Ok(started)
}

/// Start the native engine on the shared tokio runtime.
fn start_native(project: &str, zone: &str, instance: &str, remote_port: u16, local_port: Option<u16>) -> Result<IapTunnel> {
    let target = crate::iap_tunnel::TunnelTarget::new(project, zone, instance, remote_port);
    let native = crate::logging::block_on(crate::iap_tunnel::start(target, local_port))
        .map_err(anyhow::Error::new)?;
    Ok(IapTunnel { local_port: native.local_port, backend: Backend::Native(native), last_active: std::time::Instant::now() })
}

/// Keep the last `max_lines` lines of `s`, then cap to `max_chars` characters
/// (keeping the tail, where gcloud's actual error usually is). Used to embed a
/// bounded slice of gcloud's stderr in tunnel errors.
fn truncate_stderr(s: &str, max_lines: usize, max_chars: usize) -> String {
    let trimmed = s.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    let lines: Vec<&str> = trimmed.lines().collect();
    let start = lines.len().saturating_sub(max_lines);
    let tail = lines[start..].join("\n");
    if tail.chars().count() > max_chars {
        let kept: String = {
            let mut chars: Vec<char> = tail.chars().collect();
            chars = chars.split_off(chars.len() - max_chars);
            chars.into_iter().collect()
        };
        format!("…{}", kept)
    } else {
        tail
    }
}

/// Drain a (dead) child's stderr into a bounded string. Only call after the
/// process has exited or been killed, so `read_to_string` returns promptly.
fn drain_stderr(handle: Option<ChildStderr>) -> String {
    match handle {
        Some(mut h) => {
            let mut buf = String::new();
            let _ = h.read_to_string(&mut buf);
            truncate_stderr(&buf, 15, 2048)
        }
        None => String::new(),
    }
}

/// How a wait for the local listener ended.
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
enum WaitOutcome {
    /// The port answers and the engine that should own it is still alive.
    Listening,
    /// The engine exited before the port ever answered.
    Exited,
    /// The engine is alive but never bound the port in the time allowed.
    TimedOut,
}

impl WaitOutcome {
    /// Wording for the log line and the error, so the two failures stop reading
    /// alike: "gcloud died" and "gcloud is still trying" need different answers
    /// from whoever reads the report.
    fn reason(self) -> &'static str {
        match self {
            WaitOutcome::Listening => "is listening",
            WaitOutcome::Exited => "exited",
            WaitOutcome::TimedOut => "timed out",
        }
    }
}

/// Wait for the tunnel's local port, refusing to call a dead engine's port ours.
///
/// `is_port_listening` answers "somebody is listening here", not "our child is".
/// The two come apart exactly when it matters: the engine dies during startup
/// while an unrelated process — a forward orphaned by an earlier run, say —
/// holds the same port. Reported as an established tunnel, that points the
/// user's RDP or VNC client, credentials and all, at a stranger's listener.
/// Asking after the engine first is what keeps them apart: a dead engine's port
/// is never ours, whoever is answering on it.
///
/// What this still does not verify: that a listener found while the engine is
/// alive belongs to the engine. The port was proven free immediately before the
/// spawn (`ensure_local_port_available`), so a foreign listener would have to
/// win a race measured in milliseconds. Closing that last gap means matching
/// the socket's inode in `/proc/net/tcp` to a pid in the child's process group,
/// which is not done here.
fn wait_for_listener(tunnel: &mut IapTunnel, attempts: u32, interval: Duration) -> WaitOutcome {
    for _ in 0..attempts {
        if !tunnel.is_process_alive() {
            return WaitOutcome::Exited;
        }
        if tunnel.is_port_listening() {
            return WaitOutcome::Listening;
        }
        std::thread::sleep(interval);
    }
    WaitOutcome::TimedOut
}

/// Legacy engine: spawn `gcloud compute start-iap-tunnel` and wait for the port.
fn start_gcloud(project: &str, zone: &str, instance: &str, remote_port: u16, local_port: Option<u16>) -> Result<IapTunnel> {
    let port = match local_port {
        Some(p) => { ensure_local_port_available(p)?; p }
        None => get_free_port()?,
    };
    let args: Vec<String> = vec![
        "compute".to_string(),
        "start-iap-tunnel".to_string(),
        instance.to_string(),
        remote_port.to_string(),
        format!("--local-host-port=localhost:{}", port),
        "--zone".to_string(), zone.to_string(),
        "--project".to_string(), project.to_string(),
    ];
    let mut cmd = supervised_command(&crate::gcloud_bin::gcloud_path()?, &args);
    cmd.stdout(Stdio::null()).stderr(Stdio::piped());
    let mut child = spawn_supervised(cmd)
        .map_err(|e| anyhow!("Failed to spawn gcloud tunnel: {}", e))?;

    let mut stderr_handle = child.stderr.take();

    let mut tunnel = IapTunnel { local_port: port, backend: Backend::Gcloud(child), last_active: std::time::Instant::now() };
    std::thread::sleep(Duration::from_millis(1000));
    if !tunnel.is_process_alive() {
        // Process died: it is dead, so its stderr can be drained safely.
        let stderr = drain_stderr(stderr_handle.take());
        tracing::error!(
            instance,
            remote_port,
            local_port = port,
            stderr = %describe_stderr(&stderr),
            "gcloud tunnel exited before it could listen"
        );
        return Err(anyhow!("gcloud tunnel failed: {}", stderr));
    }
    let outcome = wait_for_listener(&mut tunnel, 20, Duration::from_millis(500));
    if outcome == WaitOutcome::Listening {
        // Reattach the stderr pipe to the still-running child. Otherwise the
        // taken handle would drop here and close the read end while gcloud
        // keeps running for the tunnel's lifetime — a closed pipe risks
        // SIGPIPE killing an otherwise-healthy tunnel.
        if let Backend::Gcloud(ref mut c) = tunnel.backend {
            c.stderr = stderr_handle.take();
        }
        return Ok(tunnel);
    }
    let _ = tunnel.stop(); // kill the process before draining its stderr
    let stderr = drain_stderr(stderr_handle.take());
    tracing::error!(
        instance,
        remote_port,
        local_port = port,
        seconds = 10,
        reason = outcome.reason(),
        stderr = %describe_stderr(&stderr),
        "gcloud tunnel never listened on the local port"
    );
    Err(anyhow!("gcloud tunnel {} (port {} never listened): {}", outcome.reason(), port, stderr))
}

/// Spawn the managed gcloud-ssh forward child, mirroring `start_gcloud`.
fn spawn_ssh_forward(project: &str, zone: &str, instance: &str, remote_port: u16, local_port: Option<u16>) -> Result<IapTunnel> {
    let local = match local_port {
        Some(p) => { ensure_local_port_available(p)?; p }
        None => get_free_port()?,
    };
    let args = ssh_forward_args(instance, zone, project, local, remote_port);
    let mut cmd = supervised_command(&crate::gcloud_bin::gcloud_path()?, &args);
    cmd.stdout(Stdio::null()).stderr(Stdio::piped());
    let mut child = spawn_supervised(cmd)
        .map_err(|e| anyhow!("Failed to spawn gcloud ssh: {}", e))?;

    let mut stderr_handle = child.stderr.take();
    let mut tunnel = IapTunnel { local_port: local, backend: Backend::Gcloud(child), last_active: std::time::Instant::now() };
    std::thread::sleep(Duration::from_millis(1000));
    if !tunnel.is_process_alive() {
        let stderr = drain_stderr(stderr_handle.take());
        tracing::error!(
            instance,
            remote_port,
            local_port = local,
            stderr = %describe_stderr(&stderr),
            "gcloud ssh forward exited before it could listen"
        );
        return Err(anyhow!("ssh forward failed: {}", stderr));
    }
    // gcloud ssh may provision keys / do a first connection: allow up to ~20s.
    let outcome = wait_for_listener(&mut tunnel, 40, Duration::from_millis(500));
    if outcome == WaitOutcome::Listening {
        if let Backend::Gcloud(ref mut c) = tunnel.backend {
            c.stderr = stderr_handle.take();
        }
        return Ok(tunnel);
    }
    let _ = tunnel.stop();
    let stderr = drain_stderr(stderr_handle.take());
    tracing::error!(
        instance,
        remote_port,
        local_port = local,
        seconds = 20,
        reason = outcome.reason(),
        stderr = %describe_stderr(&stderr),
        "gcloud ssh forward never listened on the local port"
    );
    Err(anyhow!("ssh forward {} (port {} never listened): {}", outcome.reason(), local, stderr))
}

/// Render a child's drained stderr for a log line.
///
/// Says so explicitly when there was nothing, because "the pipe was empty" and
/// "nobody captured the pipe" look identical in a log otherwise — and an empty
/// stderr from a gcloud failure is itself a finding worth being able to state.
/// Redacted: gcloud's own diagnostics can echo tokens.
fn describe_stderr(stderr: &str) -> String {
    if stderr.trim().is_empty() {
        return "(empty)".to_string();
    }
    crate::redact::redact_sensitive(stderr)
}

/// Start (or reuse) an SSH port-forward. Registered in TUNNELS under a
/// `sshfwd:` key; the idle reaper reaps it like any tunnel.
///
/// `username` is only consulted by the native engine: `spawn_ssh_forward`
/// shells out to `gcloud compute ssh`, which resolves its own login identity
/// the same way `gcloud` always has. The native engine has no such fallback,
/// so it authenticates as exactly the account the caller resolved via
/// `ssh_access::probe_ssh_access` / `provision_ssh_access` — on an OS Login VM
/// that is not `$USER`.
pub fn start_ssh_forward(project: &str, zone: &str, instance: &str, remote_port: u16, local_port: Option<u16>, username: &str, identity_file: Option<&str>) -> Result<Started, StartFailure> {
    validate_project_id(project)?;
    validate_zone(zone)?;
    validate_instance_name(instance)?;
    validate_username(username)?;
    let key = make_ssh_forward_key(instance, remote_port);
    {
        let mut tunnels = TUNNELS.lock().map_err(|_| anyhow!("Tunnel lock poisoned"))?;
        if let Some(t) = tunnels.get_mut(&key) {
            t.last_active = Instant::now();
            return Ok(t.started());
        }
    }
    // Resolved once: the engine that is tried is the engine a failure names.
    let engine = ssh_forward_engine();
    let tunnel = match engine {
        TunnelEngine::Native => crate::ssh_forward::start(project, zone, instance, remote_port, local_port, username, identity_file)
            .map(|f| IapTunnel {
                local_port: f.local_port(),
                backend: Backend::NativeSshForward(f),
                last_active: Instant::now(),
            }),
        TunnelEngine::Gcloud => spawn_ssh_forward(project, zone, instance, remote_port, local_port),
    }
    .map_err(|error| StartFailure { engine: Some(engine), error })?;
    let started = tunnel.started();
    let mut tunnels = TUNNELS.lock().map_err(|_| anyhow!("Tunnel lock poisoned"))?;
    tunnels.insert(key, tunnel);
    drop(tunnels);
    start_reaper_once();
    // The engine belongs in this line: the two forwards are indistinguishable
    // from the UI and from every other log line, and that ambiguity has already
    // sent two debugging sessions down the wrong path.
    tracing::info!(
        instance,
        remote_port,
        local_port = started.local_port,
        engine = started.engine.as_str(),
        "SSH forward established"
    );
    Ok(started)
}

/// Stop an SSH port-forward.
pub fn stop_ssh_forward(instance: &str, remote_port: u16) -> Result<()> {
    let key = make_ssh_forward_key(instance, remote_port);
    let mut tunnels = TUNNELS.lock().map_err(|_| anyhow!("Tunnel lock poisoned"))?;
    if let Some(mut tunnel) = tunnels.remove(&key) {
        tracing::info!(instance, remote_port, local_port = tunnel.local_port, "Stopping SSH forward");
        tunnel.stop()?;
    }
    Ok(())
}

pub fn stop_tunnel(instance: &str, remote_port: u16) -> Result<()> {
    let tunnel_key = make_tunnel_key(instance, remote_port);
    let mut tunnels = TUNNELS.lock().map_err(|_| anyhow!("Tunnel lock poisoned"))?;
    if let Some(mut tunnel) = tunnels.remove(&tunnel_key) {
        tracing::info!(
            instance = instance,
            remote_port = remote_port,
            local_port = tunnel.local_port,
            "Stopping tunnel"
        );
        tunnel.stop()?;
    } else {
        tracing::warn!(
            instance = instance,
            remote_port = remote_port,
            "Attempted to stop non-existent tunnel"
        );
    }
    Ok(())
}

/// Check if a tunnel is healthy (process alive + port listening)
/// Returns true if healthy, false if dead/unhealthy, error if tunnel doesn't exist
pub fn check_tunnel_health(instance: &str, remote_port: u16) -> Result<bool> {
    let tunnel_key = make_tunnel_key(instance, remote_port);
    let mut tunnels = TUNNELS.lock().map_err(|_| anyhow!("Tunnel lock poisoned"))?;

    if let Some(tunnel) = tunnels.get_mut(&tunnel_key) {
        let is_healthy = tunnel.is_healthy();

        // If unhealthy, automatically clean up the dead tunnel
        if !is_healthy {
            tracing::warn!(
                instance = instance,
                remote_port = remote_port,
                "Tunnel is unhealthy - process died or port stopped listening"
            );
            // We can't remove while holding the reference, so we'll mark it for removal
            // by dropping the tunnel. The caller should call stop_tunnel to clean up.
        }

        Ok(is_healthy)
    } else {
        Err(anyhow!("No tunnel exists for instance '{}' on port {}", instance, remote_port))
    }
}

/// Measure tunnel latency by performing a TCP connect to the local port.
/// Returns the round-trip time in milliseconds.
pub fn measure_tunnel_latency(instance: &str, remote_port: u16) -> Result<u64> {
    let tunnel_key = make_tunnel_key(instance, remote_port);
    let tunnels = TUNNELS.lock().map_err(|_| anyhow!("Tunnel lock poisoned"))?;

    let tunnel = tunnels.get(&tunnel_key)
        .ok_or_else(|| anyhow!("No tunnel exists for key '{}'", tunnel_key))?;

    let addr = format!("127.0.0.1:{}", tunnel.local_port);
    let socket_addr: std::net::SocketAddr = addr.parse()
        .map_err(|e| anyhow!("Failed to parse address: {}", e))?;

    let start = Instant::now();
    match TcpStream::connect_timeout(&socket_addr, Duration::from_millis(2000)) {
        Ok(_stream) => {
            let elapsed = start.elapsed();
            Ok(elapsed.as_millis() as u64)
        }
        Err(e) => Err(anyhow!("Latency measurement failed: {}", e)),
    }
}

/// Iterate all tunnels, remove dead ones (process exited), return the keys that were cleaned up.
pub fn cleanup_dead_tunnels() -> Result<Vec<String>> {
    let mut tunnels = TUNNELS.lock().map_err(|_| anyhow!("Tunnel lock poisoned"))?;
    let mut dead_keys = Vec::new();

    // First pass: identify dead tunnels
    for (key, tunnel) in tunnels.iter_mut() {
        if !tunnel.is_process_alive() {
            dead_keys.push(key.clone());
        }
    }

    // Second pass: remove and stop dead tunnels
    for key in &dead_keys {
        if let Some(mut tunnel) = tunnels.remove(key) {
            tracing::info!(key = %key, "Cleaning up dead tunnel");
            let _ = tunnel.stop();
        }
    }

    if !dead_keys.is_empty() {
        tracing::info!(count = dead_keys.len(), "Cleaned up dead tunnels");
    }

    Ok(dead_keys)
}

// SECURITY NOTE (H2 — TOCTOU, accepted risk):
// There is a theoretical race between releasing the ephemeral port here and gcloud
// binding to it. On Linux the window is microseconds on localhost and practically
// unexploitable for a single-user desktop app.
// Residual mitigation: the 10-second port_listening health check (lines ~130-143)
// in start_tunnel() would catch any case where the port is not actually serving
// IAP traffic after gcloud starts. No external attack surface exists here.
pub(crate) fn get_free_port() -> Result<u16> {
    // Port 0 in the error means "no ephemeral port at all", which the UI words
    // differently from "port N is taken". See `tunnelErrorMessage` in Dart.
    let listener = TcpListener::bind("127.0.0.1:0")
        .map_err(|e| port_unavailable(0, &e))?;
    let port = listener.local_addr().map_err(|e| port_unavailable(0, &e))?.port();
    Ok(port)
}

/// Build the typed error for a local port that could not be bound.
///
/// The OS message goes to the log, not into the error: what crosses the bridge
/// is the code plus the port, and Dart turns that pair into the sentence the
/// user reads.
fn port_unavailable(port: u16, e: &std::io::Error) -> anyhow::Error {
    tracing::warn!(port, error = %e, "local port could not be bound");
    anyhow::Error::new(crate::iap_tunnel::TunnelError::LocalPortUnavailable { port })
}

/// Pre-bind a specific local port to fail fast with a clean message when it is
/// occupied or privileged, before spawning gcloud. Same brief TOCTOU window as
/// get_free_port (bind, drop, then the child rebinds).
pub(crate) fn ensure_local_port_available(port: u16) -> Result<()> {
    match TcpListener::bind(("127.0.0.1", port)) {
        Ok(_) => Ok(()),
        Err(e) => Err(port_unavailable(port, &e)),
    }
}

/// Refreshes a tunnel's idle timer by its local port. Called by an attached UI
/// (e.g. the SFTP browser) to "pin" a tunnel that is genuinely in use even when
/// no TCP connection is currently established. No-op if no tunnel matches.
pub fn touch_tunnel_by_local_port(local_port: u16) {
    if let Ok(mut tunnels) = TUNNELS.lock() {
        for tunnel in tunnels.values_mut() {
            if tunnel.local_port == local_port {
                tunnel.last_active = Instant::now();
            }
        }
    }
}

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

#[cfg(test)]
mod stderr_tests {
    use super::truncate_stderr;

    #[test]
    fn short_stderr_is_unchanged() {
        assert_eq!(truncate_stderr("boom\n", 15, 2048), "boom");
    }

    #[test]
    fn keeps_only_last_lines() {
        let s = (1..=20).map(|i| format!("line{}", i)).collect::<Vec<_>>().join("\n");
        let out = truncate_stderr(&s, 3, 2048);
        assert_eq!(out, "line18\nline19\nline20");
    }

    #[test]
    fn truncates_overlong_tail_with_ellipsis() {
        let s = "x".repeat(5000);
        let out = truncate_stderr(&s, 15, 100);
        assert!(out.chars().count() <= 101); // 100 + leading ellipsis
        assert!(out.starts_with('…'));
    }

    #[test]
    fn empty_stays_empty() {
        assert_eq!(truncate_stderr("   ", 15, 2048), "");
    }
}

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

    // Covers the reap PATH (reap_idle_tunnels_once), which the predicate tests
    // above do not. A real Backend::Native needs a running relay engine, so a
    // Backend::Gcloud wrapping a dummy long-lived child stands in for the
    // backend process; native port-release is verified by manual QA (Task 3).
    // The assertion only inspects this test's own unique key, so it is robust
    // to any other tunnels that may be present in the shared TUNNELS map.
    #[test]
    fn reap_removes_idle_tunnel_with_no_active_connection() {
        use std::process::Command;
        let child = Command::new("sleep").arg("60").spawn().expect("spawn sleep");
        let key = "reaper-integration-test-instance:1".to_string();
        // Port 1: never bound here, so read_proc_net_tcp will not see it active.
        let tunnel = IapTunnel {
            backend: Backend::Gcloud(child),
            local_port: 1,
            last_active: Instant::now() - Duration::from_secs(3600),
        };
        TUNNELS.lock().unwrap().insert(key.clone(), tunnel);
        reap_idle_tunnels_once();
        assert!(
            !TUNNELS.lock().unwrap().contains_key(&key),
            "idle tunnel with no active connection should have been reaped"
        );
    }

    /// The leak this fixes: `gcloud compute ssh` forks the real `ssh` that
    /// holds the `-L` forward, and `stop()` used to kill only the direct
    /// child. The reaper then dropped the registry entry while the orphaned
    /// `ssh` kept the local port bound — observed in the wild as a port still
    /// in use minutes after "Reaping idle tunnel". A shell that backgrounds a
    /// `sleep` has the same parent/grandchild shape.
    #[test]
    fn stopping_a_gcloud_backend_kills_the_grandchild_too() {
        let (child, grandchild) = tree_that_announces_its_grandchild();

        let mut tunnel = IapTunnel {
            backend: Backend::Gcloud(child),
            local_port: 1,
            last_active: Instant::now(),
        };
        tunnel.stop().expect("stop");

        // SIGKILL delivery and reparented-orphan reaping are asynchronous, so
        // poll rather than assert on the first look.
        let deadline = Instant::now() + Duration::from_secs(5);
        while alive(grandchild) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(50));
        }
        assert!(
            !alive(grandchild),
            "grandchild {} survived stop(): it would keep holding the local port",
            grandchild
        );
    }

    /// The confusion this removes: a port that answers is not proof the tunnel
    /// is up. Here the engine is already dead and an unrelated listener — the
    /// shape of a forward orphaned by an earlier run — is holding the same
    /// port. Called established, it would hand an RDP or VNC client, and the
    /// credentials it sends, to a stranger's socket.
    #[test]
    fn a_dead_engine_is_not_rescued_by_a_strangers_listener() {
        let stranger = std::net::TcpListener::bind("127.0.0.1:0").expect("bind stranger");
        let port = stranger.local_addr().unwrap().port();

        let args = vec!["-c".to_string(), "exit 0".to_string()];
        let cmd = supervised_command(std::path::Path::new("/bin/sh"), &args);
        let child = spawn_supervised(cmd).expect("spawn sh");
        let mut tunnel = IapTunnel {
            backend: Backend::Gcloud(child),
            local_port: port,
            last_active: Instant::now(),
        };
        // Let the child exit before the wait begins; the point is the verdict,
        // not the timing of the reap.
        std::thread::sleep(Duration::from_millis(300));

        assert_eq!(
            wait_for_listener(&mut tunnel, 4, Duration::from_millis(50)),
            WaitOutcome::Exited,
            "a listener on the port must not stand in for an engine that died"
        );
    }

    /// An engine that is alive but never binds must be told apart from one that
    /// died: the log and the error say which, and only this path waits out the
    /// full allowance.
    #[test]
    fn a_live_engine_that_never_binds_times_out() {
        let free = std::net::TcpListener::bind("127.0.0.1:0").expect("probe");
        let port = free.local_addr().unwrap().port();
        drop(free); // nobody is listening there now

        let args = vec!["-c".to_string(), "sleep 5".to_string()];
        let cmd = supervised_command(std::path::Path::new("/bin/sh"), &args);
        let child = spawn_supervised(cmd).expect("spawn sh");
        let mut tunnel = IapTunnel {
            backend: Backend::Gcloud(child),
            local_port: port,
            last_active: Instant::now(),
        };

        let outcome = wait_for_listener(&mut tunnel, 3, Duration::from_millis(50));
        let _ = tunnel.stop();
        assert_eq!(outcome, WaitOutcome::TimedOut);
        assert_eq!(outcome.reason(), "timed out");
    }

    /// And the happy path still reports success: engine alive, port answering.
    #[test]
    fn a_live_engine_with_an_answering_port_is_ready() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let port = listener.local_addr().unwrap().port();

        let args = vec!["-c".to_string(), "sleep 5".to_string()];
        let cmd = supervised_command(std::path::Path::new("/bin/sh"), &args);
        let child = spawn_supervised(cmd).expect("spawn sh");
        let mut tunnel = IapTunnel {
            backend: Backend::Gcloud(child),
            local_port: port,
            last_active: Instant::now(),
        };

        let outcome = wait_for_listener(&mut tunnel, 4, Duration::from_millis(50));
        let _ = tunnel.stop();
        assert_eq!(outcome, WaitOutcome::Listening);
    }

    /// Signal 0 performs the existence check without delivering anything.
    fn alive(pid: i32) -> bool {
        unsafe { libc::kill(pid, 0) == 0 }
    }

    /// Spawn a supervised `sh` that backgrounds a `sleep` and prints its pid —
    /// the same parent/grandchild shape as `gcloud` forking the real `ssh`.
    /// Returns the direct child and the grandchild's pid.
    fn tree_that_announces_its_grandchild() -> (Child, i32) {
        use std::io::BufRead;

        let args = vec!["-c".to_string(), "sleep 60 & echo $!; wait".to_string()];
        let mut cmd = supervised_command(std::path::Path::new("/bin/sh"), &args);
        cmd.stdout(Stdio::piped());
        let mut child = spawn_supervised(cmd).expect("spawn supervised sh");

        let mut line = String::new();
        std::io::BufReader::new(child.stdout.take().expect("piped stdout"))
            .read_line(&mut line)
            .expect("read grandchild pid");
        let grandchild: i32 = line.trim().parse().expect("grandchild pid");
        (child, grandchild)
    }

    /// The leak that survives every cleanup path: when the app dies abruptly —
    /// SIGKILL, a segfault, the undiagnosed exit seen on 2026-09-08 — no code
    /// of ours runs, so `stop()` never happens and the forward keeps the local
    /// port bound. The kernel's answer is `PR_SET_PDEATHSIG`, but it reaches
    /// only the direct child, and the port belongs to the grandchild. This is
    /// the half that closes it: the notice arrives as SIGTERM at the direct
    /// child, and the trap turns it into the death of the whole group.
    ///
    /// What this does NOT cover: that the notice is armed at all. That is
    /// `the_parent_death_signal_is_actually_armed` below, and the one line of
    /// `pre_exec` wiring between them is read, not tested — a child process
    /// cannot report its own `PR_GET_PDEATHSIG` back here without a test
    /// binary to run.
    #[test]
    fn the_parent_death_notice_takes_the_whole_group_down() {
        let (mut child, grandchild) = tree_that_announces_its_grandchild();

        // Exactly what the kernel delivers when the parent dies.
        unsafe { libc::kill(child.id() as i32, libc::SIGTERM) };

        let deadline = Instant::now() + Duration::from_secs(5);
        while alive(grandchild) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(50));
        }
        let survived = alive(grandchild);
        let _ = child.wait();
        if survived {
            unsafe { libc::kill(grandchild, libc::SIGKILL) };
        }
        assert!(
            !survived,
            "grandchild {} outlived the parent-death notice: it would keep holding the local port",
            grandchild
        );
    }

    /// The other half: the notice is armed on the child, with SIGTERM, which
    /// is the signal the trap above is written to catch. Arming it on this
    /// process is the only way to read it back — `PR_GET_PDEATHSIG` answers
    /// only about the caller — so it is restored before returning.
    #[test]
    fn the_parent_death_signal_is_actually_armed() {
        let mut armed: libc::c_int = -1;
        unsafe {
            assert_eq!(libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM), 0);
            assert_eq!(libc::prctl(libc::PR_GET_PDEATHSIG, &mut armed), 0);
            libc::prctl(libc::PR_SET_PDEATHSIG, 0);
        }
        assert_eq!(
            armed,
            libc::SIGTERM,
            "the death notice must arrive as SIGTERM: the shim's trap catches nothing else"
        );
    }
}

#[cfg(test)]
mod engine_tests {
    use super::*;

    /// Las dos ranuras nuevas pasan por el mismo sitio que la de auth. Si
    /// alguna volviera a leer el entorno por su cuenta, el selector de Ajustes
    /// no la alcanzaría y el radio se movería sin efecto.
    ///
    /// What this catches: `TUNNEL_SLOT` and `SSH_FORWARD_SLOT` naming the same
    /// slot, or either constant pointing at the wrong environment variable —
    /// e.g. the two constants swapped, or `SSH_FORWARD_SLOT` accidentally
    /// redefined as `EngineSlot::Tunnel`.
    ///
    /// What this does NOT catch: `tunnel_engine()` or `ssh_forward_engine()`
    /// being wired to the wrong constant (say, `ssh_forward_engine()` calling
    /// `engine_for(TUNNEL_SLOT)`). Both constants would still be distinct and
    /// correctly named, so this test would stay green. Telling that apart
    /// would mean observing which environment variable each accessor actually
    /// reads, and this suite does not mutate `std::env` for tests — see
    /// `sshfs_mount/utils.rs:441`, "env::set_var es global al proceso y rompe
    /// los tests". That wiring is guarded only by reading the two three-line
    /// accessor bodies above.
    #[test]
    fn the_two_tunnel_slots_are_distinct_and_correctly_named() {
        use crate::engine_pref::Engine;
        assert_eq!(TunnelEngine::from(Engine::Gcloud), TunnelEngine::Gcloud);
        assert_eq!(TunnelEngine::from(Engine::Native), TunnelEngine::Native);
        assert_ne!(TUNNEL_SLOT, SSH_FORWARD_SLOT);
        assert_eq!(TUNNEL_SLOT.env_var(), "LCC_TUNNEL_ENGINE");
        assert_eq!(SSH_FORWARD_SLOT.env_var(), "LCC_SSH_FORWARD_ENGINE");
    }

    /// El gestor de túneles pinta el motor que devuelve el start, y ese motor
    /// sale del backend de la entrada. Un proceso de gcloud tiene que decir
    /// gcloud, o la etiqueta mandaría a mirar el motor que no es.
    #[test]
    fn a_gcloud_backend_reports_the_gcloud_engine() {
        let child = std::process::Command::new("sleep").arg("60").spawn().expect("spawn sleep");
        let mut tunnel = IapTunnel { backend: Backend::Gcloud(child), local_port: 1, last_active: Instant::now() };
        let started = tunnel.started();
        let _ = tunnel.stop();
        assert_eq!(started.engine, TunnelEngine::Gcloud);
        assert_eq!(started.local_port, 1);
    }

    /// El nombre del motor que cruza al puente es el mismo que escribe el log
    /// y que se pone en LCC_TUNNEL_ENGINE: un solo vocabulario.
    #[test]
    fn a_tunnel_engine_is_named_in_the_shared_vocabulary() {
        assert_eq!(TunnelEngine::Native.as_str(), "native");
        assert_eq!(TunnelEngine::Gcloud.as_str(), "gcloud");
    }

    /// Reutilizar una entrada no resuelve nada: devuelve el puerto de la
    /// entrada, y el motor tiene que ser también el de la entrada, no el que
    /// esté seleccionado ahora. Desde D5 el motor cambia en caliente, así que
    /// los dos pueden no coincidir.
    ///
    /// Lo que esto detecta: un camino de reutilización que se invente el
    /// motor (p. ej. `TunnelEngine::Native` fijo) en lugar de leerlo de la
    /// entrada, en túneles y en reenvíos.
    ///
    /// Lo que NO detecta por sí solo: que el camino de reutilización lea el
    /// resolutor (`tunnel_engine()` / `ssh_forward_engine()`) en vez de la
    /// entrada. Solo se puede insertar una entrada Gcloud (ver abajo), así que
    /// si el resolutor de esta máquina también dice gcloud —el engine.json de
    /// quien corre los tests lo decide, y esta suite no muta `std::env`—, las
    /// dos lecturas dan lo mismo y el test sigue verde. Lo que lo cierra es la
    /// construcción: los tres caminos de retorno de `start_tunnel` y
    /// `start_ssh_forward` devuelven `tunnel.started()` y ninguno toca el
    /// resolutor después de elegir el backend.
    #[test]
    fn reusing_an_entry_reports_the_engine_of_the_entry() {
        let instance = "engine-reuse-test-instance";
        for (key, is_forward) in [
            (make_tunnel_key(instance, 4242), false),
            (make_ssh_forward_key(instance, 4242), true),
        ] {
            let child = std::process::Command::new("sleep").arg("60").spawn().expect("spawn sleep");
            let tunnel = IapTunnel { backend: Backend::Gcloud(child), local_port: 1, last_active: Instant::now() };
            TUNNELS.lock().unwrap().insert(key.clone(), tunnel);

            let started = if is_forward {
                start_ssh_forward("test-project-123", "us-central1-a", instance, 4242, None, "tester", None)
            } else {
                start_tunnel("test-project-123", "us-central1-a", instance, 4242, None)
            };

            if let Some(mut tunnel) = TUNNELS.lock().unwrap().remove(&key) {
                let _ = tunnel.stop();
            }
            let started = started.expect("reusing an existing entry cannot fail");
            assert_eq!(started.local_port, 1, "{key}");
            assert_eq!(started.engine, TunnelEngine::Gcloud, "{key}");
        }
    }

    /// Un fallo antes de elegir motor (aquí, un proyecto inválido) no puede
    /// culpar a ninguno: ninguno llegó a correr. La fila en error se queda
    /// sin etiqueta en vez de señalar un motor inocente.
    #[test]
    fn a_failure_before_any_engine_runs_names_no_engine() {
        let tunnel = start_tunnel("NOT A PROJECT", "us-central1-a", "vm", 22, None)
            .err()
            .expect("an invalid project cannot start a tunnel");
        assert_eq!(tunnel.engine, None);
        let forward = start_ssh_forward("NOT A PROJECT", "us-central1-a", "vm", 22, None, "tester", None)
            .err()
            .expect("an invalid project cannot start a forward");
        assert_eq!(forward.engine, None);
    }

    /// ssh_access llama a start_tunnel con `?` sobre anyhow. Al convertir, el
    /// error tiene que seguir siendo el original, o el `downcast` a
    /// `TunnelError` que traduce el fallo en la UI deja de encontrarlo.
    #[test]
    fn a_start_failure_converts_back_to_the_original_error() {
        let failure = StartFailure {
            engine: Some(TunnelEngine::Native),
            error: anyhow::Error::new(crate::iap_tunnel::TunnelError::LocalPortUnavailable { port: 8443 }),
        };
        let error: anyhow::Error = failure.into();
        assert!(matches!(
            error.downcast_ref::<crate::iap_tunnel::TunnelError>(),
            Some(crate::iap_tunnel::TunnelError::LocalPortUnavailable { port: 8443 })
        ));
    }
}

#[cfg(test)]
mod ssh_forward_tests {
    use super::{ssh_forward_args, make_ssh_forward_key};

    #[test]
    fn args_have_tunnel_through_iap_and_L_and_N() {
        let args = ssh_forward_args("vm1", "us-central1-a", "proj", 5000, 8443);
        assert_eq!(
            args,
            vec![
                "compute", "ssh", "vm1",
                "--tunnel-through-iap",
                "--zone=us-central1-a",
                "--project=proj",
                "--",
                "-L", "5000:localhost:8443",
                "-N",
            ]
        );
    }

    #[test]
    fn ssh_forward_key_is_prefixed() {
        assert_eq!(make_ssh_forward_key("vm1", 8443), "sshfwd:vm1:8443");
    }
}

#[cfg(test)]
mod local_port_tests {

    #[test]
    fn ensure_local_port_available_ok_for_free_port() {
        let probe = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = probe.local_addr().unwrap().port();
        drop(probe);
        assert!(super::ensure_local_port_available(port).is_ok());
    }

    #[test]
    fn ensure_local_port_available_errs_when_taken() {
        let _held = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = _held.local_addr().unwrap().port();
        assert!(super::ensure_local_port_available(port).is_err());
    }

    /// A busy local port must cross the bridge as a typed error carrying the
    /// port, not as prose. Untyped, `api::start_connection` and
    /// `api::start_ssh_forward` both fall back to `protocol_error`, and the
    /// user is told the IAP relay answered strangely when in truth something
    /// on their own machine already holds the port — which is what a leftover
    /// forward process looks like.
    #[test]
    fn a_taken_local_port_is_typed_so_the_ui_can_name_it() {
        let held = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = held.local_addr().unwrap().port();
        let err = super::ensure_local_port_available(port).unwrap_err();
        let typed = err
            .downcast_ref::<crate::iap_tunnel::TunnelError>()
            .expect("a busy local port must be a TunnelError, not a bare anyhow message");
        assert_eq!(typed.code(), "local_port_unavailable");
        assert_eq!(typed.detail(), Some(port.to_string()));
    }
}
