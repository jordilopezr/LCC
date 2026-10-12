use anyhow::anyhow;
use ssh2::Session;
use std::net::TcpStream;
use std::path::{Path, PathBuf};

/// Key files to offer, in order: the user's own first, then the one gcloud
/// provisions, then LCC's own.
///
/// `google_compute_engine` is what `gcloud compute ssh` generates and pushes to
/// the VM, so anyone arriving from gcloud already has it authorised — trying it
/// is what lets them connect without provisioning anything. It comes after the
/// user's own keys, which they chose.
///
/// LCC's key lives in the app's data directory rather than `~/.ssh`, so it
/// cannot be found by name like the others — without it in this list, a key
/// LCC has just authorised on a VM would never be presented to it. It goes
/// last: it is the fallback of last resort, tried only once everything the
/// user already had fails.
///
/// Pure and takes no side effect: existence is checked by the caller, not
/// here, so this stays testable without touching the filesystem.
pub(crate) fn candidate_key_paths(ssh_dir: &Path, lcc_key: Option<PathBuf>) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = ["id_ed25519", "id_ecdsa", "id_rsa", "google_compute_engine"]
        .iter()
        .map(|name| ssh_dir.join(name))
        .collect();
    if let Some(key) = lcc_key {
        out.push(key);
    }
    out
}

/// Open a TCP connection to `host:port` (the local end of the IAP tunnel) and
/// complete the SSH handshake. No authentication yet — shared by every entry
/// point below, so the two never drift into two copies of the same setup.
fn connect_and_handshake(host: &str, port: u16) -> anyhow::Result<Session> {
    let tcp = TcpStream::connect(format!("{}:{}", host, port))
        .map_err(|e| anyhow!("Failed to connect to SSH server: {}", e))?;

    let mut sess = Session::new()
        .map_err(|e| anyhow!("Failed to create SSH session: {}", e))?;

    sess.set_tcp_stream(tcp);
    sess.handshake()
        .map_err(|e| anyhow!("SSH handshake failed: {}", e))?;

    Ok(sess)
}

/// A session plus the credential that actually authenticated it.
///
/// The credential is the point: `create_ssh_session` walks a ladder of
/// candidates, and until now it threw away which rung worked. Every later
/// session — SFTP, the native forward, the `ssh(1)` the terminal spawns —
/// then had to re-derive it from scratch, which is how a key LCC had just
/// authorised could still fail to be presented (LCC's key is not in `~/.ssh`,
/// so `ssh(1)` cannot find it by name) or be reached only after `sshd`'s
/// default `MaxAuthTries` budget of 6 was already spent on other identities.
pub(crate) struct AuthenticatedSession {
    pub session: Session,
    /// The key FILE that authenticated, when one did. `None` means the SSH
    /// agent authenticated, in which case there is no path to carry forward
    /// and every other entry point should simply use the agent too.
    pub key_path: Option<PathBuf>,
}

/// Create SSH session and authenticate, reporting which key file worked.
///
/// The ladder itself is unchanged — the user's own keys still win over
/// LCC's. What is new is that the winner is reported, so the caller can
/// present exactly that credential everywhere else instead of making every
/// subsequent session re-run the ladder.
pub(crate) fn create_ssh_session_reporting_key(
    host: &str,
    port: u16,
    username: &str,
) -> anyhow::Result<AuthenticatedSession> {
    tracing::info!(
        host = host,
        port = port,
        username = username,
        "Creating SSH session"
    );

    let sess = connect_and_handshake(host, port)?;

    // Try multiple authentication methods and accumulate errors for better diagnostics
    let mut auth_errors = Vec::new();
    let mut authenticated_with: Option<PathBuf> = None;

    // Try SSH agent authentication first (most common for GCP)
    if let Err(e) = sess.userauth_agent(username) {
        let error_msg = format!("SSH agent: {}", e);
        tracing::warn!(error = %error_msg, "SSH agent authentication failed");
        auth_errors.push(error_msg);

        // Try default SSH keys as fallback. Prefer modern key types and fall
        // back to RSA, so users whose only key is ed25519/ecdsa can still auth.
        let home = dirs::home_dir()
            .ok_or_else(|| anyhow!("Could not determine home directory"))?;
        let ssh_dir = home.join(".ssh");
        // LCC's own key is offered here too when it exists: `key_path` only
        // computes the location, it never generates key material, so a login
        // attempt stays free of that side effect.
        let candidates = candidate_key_paths(&ssh_dir, crate::ssh_keys::key_path().ok());
        let existing: Vec<PathBuf> = candidates.iter().cloned().filter(|p| p.exists()).collect();

        if existing.is_empty() {
            // Lists every path tried, LCC's included — a message that omitted
            // it would send a user hunting in `~/.ssh` for a key that isn't
            // there.
            auth_errors.push(format!(
                "No SSH key file found (tried {})",
                candidates
                    .iter()
                    .map(|p| p.display().to_string())
                    .collect::<Vec<_>>()
                    .join(", ")
            ));

            return Err(anyhow!(
                "All SSH authentication methods failed:\n  • {}\n\n\
                Please either:\n\
                  1. Start ssh-agent and add your key: ssh-add ~/.ssh/id_ed25519\n\
                  2. Create an SSH key pair: ssh-keygen -t ed25519\n\
                  3. Ensure your public key is in the remote server's ~/.ssh/authorized_keys",
                auth_errors.join("\n  • ")
            ));
        }

        // Try each available key until one authenticates.
        for key_path in &existing {
            match sess.userauth_pubkey_file(username, None, key_path, None) {
                Ok(()) => {
                    authenticated_with = Some(key_path.clone());
                    break;
                }
                Err(e) => {
                    auth_errors.push(format!("SSH key file ({}): {}", key_path.display(), e));
                }
            }
        }

        if authenticated_with.is_none() {
            return Err(anyhow!(
                "All SSH authentication methods failed:\n  • {}\n\n\
                Troubleshooting:\n\
                  • Check that your public key is in ~/.ssh/authorized_keys on the remote server\n\
                  • Verify key permissions: chmod 600 ~/.ssh/id_ed25519\n\
                  • Try: ssh-add ~/.ssh/id_ed25519",
                auth_errors.join("\n  • ")
            ));
        }
    }

    if !sess.authenticated() {
        auth_errors.push("Final authentication check failed".to_string());
        return Err(anyhow!(
            "SSH authentication failed despite successful auth call:\n  • {}",
            auth_errors.join("\n  • ")
        ));
    }

    tracing::info!("SSH session authenticated successfully");
    Ok(AuthenticatedSession {
        session: sess,
        key_path: authenticated_with,
    })
}

/// Create SSH session and authenticate.
pub(crate) fn create_ssh_session(host: &str, port: u16, username: &str) -> anyhow::Result<ssh2::Session> {
    create_ssh_session_reporting_key(host, port, username).map(|a| a.session)
}

/// Present the one credential already proven to work, or fall back to the
/// ladder when there is none to present.
///
/// `identity` is the key file a previous probe/provision authenticated with.
/// When it is `Some`, offering anything else is pure waste — and worse than
/// waste on a server with the default `MaxAuthTries` of 6, which a loaded
/// agent plus the usual `~/.ssh` files can exhaust before the right key is
/// ever reached. `None` means the agent authenticated (or nothing has been
/// probed yet), and the ladder is the right behaviour.
pub(crate) fn create_ssh_session_maybe_with_key(
    host: &str,
    port: u16,
    username: &str,
    identity: Option<&Path>,
) -> anyhow::Result<Session> {
    match identity {
        Some(key) => create_ssh_session_with_key(host, port, username, key),
        None => create_ssh_session(host, port, username),
    }
}

/// Authenticate with exactly one key — nothing else is tried.
///
/// For the retry loop after publishing: at that point we know precisely
/// which key we just authorised, and `sshd`'s default `MaxAuthTries` (6) can
/// be exhausted by an agent holding a few identities plus the usual `~/.ssh`
/// candidates before LCC's key — offered last by `create_ssh_session` — is
/// ever reached. Presenting only the one key we care about sidesteps that
/// budget entirely.
pub(crate) fn create_ssh_session_with_key(
    host: &str,
    port: u16,
    username: &str,
    key_path: &Path,
) -> anyhow::Result<Session> {
    tracing::info!(
        host = host,
        port = port,
        username = username,
        key = %key_path.display(),
        "Creating SSH session with a single explicit key"
    );

    let sess = connect_and_handshake(host, port)?;

    sess.userauth_pubkey_file(username, None, key_path, None)
        .map_err(|e| anyhow!("SSH key file ({}): {}", key_path.display(), e))?;

    if !sess.authenticated() {
        return Err(anyhow!(
            "SSH authentication failed despite successful auth call:\n  • SSH key file ({}): Final authentication check failed",
            key_path.display()
        ));
    }

    tracing::info!("SSH session authenticated successfully");
    Ok(sess)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// La clave que genera `gcloud compute ssh` tiene que estar entre las
    /// candidatas: quien venga de gcloud ya la tiene autorizada en sus VMs, y
    /// sin ella ese usuario iría a provisionar una clave nueva sin necesidad.
    /// La de LCC va la última: es el recurso final, solo cuando lo demás falla.
    #[test]
    fn personal_and_gcloud_keys_come_before_lccs() {
        let ssh_dir = Path::new("/home/u/.ssh");
        let lcc_key = PathBuf::from("/data/ssh/lcc_ed25519");
        let paths = candidate_key_paths(ssh_dir, Some(lcc_key.clone()));

        let ed25519 = paths.iter().position(|p| p.ends_with("id_ed25519")).unwrap();
        let gcloud = paths.iter().position(|p| p.ends_with("google_compute_engine")).unwrap();
        let lcc = paths.iter().position(|p| *p == lcc_key).unwrap();
        assert!(ed25519 < gcloud, "orden inesperado: {:?}", paths);
        assert!(gcloud < lcc, "la clave de LCC debe ir última: {:?}", paths);
    }

    /// Sin esto, una clave que LCC acaba de autorizar en la VM nunca se
    /// ofrece en el `userauth_pubkey_file` que sigue: `provision_ssh_access`
    /// habría publicado una clave que `create_ssh_session` no sabe presentar.
    #[test]
    fn lccs_key_is_offered_when_supplied() {
        let ssh_dir = Path::new("/home/u/.ssh");
        let lcc_key = PathBuf::from("/data/ssh/lcc_ed25519");
        let paths = candidate_key_paths(ssh_dir, Some(lcc_key.clone()));
        assert!(paths.contains(&lcc_key), "la clave de LCC no está en la lista: {:?}", paths);
    }

    /// Sin clave de LCC (aún no generada), la lista es solo la de siempre.
    #[test]
    fn without_an_lcc_key_the_list_has_only_the_usual_four() {
        let ssh_dir = Path::new("/home/u/.ssh");
        let paths = candidate_key_paths(ssh_dir, None);
        assert_eq!(paths.len(), 4, "lista inesperada: {:?}", paths);
    }
}
