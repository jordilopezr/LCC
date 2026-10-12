//! Launching external GUI clients without leaving zombies behind.

use std::process::Command;

/// Spawn the command, hand the child to a thread that waits for it, and return its
/// pid without waiting.
///
/// Dropping a `std::process::Child` neither kills nor reaps it: the process
/// runs on, and when it exits it stays in the process table as `<defunct>`
/// until our own process quits. Every client launcher did exactly that, so
/// each RDP or database client the user opened and closed left one zombie
/// under LCC. The waiting thread is the reap; it lives as long as the client
/// does and costs nothing while blocked.
///
/// Not done instead: ignoring SIGCHLD process-wide would reap these for free,
/// but it also breaks `try_wait()`/`wait()` for the children `tunnel.rs`
/// supervises (gcloud), which must be able to see their own exit status.
pub(crate) trait SpawnReaped {
    fn spawn_reaped(&mut self) -> std::io::Result<u32>;
}

impl SpawnReaped for Command {
    fn spawn_reaped(&mut self) -> std::io::Result<u32> {
        let mut child = self.spawn()?;
        let pid = child.id();
        let program = self.get_program().to_string_lossy().into_owned();
        let reaper = std::thread::Builder::new().name(format!("reap-{}", pid)).spawn({
            let program = program.clone();
            move || match child.wait() {
                Ok(status) => tracing::debug!(program, pid, %status, "external client exited"),
                Err(e) => tracing::warn!(program, pid, error = %e, "could not wait for external client"),
            }
        });
        // The client is already running, so this is still a successful launch:
        // an error here would send the launcher on to its next candidate and open
        // a second client next to the first. Only the reap is lost. Not covered
        // by a test — a thread spawn cannot be made to fail on demand.
        if let Err(e) = reaper {
            tracing::warn!(program, pid, error = %e, "no reaper thread; this client will linger as <defunct> after it exits");
        }
        Ok(pid)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    /// The process state letter from `/proc/<pid>/stat`, or `None` once the
    /// pid is gone — which, for our own child, means it was reaped.
    fn proc_state(pid: u32) -> Option<char> {
        let stat = std::fs::read_to_string(format!("/proc/{}/stat", pid)).ok()?;
        // The command name sits in parentheses and may itself contain spaces
        // or parentheses; the state is the first field after the LAST ')'.
        stat.rsplit_once(')')?.1.trim_start().chars().next()
    }

    /// The defect: every client launcher dropped its `Child`, nobody called
    /// `wait()`, and each client that exited stayed as `<defunct>` under LCC
    /// until LCC itself quit — one per RDP or database session opened.
    #[test]
    fn a_client_that_exits_is_reaped_not_left_a_zombie() {
        let pid = Command::new("true").spawn_reaped().expect("spawning true");

        let t0 = Instant::now();
        let mut last = proc_state(pid);
        while last.is_some() && t0.elapsed() < Duration::from_secs(2) {
            std::thread::sleep(Duration::from_millis(10));
            last = proc_state(pid);
        }
        assert_eq!(last, None, "pid {} still in the process table, state {:?}", pid, last);
    }

    /// Reaping must not turn a launch into a wait: the client is a window the
    /// user keeps open for hours, and the launch is called from the UI's
    /// request path.
    #[test]
    fn launching_does_not_wait_for_the_client_to_exit() {
        let t0 = Instant::now();
        let pid = Command::new("sleep").arg("5").spawn_reaped().expect("spawning sleep");
        let took = t0.elapsed();

        let state = proc_state(pid);
        let _ = Command::new("kill").arg(pid.to_string()).status();

        assert!(took < Duration::from_secs(1), "spawn_reaped blocked for {:?}", took);
        assert!(
            matches!(state, Some('S') | Some('R')),
            "the client should still be running, state {:?}",
            state
        );
    }

    /// Launchers fall through to the next candidate (native, then Flatpak)
    /// on a spawn error, so the error must still reach them.
    #[test]
    fn a_client_that_cannot_start_is_still_an_error() {
        assert!(Command::new("/nonexistent/lcc-no-such-client").spawn_reaped().is_err());
    }

    /// Source-level guard for the wiring, which no behavioural test can reach
    /// without the clients installed: no RDP or database launcher may spawn
    /// a client with a bare `.spawn()` again. A new launcher written that way
    /// is exactly how the zombies came back.
    #[test]
    fn no_client_launcher_spawns_without_reaping() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        let mut offenders = Vec::new();
        for dir in ["rdp_client", "db_client", "vnc_client"] {
            for entry in std::fs::read_dir(root.join(dir)).unwrap() {
                let path = entry.unwrap().path();
                if path.extension().and_then(|e| e.to_str()) != Some("rs") {
                    continue;
                }
                let text = std::fs::read_to_string(&path).unwrap();
                for (n, line) in text.lines().enumerate() {
                    let code = line.split("//").next().unwrap_or("");
                    if code.contains(".spawn()") {
                        offenders.push(format!("{}:{}", path.display(), n + 1));
                    }
                }
            }
        }
        assert!(offenders.is_empty(), "client launched without a reaper at:\n{}", offenders.join("\n"));
    }
}
