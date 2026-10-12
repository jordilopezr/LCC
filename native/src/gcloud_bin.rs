//! Resolves the `gcloud` executable to a validated absolute path so a malicious
//! `gcloud` planted earlier on $PATH (CWE-426) cannot run in place of the real
//! Google Cloud SDK binary.

use anyhow::{anyhow, Result};
use std::path::{Path, PathBuf};

const BIN_NAME: &str = "gcloud";

/// Well-known SDK/system locations checked BEFORE $PATH, so a system install is
/// preferred over a $PATH-injected binary.
const KNOWN_DIRS: &[&str] = &[
    "/usr/lib/google-cloud-sdk/bin",
    "/usr/local/google-cloud-sdk/bin",
    "/snap/bin",
    "/usr/bin",
    "/usr/local/bin",
    "/opt/homebrew/bin",
    "/opt/homebrew/share/google-cloud-sdk/bin",
];

/// A candidate is valid if, after resolving symlinks, it is a regular file with
/// an executable bit set and its containing directory is not world-writable
/// (unless sticky, like /tmp) — a planted-binary indicator.
fn is_valid_executable(p: &Path) -> bool {
    let canon = match std::fs::canonicalize(p) {
        Ok(c) => c,
        Err(_) => return false,
    };
    let meta = match std::fs::metadata(&canon) {
        Ok(m) => m,
        Err(_) => return false,
    };
    if !meta.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if meta.permissions().mode() & 0o111 == 0 {
            return false;
        }
        // Reject any world-writable parent directory. There is no legitimate
        // reason for the gcloud binary to live in one, and the sticky bit
        // (e.g. /tmp, mode 1777) only prevents cross-user deletion — it gives
        // NO binary-trust guarantee, so a planted `/tmp/gcloud` must not pass.
        if let Some(dir) = canon.parent() {
            if let Ok(dmeta) = std::fs::metadata(dir) {
                if dmeta.permissions().mode() & 0o002 != 0 {
                    return false;
                }
            }
        }
    }
    true
}

fn resolve() -> Result<PathBuf> {
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Some(home) = dirs::home_dir() {
        candidates.push(home.join("google-cloud-sdk").join("bin").join(BIN_NAME));
    }
    for d in KNOWN_DIRS {
        candidates.push(Path::new(d).join(BIN_NAME));
    }
    if let Some(path) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&path) {
            candidates.push(dir.join(BIN_NAME));
        }
    }
    for c in candidates {
        if is_valid_executable(&c) {
            return std::fs::canonicalize(&c)
                .map_err(|e| anyhow!("Failed to canonicalize gcloud path {}: {}", c.display(), e));
        }
    }
    Err(anyhow!(
        "Could not find a valid 'gcloud' executable. Install the Google Cloud SDK \
         and ensure 'gcloud' is on PATH or in a standard location."
    ))
}

/// Absolute, validated path to the `gcloud` executable. Resolves each call
/// (cheap: a handful of stat calls; negligible next to spawning a process), so
/// it recovers if gcloud is installed later in the session.
pub fn gcloud_path() -> Result<PathBuf> {
    resolve()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_missing_and_nonexecutable_paths() {
        assert!(!is_valid_executable(Path::new("/nonexistent/gcloud")));
        // A regular non-executable temp file is rejected.
        let tmp = std::env::temp_dir().join(format!("lcc_gtest_{}", std::process::id()));
        std::fs::write(&tmp, b"x").unwrap();
        assert!(!is_valid_executable(&tmp));
        std::fs::remove_file(&tmp).ok();
    }

    #[test]
    fn accepts_a_real_executable_via_known_or_path() {
        // /bin/sh is a real executable in a system dir; validate the predicate
        // accepts it (proves is_valid_executable works on a genuine binary).
        assert!(is_valid_executable(Path::new("/bin/sh")));
    }

    #[cfg(unix)]
    #[test]
    fn rejects_executable_in_world_writable_dir_even_if_sticky() {
        use std::os::unix::fs::PermissionsExt;
        // Simulate a planted binary in a world-writable, sticky dir (like /tmp,
        // mode 1777): it must be rejected — the sticky bit must NOT excuse it.
        let dir = std::env::temp_dir()
            .join(format!("lcc_ww_{}_{}", std::process::id(), "sticky"));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o1777)).unwrap();
        let bin = dir.join("gcloud");
        std::fs::write(&bin, b"#!/bin/sh\n").unwrap();
        std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert!(!is_valid_executable(&bin), "planted binary in a 1777 dir must be rejected");
        std::fs::remove_file(&bin).ok();
        std::fs::remove_dir(&dir).ok();
    }
}
