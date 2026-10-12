//! Getting SSH access to a VM without gcloud: which user to log in as, and
//! publishing LCC's key when nothing already grants access.

use anyhow::{anyhow, Result};
use crate::ssh_keys::{format_entry, merge_ssh_keys, LccKey};
use crate::validation::{validate_project_id, validate_zone, validate_instance_name, validate_username};

/// How a key reaches the VM. Decided per instance by its `enable-oslogin`
/// metadata, which `gcp_rest_client` already surfaces as `os_login_enabled`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProvisionMethod {
    OsLogin,
    InstanceMetadata,
}

/// Percent-encode a path segment (RFC 3986 unreserved set kept as-is).
///
/// Local copy of the same helper in `iap_tunnel::session`: `urlencoding` is
/// not a dependency of this crate, and this module is the only place that
/// needs it, so a ten-line copy beats widening that module's API.
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

/// Pick the SSH username for a VM.
///
/// Under OS Login the account is the POSIX one, which is *queried* rather than
/// derived: it can carry a collision suffix or be pinned by the organisation.
/// The derivation is the fallback. Without OS Login the local user is right —
/// it is the name gcloud publishes into `ssh-keys`, and using anything else
/// would break every VM already provisioned by gcloud.
pub(crate) fn choose_username(
    os_login_enabled: bool,
    posix: Option<&str>,
    email: &str,
    local_user: &str,
) -> String {
    if !os_login_enabled {
        return local_user.to_string();
    }
    match posix.map(str::trim).filter(|p| !p.is_empty()) {
        Some(p) => p.to_string(),
        None => crate::gcloud::email_to_oslogin_username(email),
    }
}

/// The POSIX account name to log in as, taken from an OS Login `loginProfile`.
///
/// The winner is the entry flagged `primary`, not `[0]`: a user can hold a
/// different POSIX account per project, and the array's order is not the
/// answer to "which one is this account's". Falling back to the first entry
/// only covers a profile that flags none.
pub(crate) fn primary_posix_username(profile: &serde_json::Value) -> Option<String> {
    let accounts = profile["posixAccounts"].as_array()?;
    accounts
        .iter()
        .find(|p| p["primary"] == serde_json::Value::Bool(true))
        .or_else(|| accounts.first())
        .and_then(|p| p["username"].as_str())
        .map(|s| s.to_string())
}

/// The POSIX account name from the caller's OS Login profile, if it has one.
pub(crate) async fn os_login_posix_username(email: &str) -> Result<Option<String>> {
    let token = crate::gcp_rest_client::access_token().await?;
    let url = format!(
        "https://oslogin.googleapis.com/v1/users/{}/loginProfile",
        encode(email)
    );

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| anyhow!("Failed to build the HTTP client: {}", e))?;

    let response = client
        .get(&url)
        .bearer_auth(&token)
        .send()
        .await
        .map_err(|e| anyhow!("OS Login profile request failed: {}", e))?;

    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        return Err(anyhow!(
            "OS Login profile lookup failed ({}): {}",
            status,
            crate::redact::redact_sensitive(&body)
        ));
    }

    let profile: serde_json::Value = serde_json::from_str(&response.text().await?)
        .map_err(|e| anyhow!("Could not parse the OS Login profile: {}", e))?;

    Ok(primary_posix_username(&profile))
}

/// Replace (or add) the `ssh-keys` item, leaving every other item untouched.
///
/// `items` carries whatever the organisation put on the VM — startup scripts,
/// `enable-oslogin`, monitoring flags. `setMetadata` replaces the whole list,
/// so dropping one here deletes it from the instance.
pub(crate) fn metadata_items_with_ssh_keys(
    items: &serde_json::Value,
    merged: &str,
) -> Vec<serde_json::Value> {
    let mut out: Vec<serde_json::Value> = items
        .as_array()
        .map(|a| a.iter().filter(|i| i["key"] != "ssh-keys").cloned().collect())
        .unwrap_or_default();
    out.push(serde_json::json!({ "key": "ssh-keys", "value": merged }));
    out
}

/// Authorise `key` for `username` on ONE instance.
///
/// Instance level, never project level: a project-level write would authorise
/// the key on every VM in the project, present and future.
pub(crate) async fn publish_to_instance_metadata(
    project: &str,
    zone: &str,
    instance: &str,
    username: &str,
    key: &LccKey,
) -> Result<()> {
    // Unvalidated inputs land in a request URL and in the shared `ssh-keys`
    // blob below. A stray `/` or `#` in `project` truncates the instance path
    // and can turn this into a project-level write — the one outcome this
    // function exists to forbid. A stray newline in `username` (which can
    // come from OS Login's server-supplied POSIX account) would inject an
    // extra line into `ssh-keys` that `merge_ssh_keys` has no way to catch,
    // since it only ever appends the entry whole.
    validate_project_id(project)?;
    validate_zone(zone)?;
    validate_instance_name(instance)?;
    validate_username(username)?;

    let token = crate::gcp_rest_client::access_token().await?;
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| anyhow!("Failed to build the HTTP client: {}", e))?;
    let base = format!(
        "https://compute.googleapis.com/compute/v1/projects/{}/zones/{}/instances/{}",
        project, zone, instance
    );

    // The read and the write are one attempt, retried once as a unit: the
    // fingerprint read in step 1 is exactly what step 3 can be rejected for.
    with_fingerprint_retry(|| publish_attempt(&client, &token, &base, username, key)).await?;

    tracing::info!(instance, username, fingerprint = %key.fingerprint, "Published LCC's SSH key to the instance metadata");
    Ok(())
}

/// What a single read-merge-write round trip ended in.
enum PublishAttempt {
    Done,
    /// GCP rejected the write with 412: the metadata fingerprint moved
    /// between our read and our write. Carries the (redacted) response body
    /// so a second conflict can still be reported with GCP's own detail.
    FingerprintConflict(String),
}

/// Run `attempt` once more if the first ended in a fingerprint conflict.
///
/// A 412 is reachable in normal use, not just under exotic contention: two
/// LCC session tabs booting at once (SSH and SFTP on the same VM), or the
/// user clicking twice, put two `setMetadata` writes on the same instance.
/// The loser's fingerprint is stale by the time it writes, and without this
/// it surfaced raw — a bare HTTP number for something the caller can simply
/// redo against the new fingerprint. Once only: a second conflict is real
/// contention with something outside LCC, and spinning on it would just
/// stack more writes onto a busy instance.
async fn with_fingerprint_retry<F, Fut>(mut attempt: F) -> Result<()>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Result<PublishAttempt>>,
{
    let mut conflict: Option<String> = None;
    for _ in 0..2 {
        match attempt().await? {
            PublishAttempt::Done => return Ok(()),
            PublishAttempt::FingerprintConflict(body) => {
                tracing::warn!(
                    "The instance metadata changed while LCC was writing to it (HTTP 412); re-reading the fingerprint and retrying once"
                );
                conflict = Some(body);
            }
        }
    }
    Err(anyhow!(
        "Could not authorise the SSH key: the VM's metadata kept changing while LCC was writing to it (412). \
         Another write is in flight on this instance — try again in a moment.\n\
         Details: {}",
        conflict.unwrap_or_default()
    ))
}

/// One read-merge-write round trip against the instance's metadata.
async fn publish_attempt(
    client: &reqwest::Client,
    token: &str,
    base: &str,
    username: &str,
    key: &LccKey,
) -> Result<PublishAttempt> {
    // 1) Read: we need the CURRENT metadata fingerprint. GCP uses it for
    //    optimistic concurrency and rejects a write without it.
    let current: serde_json::Value = {
        let r = client.get(base).bearer_auth(token).send().await
            .map_err(|e| anyhow!("Failed to read the instance: {}", e))?;
        if !r.status().is_success() {
            let status = r.status();
            let body = r.text().await.unwrap_or_default();
            return Err(anyhow!("Could not read the instance ({}): {}", status, crate::redact::redact_sensitive(&body)));
        }
        serde_json::from_str(&r.text().await?)
            .map_err(|e| anyhow!("Could not parse the instance: {}", e))?
    };

    let fingerprint = current["metadata"]["fingerprint"].as_str()
        .ok_or_else(|| anyhow!("The instance metadata carries no fingerprint; refusing to write blind"))?;
    let merged = merge_ssh_keys(
        current["metadata"]["items"].as_array()
            .and_then(|a| a.iter().find(|i| i["key"] == "ssh-keys"))
            .and_then(|i| i["value"].as_str()),
        &format_entry(username, &key.public_openssh),
    );

    // 2+3) Write back every item, with ssh-keys merged.
    let body = serde_json::json!({
        "fingerprint": fingerprint,
        "items": metadata_items_with_ssh_keys(&current["metadata"]["items"], &merged),
    });
    let r = client.post(format!("{}/setMetadata", base))
        .bearer_auth(token)
        .json(&body)
        .send().await
        .map_err(|e| anyhow!("Failed to write the instance metadata: {}", e))?;
    if !r.status().is_success() {
        let status = r.status();
        let text = r.text().await.unwrap_or_default();
        if status.as_u16() == 412 {
            return Ok(PublishAttempt::FingerprintConflict(
                crate::redact::redact_sensitive(&text),
            ));
        }
        return Err(provisioning_error(status.as_u16(), &text, "compute.instances.setMetadata"));
    }
    let operation: serde_json::Value = serde_json::from_str(&r.text().await?)
        .map_err(|e| anyhow!("Could not parse the metadata write's operation: {}", e))?;

    // `setMetadata` returning 200 means the write was ACCEPTED, not that it
    // landed: the response is an Operation in PENDING/RUNNING. Returning here
    // would let a write that later fails look successful to every caller,
    // including task 6's retry loop, which would then blame VM propagation
    // delay for what is actually a failed write.
    wait_for_zone_operation(client, token, base, &operation).await?;

    Ok(PublishAttempt::Done)
}

/// Poll a zone operation until GCP marks it `DONE`, bounded to 30s.
///
/// GCP's compute API is asynchronous: a 200 from `setMetadata` only means the
/// request was accepted. The write can still fail afterwards (a concurrent
/// fingerprint mismatch, a quota error), and that failure only shows up here.
async fn wait_for_zone_operation(
    client: &reqwest::Client,
    token: &str,
    instance_base: &str,
    operation: &serde_json::Value,
) -> Result<()> {
    let op_name = operation["name"].as_str().ok_or_else(|| {
        anyhow!("The metadata write's response carried no operation name; cannot confirm it landed")
    })?;
    // Derived from the instance URL rather than re-formatted from
    // project/zone, so the two can never disagree about which zone is being
    // polled: `.../zones/<zone>/instances/<name>` → `.../zones/<zone>/operations/<op>`.
    let url = format!(
        "{}/operations/{}",
        instance_base
            .rsplit_once("/instances/")
            .map(|(zone_base, _)| zone_base)
            .ok_or_else(|| anyhow!("Unexpected instance URL; cannot poll the metadata write"))?,
        op_name
    );

    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    let mut current = operation.clone();
    while current["status"].as_str() != Some("DONE") {
        if std::time::Instant::now() >= deadline {
            return Err(anyhow!(
                "Timed out waiting for the metadata write to finish (last status: {})",
                current["status"].as_str().unwrap_or("unknown")
            ));
        }
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;

        let r = client.get(&url).bearer_auth(token).send().await
            .map_err(|e| anyhow!("Failed to poll the metadata write's operation: {}", e))?;
        if !r.status().is_success() {
            let status = r.status();
            let body = r.text().await.unwrap_or_default();
            return Err(anyhow!(
                "Could not poll the metadata write's operation ({}): {}",
                status,
                crate::redact::redact_sensitive(&body)
            ));
        }
        current = serde_json::from_str(&r.text().await?)
            .map_err(|e| anyhow!("Could not parse the metadata write's operation: {}", e))?;
    }

    if let Some(error) = current.get("error") {
        return Err(anyhow!(
            "The metadata write finished with an error: {}",
            crate::redact::redact_sensitive(&error.to_string())
        ));
    }
    Ok(())
}

/// Authorise `key` through OS Login, for the signed-in account.
///
/// Returns the POSIX account name from the login profile the import created
/// or refreshed. That return value is the whole point of parsing the
/// response: a user who has never logged into an OS Login VM has no profile
/// *before* the import, so the name resolved earlier is the `@`→`_` mangle of
/// their e-mail — wrong whenever Google prefixes `ext_` (an identity outside
/// the project's organisation, precisely this feature's target user), and
/// wrong for any org-pinned or collision-suffixed name. `importSshPublicKey`
/// answers with the real one; discarding it made the retry loop authenticate
/// as a user that does not exist and then blame VM propagation for it.
pub(crate) async fn publish_to_os_login(email: &str, key: &LccKey) -> Result<Option<String>> {
    let token = crate::gcp_rest_client::access_token().await?;
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| anyhow!("Failed to build the HTTP client: {}", e))?;

    let url = format!(
        "https://oslogin.googleapis.com/v1/users/{}:importSshPublicKey",
        encode(email)
    );
    let body = serde_json::json!({
        "key": format!("{} {}", key.public_openssh, crate::ssh_keys::KEY_COMMENT),
    });

    let r = client.post(&url).bearer_auth(&token).json(&body).send().await
        .map_err(|e| anyhow!("OS Login key import failed: {}", e))?;
    if !r.status().is_success() {
        let status = r.status();
        let text = r.text().await.unwrap_or_default();
        return Err(provisioning_error(status.as_u16(), &text, "compute.instances.osLogin"));
    }

    let response: serde_json::Value = serde_json::from_str(&r.text().await?)
        .map_err(|e| anyhow!("Could not parse the OS Login key import response: {}", e))?;
    let posix = primary_posix_username(&response["loginProfile"]);

    tracing::info!(fingerprint = %key.fingerprint, "Imported LCC's SSH key through OS Login");
    Ok(posix)
}

/// Turn a provisioning failure into something the user can act on.
///
/// Permissions are the likeliest failure in a distributed app: plenty of users
/// hold read-only or operator roles. Naming the missing permission and the two
/// real ways out beats a generic message that sends them looking in the wrong
/// place — the same lesson the tunnel error sweep taught. 401 is kept apart
/// from 403: an expired or invalid credential is not a missing permission,
/// and sending that user to IAM is exactly the misdirection this function
/// exists to prevent. The literal `invalid_grant` is required by
/// `classifyRustError` in `lib/src/features/app_error.dart`, which keys on it
/// to raise the re-login banner.
fn provisioning_error(status: u16, body: &str, permission: &str) -> anyhow::Error {
    let redacted = crate::redact::redact_sensitive(body);
    if status == 401 {
        return anyhow!(
            "The sign-in session has expired (invalid_grant). Sign in again and retry.\n\
             Details: {}",
            redacted
        );
    }
    if status == 403 {
        return anyhow!(
            "Not allowed to authorise an SSH key on this VM: the account is missing `{}`.\n\
             Either ask an administrator to grant it (or to authorise your key), or open the port \
             in the IAP firewall rule and use a direct tunnel instead.\n\
             Details: {}",
            permission, redacted
        );
    }
    anyhow!("Could not authorise the SSH key ({}): {}", status, redacted)
}

/// Run blocking SSH work off the async runtime.
///
/// `create_ssh_session` and `start_tunnel` both block — the latter sleeps in a
/// loop for up to ten seconds waiting for the local port — so calling either
/// directly from an async fn would pin a tokio worker.
async fn ssh_call<T, F>(f: F) -> Result<T>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
{
    tokio::task::spawn_blocking(f)
        .await
        .map_err(|e| anyhow!("SSH task failed: {}", e))
}

/// How long to keep retrying the session after publishing, while the guest
/// agent picks the new key up.
const PROPAGATION_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(45);

/// The credential that opens a session on this VM.
///
/// Both halves matter, and until now only the first was carried: returning a
/// username alone made every real session — the `ssh(1)` the terminal spawns,
/// SFTP, the native forward — re-derive the key from scratch. `ssh(1)` cannot
/// re-derive LCC's key at all (it lives outside `~/.ssh`), and libssh2's
/// candidate ladder reaches it only after `sshd`'s default `MaxAuthTries` of 6
/// may already be spent. So the key that was *proven* to work travels with the
/// username.
pub struct SshCredential {
    pub username: String,
    /// The key file that authenticated. `None` when the SSH agent did: there
    /// is then nothing to carry, and every entry point should use the agent
    /// exactly as before.
    pub key_path: Option<String>,
}

/// Whether we already have SSH access, or need to publish a key first.
pub enum SshAccessState {
    Ready { credential: SshCredential },
    NeedsProvisioning { username: String, method: ProvisionMethod, key_fingerprint: String },
}

fn method_for(os_login_enabled: bool) -> ProvisionMethod {
    if os_login_enabled { ProvisionMethod::OsLogin } else { ProvisionMethod::InstanceMetadata }
}

/// Whether an SSH failure is the server rejecting our credentials.
///
/// Anything else — refused connection, failed handshake, dead relay — is a
/// different problem, and provisioning a key would neither fix it nor explain
/// it. Matches the wording `create_ssh_session` and `create_ssh_session_with_key`
/// produce: the third clause covers the final `sess.authenticated()` check
/// failing after a call that reported success, which carries neither
/// "authentication methods failed" nor "Authentication failed" verbatim.
fn is_auth_failure(message: &str) -> bool {
    message.contains("authentication methods failed")
        || message.contains("Authentication failed")
        || message.contains("SSH authentication failed despite successful auth call")
}

/// Do we already have access to this VM, and as whom?
///
/// Finds out by connecting for real: an authorised key is one that
/// authenticates, not one with a familiar file name. Writes nothing to the
/// VM or to GCP — the consent this feature asks for is about modifying the
/// user's infrastructure, not about local files. It may generate LCC's own
/// key pair on first use, though: the consent dialog needs the fingerprint of
/// the key that would be published, so it has to exist by then.
pub async fn probe_ssh_access(project: String, zone: String, instance: String) -> Result<SshAccessState> {
    let on = os_login_enabled(&project, &zone, &instance).await?;
    let username = resolve_username(on).await?;

    let (p, z, i) = (project.clone(), zone.clone(), instance.clone());
    let local_port = ssh_call(move || crate::tunnel::start_tunnel(&p, &z, &i, 22, None)).await??.local_port;

    let user_for_thread = username.clone();
    // The full candidate ladder, deliberately: on the probe the user's own
    // keys should still win over LCC's. What changed is that the winner is
    // reported instead of discarded, so the session that follows presents
    // exactly the credential this probe proved.
    let attempt = ssh_call(move || {
        crate::ssh_session::create_ssh_session_reporting_key("127.0.0.1", local_port, &user_for_thread)
            .map(|s| s.key_path)
    })
    .await?;

    match attempt {
        Ok(key_path) => Ok(SshAccessState::Ready {
            credential: SshCredential {
                username,
                key_path: key_path.map(|p| p.to_string_lossy().into_owned()),
            },
        }),
        Err(e) if is_auth_failure(&e.to_string()) => {
            let key = crate::ssh_keys::load_or_create_key()?;
            Ok(SshAccessState::NeedsProvisioning {
                username,
                method: method_for(on),
                key_fingerprint: key.fingerprint,
            })
        }
        Err(e) => Err(e),
    }
}

/// Publish LCC's key and do not return until a session actually authenticates.
pub async fn provision_ssh_access(project: String, zone: String, instance: String) -> Result<SshCredential> {
    let on = os_login_enabled(&project, &zone, &instance).await?;
    let username = resolve_username(on).await?;
    let key = crate::ssh_keys::load_or_create_key()?;
    let email = crate::accounts::active_email().await?;

    let username = match method_for(on) {
        ProvisionMethod::OsLogin => {
            // The import CREATES the profile for a user who never had one, so
            // its answer supersedes the name resolved above — which, for that
            // user, was only the e-mail mangle.
            match publish_to_os_login(&email, &key).await? {
                // Server-supplied, and about to be used as an SSH username:
                // validated for the same reason the metadata path validates
                // it, rather than trusted because Google sent it.
                Some(posix) => match validate_username(&posix) {
                    Ok(()) => posix,
                    Err(e) => {
                        tracing::warn!(error = %e, "OS Login returned an unusable POSIX account name; keeping the resolved one");
                        username
                    }
                },
                None => {
                    tracing::warn!("The OS Login key import returned no POSIX account; keeping the resolved user name");
                    username
                }
            }
        }
        ProvisionMethod::InstanceMetadata => {
            publish_to_instance_metadata(&project, &zone, &instance, &username, &key).await?;
            username
        }
    };

    let (p, z, i) = (project.clone(), zone.clone(), instance.clone());
    let local_port = ssh_call(move || crate::tunnel::start_tunnel(&p, &z, &i, 22, None)).await??.local_port;

    // From here we present the ONE key we just authorised, never the full
    // candidate ladder: `sshd`'s default `MaxAuthTries` (6) can be exhausted
    // by an agent holding a few identities plus the usual `~/.ssh` files
    // before LCC's key — offered last by `create_ssh_session` — is ever
    // tried, which would make this loop spin for the full timeout and blame
    // VM propagation for a budget it never got to spend on the right key.
    let key_path = crate::ssh_keys::key_path()?;

    let deadline = std::time::Instant::now() + PROPAGATION_TIMEOUT;
    loop {
        let user_for_thread = username.clone();
        let key_for_thread = key_path.clone();
        let attempt = ssh_call(move || {
            crate::ssh_session::create_ssh_session_with_key(
                "127.0.0.1",
                local_port,
                &user_for_thread,
                &key_for_thread,
            )
            .map(|_| ())
        })
        .await?;

        match attempt {
            Ok(()) => {
                return Ok(SshCredential {
                    username,
                    key_path: Some(key_path.to_string_lossy().into_owned()),
                })
            }
            // Only an auth failure is consistent with "the key is not visible
            // on the VM yet" and worth retrying. Anything else — the relay
            // dying mid-loop, a refused connection — is a different problem;
            // retrying it for the full timeout and then blaming propagation
            // would be exactly the misdiagnosis `is_auth_failure` exists to
            // prevent.
            Err(e) if is_auth_failure(&e.to_string()) => {
                if std::time::Instant::now() >= deadline {
                    // Distinct from "could not write": the key IS authorised,
                    // the VM has just not picked it up yet, and retrying is
                    // the right advice.
                    return Err(anyhow!(
                        "The SSH key was authorised, but {} has not picked it up yet after {} seconds. Try again in a moment.",
                        instance,
                        PROPAGATION_TIMEOUT.as_secs()
                    ));
                }
                tokio::time::sleep(std::time::Duration::from_secs(3)).await;
            }
            Err(e) => return Err(e),
        }
    }
}

/// Whether this VM uses OS Login. Read from the instance, which
/// `gcp_rest_client` already parses out of its `enable-oslogin` metadata.
/// The SSH username for this VM, without probing or provisioning anything.
///
/// One REST call, no tunnel and no SSH session, so it is cheap enough to fill a
/// form field as a dialog opens. The SSHFS dialog uses it: that field used to be
/// prefilled by mangling the e-mail, which silently produced the wrong account
/// on an OS Login VM — and a plausible-looking wrong value in an editable field
/// is worse than an empty one, because the user "corrects" it.
pub async fn ssh_username_for(project: String, zone: String, instance: String) -> Result<String> {
    let on = os_login_enabled(&project, &zone, &instance).await?;
    resolve_username(on).await
}

async fn os_login_enabled(project: &str, zone: &str, instance: &str) -> Result<bool> {
    Ok(crate::gcp_rest_client::get_instance_client_lib(project, zone, instance)
        .await?
        .os_login_enabled)
}

/// The username to log in as on this VM.
///
/// Takes whether OS Login is on rather than fetching the instance itself:
/// both callers already need that flag for `method_for`, and fetching it a
/// second time in here would double the `get_instance_client_lib` round trip
/// per `probe`/`provision` call for no benefit. The OS Login profile is only
/// fetched when OS Login is actually on: under metadata the answer is the
/// local user and the network call would be waste.
async fn resolve_username(os_login_enabled: bool) -> Result<String> {
    let email = crate::accounts::active_email().await?;
    let posix = if os_login_enabled {
        // Not `.ok().flatten()`: a 403, a 404 or a dead network here silently
        // demotes the answer to the e-mail mangle, and the user then meets a
        // failure ("the key was authorised but the VM has not picked it up
        // yet") that names the wrong cause. The warning is what makes that
        // diagnosable.
        match os_login_posix_username(&email).await {
            Ok(posix) => posix,
            Err(e) => {
                tracing::warn!(
                    error = %e,
                    "Could not read the OS Login profile; falling back to the name derived from the e-mail"
                );
                None
            }
        }
    } else {
        None
    };
    Ok(choose_username(
        os_login_enabled,
        posix.as_deref(),
        &email,
        &crate::sftp::get_current_username()?,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Solo un fallo de AUTENTICACIÓN significa "hay que provisionar". Que la
    /// VM no responda es otro problema y debe propagarse, no disfrazarse de
    /// clave que falta.
    #[test]
    fn only_an_auth_failure_means_provisioning_is_needed() {
        assert!(is_auth_failure("All SSH authentication methods failed:\n  • SSH agent: ..."));
        assert!(is_auth_failure("SSH key file (/home/u/.ssh/id_rsa): Authentication failed"));
        assert!(!is_auth_failure("Failed to connect to SSH server: Connection refused"));
        assert!(!is_auth_failure("SSH handshake failed: timed out"));
    }

    /// Round 2, finding 4: `create_ssh_session_with_key`'s final
    /// `sess.authenticated()` check produces this exact wording, which
    /// carries neither "authentication methods failed" nor "Authentication
    /// failed" verbatim — without this clause it would fall through to
    /// `Err(e) => Err(e)` and propagate instead of triggering provisioning.
    #[test]
    fn the_final_authenticated_check_failing_is_also_an_auth_failure() {
        assert!(is_auth_failure(
            "SSH authentication failed despite successful auth call:\n  \
             • SSH key file (/data/ssh/lcc_ed25519): Final authentication check failed"
        ));
    }

    /// Round 2, finding 1, regression guard: the retry loop in
    /// `provision_ssh_access` must authenticate with the one key we just
    /// published (`create_ssh_session_with_key`), never the full candidate
    /// ladder (`create_ssh_session`) — `sshd`'s default `MaxAuthTries` (6) can
    /// be exhausted by an agent holding a few identities plus the usual
    /// `~/.ssh` files before LCC's key, offered last, is ever tried, which
    /// would make the 45s retry loop spin and misreport propagation delay.
    ///
    /// A behavioural test would need a live `sshd`, which this crate's other
    /// GCP/SSH tests avoid by being `#[ignore]`d. This reads the function's
    /// own source instead, so it still fails the moment the loop is pointed
    /// back at the full ladder — verified failing when reverted, see report.
    #[test]
    fn the_retry_loop_uses_the_single_key_entry_point_not_the_full_ladder() {
        let source = include_str!("ssh_access.rs");
        let start = source
            .find("pub async fn provision_ssh_access")
            .expect("no se encontró provision_ssh_access en el propio fichero");
        let body = &source[start..];
        let end = body.find("\nasync fn os_login_enabled").unwrap_or(body.len());
        let body = &body[..end];

        assert!(
            body.contains("create_ssh_session_with_key"),
            "provision_ssh_access ya no llama a create_ssh_session_with_key"
        );
        assert!(
            !body.contains("create_ssh_session("),
            "provision_ssh_access volvió a usar la escalera completa de candidatas (create_ssh_session)"
        );
    }

    #[test]
    fn the_provisioning_method_follows_os_login() {
        assert_eq!(method_for(true), ProvisionMethod::OsLogin);
        assert_eq!(method_for(false), ProvisionMethod::InstanceMetadata);
    }

    /// Round 3, finding 5: el POSIX bueno es el marcado `primary`, no el
    /// `[0]`. Un usuario puede tener una cuenta POSIX distinta por proyecto y
    /// el orden del array no responde a cuál es la suya.
    #[test]
    fn the_primary_posix_account_wins_over_the_first_one() {
        let profile = serde_json::json!({
            "posixAccounts": [
                {"username": "jlopezre_otro_proyecto", "primary": false},
                {"username": "ext_jlopezre_gmail_com", "primary": true}
            ]
        });
        assert_eq!(
            primary_posix_username(&profile).as_deref(),
            Some("ext_jlopezre_gmail_com")
        );
    }

    /// Sin ninguna marcada, la primera es la única respuesta disponible.
    #[test]
    fn without_a_primary_flag_the_first_account_is_used() {
        let profile = serde_json::json!({"posixAccounts": [{"username": "jlopezre_ntt_enap_cl"}]});
        assert_eq!(primary_posix_username(&profile).as_deref(), Some("jlopezre_ntt_enap_cl"));
    }

    /// Un perfil recién creado sin cuentas POSIX no inventa un nombre.
    #[test]
    fn a_profile_without_posix_accounts_yields_nothing() {
        assert_eq!(primary_posix_username(&serde_json::json!({})), None);
        assert_eq!(primary_posix_username(&serde_json::json!({"posixAccounts": []})), None);
    }

    /// Round 3, finding 5: la respuesta de `importSshPublicKey` es un
    /// `ImportSshPublicKeyResponse` que trae el `loginProfile` recién creado.
    /// Ese es el nombre real del usuario que no tenía perfil antes del import
    /// —justo el caso en el que el derivado del email se equivoca, porque
    /// Google antepone `ext_` a las identidades de fuera de la organización.
    #[test]
    fn the_import_response_carries_the_freshly_created_posix_account() {
        let response = serde_json::json!({
            "loginProfile": {
                "name": "1234567890",
                "posixAccounts": [{
                    "primary": true,
                    "username": "ext_jordi_lopez_reyes_gmail_com",
                    "uid": "1000",
                    "homeDirectory": "/home/ext_jordi_lopez_reyes_gmail_com"
                }]
            }
        });
        assert_eq!(
            primary_posix_username(&response["loginProfile"]).as_deref(),
            Some("ext_jordi_lopez_reyes_gmail_com"),
            "sin esto el bucle de reintento autentica como un usuario que no existe"
        );
    }

    /// Round 3, finding 4: un 412 significa que la huella de metadatos se
    /// movió entre nuestra lectura y nuestra escritura —dos pestañas de LCC
    /// arrancando a la vez sobre la misma VM basta— y se resuelve releyendo y
    /// reintentando, no propagando un número HTTP crudo.
    #[tokio::test]
    async fn a_fingerprint_conflict_is_retried_once_and_then_succeeds() {
        let calls = std::cell::Cell::new(0);
        let out = with_fingerprint_retry(|| async {
            calls.set(calls.get() + 1);
            if calls.get() == 1 {
                Ok(PublishAttempt::FingerprintConflict("conditionNotMet".into()))
            } else {
                Ok(PublishAttempt::Done)
            }
        })
        .await;
        assert!(out.is_ok(), "el reintento debía salvar la escritura: {:?}", out.err());
        assert_eq!(calls.get(), 2, "no se releyó la huella ni se reintentó");
    }

    /// Pero solo una vez: un segundo conflicto es contención real y el
    /// mensaje tiene que decir qué hacer, no repetir el 412 a secas.
    #[tokio::test]
    async fn a_second_conflict_gives_up_with_an_actionable_message() {
        let calls = std::cell::Cell::new(0);
        let err = with_fingerprint_retry(|| async {
            calls.set(calls.get() + 1);
            Ok(PublishAttempt::FingerprintConflict("conditionNotMet".into()))
        })
        .await
        .unwrap_err();
        assert_eq!(calls.get(), 2, "no puede reintentar indefinidamente");
        let msg = err.to_string();
        assert!(msg.contains("try again"), "mensaje sin salida accionable: {}", msg);
    }

    /// Round 3, finding 2: el reenvío nativo es una de las tres sesiones
    /// reales posteriores al provisionado. Si vuelve a la escalera completa,
    /// la clave de LCC —que va la última— puede quedarse sin presupuesto de
    /// `MaxAuthTries` y el reenvío falla justo después de que el provisionado
    /// dijera que todo fue bien. Igual que el guard del bucle de reintento,
    /// esto lee la fuente porque una prueba de comportamiento necesitaría un
    /// `sshd` vivo.
    #[test]
    fn the_native_forward_presents_the_credential_it_was_given() {
        let source = include_str!("ssh_forward.rs");
        assert!(
            source.contains("create_ssh_session_maybe_with_key"),
            "ssh_forward ya no presenta la credencial validada"
        );
        assert!(
            !source.contains("create_ssh_session(\""),
            "ssh_forward volvió a la escalera completa de candidatas"
        );
    }

    /// Lo mismo para SFTP, la otra sesión real: ninguna de sus rutas puede
    /// volver a abrir sesión ignorando la credencial que le llega.
    #[test]
    fn every_sftp_path_presents_the_credential_it_was_given() {
        let source = include_str!("sftp.rs");
        assert!(
            !source.contains("create_ssh_session(&host"),
            "alguna ruta de SFTP volvió a la escalera completa de candidatas"
        );
        assert!(
            source.contains("create_ssh_session_maybe_with_key(&host, port, &username, identity(&identity_file))"),
            "SFTP ya no presenta la credencial validada"
        );
    }

    /// El fallo que SP-1 arregla: con OS Login activo el usuario NO es el local.
    #[test]
    fn os_login_uses_the_posix_account_not_the_local_user() {
        let u = choose_username(true, Some("jlopezre_ntt_enap_cl"), "jlopezre@ntt.enap.cl", "jlopezre");
        assert_eq!(u, "jlopezre_ntt_enap_cl");
    }

    /// Sin perfil utilizable se deriva del email, que es mejor que el local.
    #[test]
    fn os_login_without_a_profile_falls_back_to_the_derived_name() {
        let u = choose_username(true, None, "jlopezre@ntt.enap.cl", "jlopezre");
        assert_eq!(u, "jlopezre_ntt_enap_cl");
    }

    /// Un perfil vacío o en blanco no es un nombre de usuario.
    #[test]
    fn a_blank_posix_name_is_not_used() {
        let u = choose_username(true, Some("   "), "jlopezre@ntt.enap.cl", "jlopezre");
        assert_eq!(u, "jlopezre_ntt_enap_cl");
    }

    /// Sin OS Login manda el usuario local, que es lo que gcloud provisiona.
    #[test]
    fn metadata_mode_keeps_the_local_user() {
        let u = choose_username(false, Some("jlopezre_ntt_enap_cl"), "jlopezre@ntt.enap.cl", "jlopezre");
        assert_eq!(u, "jlopezre");
    }

    /// Reescribir `items` no puede perder los demás metadatos de la VM:
    /// ahí viven startup-script, enable-oslogin y todo lo que la organización
    /// haya puesto.
    #[test]
    fn rewriting_ssh_keys_keeps_every_other_metadata_item() {
        let items = serde_json::json!([
            {"key": "startup-script", "value": "#!/bin/bash\necho hola"},
            {"key": "ssh-keys", "value": "ana:ssh-rsa AAAA0000 ana"},
            {"key": "enable-oslogin", "value": "FALSE"}
        ]);

        let out = metadata_items_with_ssh_keys(&items, "ana:ssh-rsa AAAA0000 ana\nyo:ssh-ed25519 AAAA1111 lightweight-cloud-connector");

        let by_key = |k: &str| out.iter().find(|i| i["key"] == k).cloned();
        assert_eq!(by_key("startup-script").unwrap()["value"], "#!/bin/bash\necho hola");
        assert_eq!(by_key("enable-oslogin").unwrap()["value"], "FALSE");
        assert!(by_key("ssh-keys").unwrap()["value"].as_str().unwrap().contains("lightweight-cloud-connector"));
        assert_eq!(out.len(), 3, "cambió el número de items: {:?}", out);
    }

    /// Una VM sin `ssh-keys` previo gana el item, sin perder los otros.
    #[test]
    fn an_instance_without_ssh_keys_gains_the_item() {
        let items = serde_json::json!([{"key": "startup-script", "value": "x"}]);
        let out = metadata_items_with_ssh_keys(&items, "yo:ssh-ed25519 AAAA1111 lightweight-cloud-connector");
        assert_eq!(out.len(), 2);
        assert!(out.iter().any(|i| i["key"] == "ssh-keys"));
        assert!(out.iter().any(|i| i["key"] == "startup-script"));
    }

    /// Round 1, finding 1: un `project` malformado no puede llegar a construir
    /// una petición. Sin la validación, un `#` o `/` en `project` trunca la
    /// ruta y puede convertir la escritura en una escritura a nivel de
    /// proyecto — justo lo que esta función existe para prohibir. Este test
    /// debe fallar si las llamadas `validate_*` se quitan del principio de
    /// `publish_to_instance_metadata` (verificado a mano: ver informe).
    #[tokio::test]
    async fn a_malformed_project_is_rejected_before_any_request_is_built() {
        let key = LccKey {
            public_openssh: "ssh-ed25519 AAAA0000".to_string(),
            fingerprint: "SHA256:x".to_string(),
        };
        let err = publish_to_instance_metadata(
            "myproj/setCommonInstanceMetadata#",
            "us-central1-a",
            "vm1",
            "jlopezre",
            &key,
        )
        .await
        .unwrap_err();
        // Buscamos el texto exacto de `validate_project_id`, no una palabra
        // suelta como "project": esa palabra también aparece si la petición
        // llega a salir (queda en la URL de la respuesta de error de Google),
        // lo que volvería la prueba verde por la razón equivocada.
        let msg = err.to_string().to_lowercase();
        assert!(
            msg.contains("invalid project id"),
            "se esperaba el error de `validate_project_id`, se obtuvo: {}",
            err
        );
    }

    /// Round 1, finding 5: un item `ssh-keys` con valor null no debe leerse
    /// como una clave real. El código que llama a `merge_ssh_keys` extrae el
    /// valor con `.as_str()`, que ya devuelve `None` para `null` — este test
    /// fija ese comportamiento en vez de dejarlo implícito, porque el fallo
    /// de esta función es revocar el acceso SSH de otros.
    #[test]
    fn a_null_ssh_keys_value_merges_as_if_absent() {
        let items = serde_json::json!([
            {"key": "ssh-keys", "value": serde_json::Value::Null},
            {"key": "startup-script", "value": "x"}
        ]);
        let current = items
            .as_array()
            .unwrap()
            .iter()
            .find(|i| i["key"] == "ssh-keys")
            .and_then(|i| i["value"].as_str());
        assert_eq!(current, None, "un valor null no debe leerse como cadena");

        let merged = merge_ssh_keys(current, "yo:ssh-ed25519 AAAA1111 lightweight-cloud-connector");
        assert_eq!(merged, "yo:ssh-ed25519 AAAA1111 lightweight-cloud-connector");

        let out = metadata_items_with_ssh_keys(&items, &merged);
        assert_eq!(out.len(), 2);
        assert!(out.iter().any(|i| i["key"] == "startup-script"));
    }

    /// Lo mismo, pero cuando el item ni siquiera lleva el campo `value`.
    #[test]
    fn an_ssh_keys_item_missing_the_value_field_merges_as_if_absent() {
        let items = serde_json::json!([{"key": "ssh-keys"}]);
        let current = items
            .as_array()
            .unwrap()
            .iter()
            .find(|i| i["key"] == "ssh-keys")
            .and_then(|i| i["value"].as_str());
        assert_eq!(current, None);

        let merged = merge_ssh_keys(current, "yo:ssh-ed25519 AAAA1111 lightweight-cloud-connector");
        assert_eq!(merged, "yo:ssh-ed25519 AAAA1111 lightweight-cloud-connector");
    }
}
