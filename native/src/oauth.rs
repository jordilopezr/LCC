//! LCC's own OAuth 2.0 client: authorization code + PKCE with a loopback
//! redirect, modelled on how IAP Desktop authenticates without the gcloud CLI.
//!
//! The client ID is public by design for installed apps — PKCE, not a secret,
//! is what protects the exchange.

use anyhow::{anyhow, Result};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use sha2::{Digest, Sha256};
use std::time::Duration;
use tracing::debug;

const OAUTH_CLIENT_ID: &str =
    "743123147934-plp891qo2a44ie5jop1ud7n445gduk0h.apps.googleusercontent.com";
/// Non-confidential secret issued to this Desktop client, supplied at build
/// time by `build.rs` — never hard-coded here.
///
/// Google *requires* it on the code exchange (an empty value is rejected with
/// `invalid_request: client_secret missing`), so it ships inside the binary: an
/// installed app cannot keep a secret, which is why PKCE, not this value, is
/// what actually protects the exchange. Same posture as the gcloud CLI, whose
/// own client secret sits in plaintext in every
/// `application_default_credentials.json`.
///
/// What it must not do is sit in a public repository, where credential scanners
/// find it and providers revoke it — breaking sign-in for everyone running a
/// release. Empty when the build did not supply one: the two exchanges below
/// then omit the parameter, native sign-in is unavailable, and the gcloud auth
/// engine takes over.
const OAUTH_CLIENT_SECRET: &str =
    include_str!(concat!(env!("OUT_DIR"), "/oauth_client_secret"));
const AUTH_ENDPOINT: &str = "https://accounts.google.com/o/oauth2/v2/auth";
const TOKEN_ENDPOINT: &str = "https://oauth2.googleapis.com/token";
const REVOKE_ENDPOINT: &str = "https://oauth2.googleapis.com/revoke";
const SCOPES: &str = "https://www.googleapis.com/auth/cloud-platform openid email";
const REDIRECT_TIMEOUT: Duration = Duration::from_secs(300);

/// Which credential source serves access tokens.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthEngine {
    Gcloud,
    Native,
}

impl From<crate::engine_pref::Engine> for AuthEngine {
    fn from(e: crate::engine_pref::Engine) -> Self {
        match e {
            crate::engine_pref::Engine::Native => AuthEngine::Native,
            crate::engine_pref::Engine::Gcloud => AuthEngine::Gcloud,
        }
    }
}

/// Which credential source serves access tokens.
///
/// `LCC_AUTH_ENGINE` wins, then the stored preference, then native — the
/// default since D5. See `crate::engine_pref`.
pub fn auth_engine() -> AuthEngine {
    crate::engine_pref::engine_for(crate::engine_pref::EngineSlot::Auth).into()
}

/// Tokens obtained from a completed interactive sign-in.
pub struct OAuthTokens {
    pub email: String,
    pub refresh_token: String,
    pub access_token: String,
    pub expires_in_secs: u64,
}

/// PKCE S256: base64url-no-pad of SHA-256(verifier), per RFC 7636.
fn challenge_from_verifier(verifier: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()))
}

/// Fresh (verifier, challenge) pair. 32 random bytes → 43-char verifier.
fn generate_pkce() -> (String, String) {
    use rand::RngCore;
    let mut bytes = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut bytes);
    let verifier = URL_SAFE_NO_PAD.encode(bytes);
    let challenge = challenge_from_verifier(&verifier);
    (verifier, challenge)
}

/// Random anti-CSRF `state` value.
fn generate_state() -> String {
    use rand::RngCore;
    let mut bytes = [0u8; 16];
    rand::thread_rng().fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

/// Compare secrets without leaking length-independent timing.
fn constant_time_eq(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

/// Build the Google authorization URL the browser is sent to.
fn build_auth_url(
    client_id: &str,
    redirect_uri: &str,
    challenge: &str,
    state: &str,
) -> Result<String> {
    let url = reqwest::Url::parse_with_params(
        AUTH_ENDPOINT,
        &[
            ("client_id", client_id),
            ("redirect_uri", redirect_uri),
            ("response_type", "code"),
            ("scope", SCOPES),
            ("code_challenge", challenge),
            ("code_challenge_method", "S256"),
            ("state", state),
            // offline → issue a refresh token; consent → keep issuing one on
            // later sign-ins (Google omits it otherwise).
            ("access_type", "offline"),
            ("prompt", "consent"),
        ],
    )?;
    Ok(url.to_string())
}

/// Extract the authorization code from the browser's redirect request line
/// (e.g. `GET /?code=…&state=… HTTP/1.1`), validating the path and `state`
/// first, in that order, before looking at `code`/`error`.
fn parse_redirect_request(request_line: &str, expected_state: &str) -> Result<String> {
    let target = request_line
        .split_whitespace()
        .nth(1)
        .ok_or_else(|| anyhow!("Malformed HTTP request from browser"))?;
    let url = reqwest::Url::parse(&format!("http://127.0.0.1{}", target))
        .map_err(|_| anyhow!("Malformed redirect URL from browser"))?;

    // The redirect_uri sent to Google is bare (http://127.0.0.1:<port>, no
    // path), so anything else here — e.g. a browser's favicon/probe request —
    // is not our OAuth redirect. The caller's own code=/error= sniff still
    // routes those to the "dismiss and keep waiting" branch rather than
    // aborting the sign-in; this only rejects them earlier and more precisely.
    if url.path() != "/" {
        return Err(anyhow!("Unexpected redirect path: {}", url.path()));
    }

    let (mut code, mut state, mut error) = (None, None, None);
    for (key, value) in url.query_pairs() {
        match key.as_ref() {
            "code" => code = Some(value.into_owned()),
            "state" => state = Some(value.into_owned()),
            "error" => error = Some(value.into_owned()),
            _ => {}
        }
    }

    // Validate state before anything else, including a reported `error=`.
    // RFC 6749 §4.1.2.1 requires the authorization server to echo state on
    // error redirects too, so checking it first is safe — and it closes a
    // real gap: previously any local process could abort a pending sign-in
    // by hitting this port with a forged `?error=access_denied` before state
    // was ever checked. This does not fully close that boundary: a local
    // process that also knows or guesses the state can still abort a pending
    // sign-in this way — the loopback listener has no stronger
    // authentication than `state`, and that is an accepted local-DoS risk on
    // a single-user desktop app, not a data-confidentiality one.
    let state = state.ok_or_else(|| anyhow!("Redirect carried no state parameter"))?;
    if !constant_time_eq(&state, expected_state) {
        return Err(anyhow!("OAuth state mismatch — ignoring the redirect"));
    }

    if let Some(error) = error {
        return Err(anyhow!("Google returned an authorization error: {}", error));
    }
    let code = code.ok_or_else(|| anyhow!("Redirect carried no authorization code"))?;
    if code.is_empty() {
        return Err(anyhow!("Redirect carried an empty authorization code"));
    }
    Ok(code)
}

/// Read the `email` claim from an id_token's payload. The token comes straight
/// from Google's token endpoint over TLS, so the signature is not re-verified.
fn email_from_id_token(id_token: &str) -> Result<String> {
    let payload = id_token
        .split('.')
        .nth(1)
        .ok_or_else(|| anyhow!("Malformed id_token"))?;
    let bytes = URL_SAFE_NO_PAD
        .decode(payload)
        .map_err(|_| anyhow!("Malformed id_token payload"))?;
    let claims: serde_json::Value = serde_json::from_slice(&bytes)
        .map_err(|_| anyhow!("id_token payload is not valid JSON"))?;
    claims["email"]
        .as_str()
        .map(|s| s.to_string())
        .ok_or_else(|| anyhow!("id_token has no email claim"))
}

/// Minimal page shown in the browser once the redirect has been captured.
/// Rust-produced string; not localized this phase.
const REDIRECT_RESPONSE: &str = "HTTP/1.1 200 OK\r\n\
Content-Type: text/html; charset=utf-8\r\n\
Connection: close\r\n\r\n\
<html><body style=\"font-family:sans-serif;text-align:center;padding-top:3em\">\
<h3>Signed in to Lightweight Cloud Connector</h3>\
<p>You can close this tab and return to the app.</p></body></html>";

// Chromium-family browsers speculatively pre-connect sockets without ever
// sending on them; without a per-connection bound, one such peer parks the
// accept loop until it disconnects, starving the real redirect for the whole
// of REDIRECT_TIMEOUT.
const STRAY_CONNECTION_READ_TIMEOUT: Duration = Duration::from_secs(5);

/// Wait on the loopback listener until the browser delivers the OAuth redirect.
///
/// Browsers may hit the port with unrelated requests (favicon, probes), so
/// connections that carry no `code`/`error` are answered 404 and skipped
/// instead of consuming the one-shot wait. Returns the authorization code.
async fn await_redirect_code(
    listener: tokio::net::TcpListener,
    expected_state: &str,
) -> Result<String> {
    await_redirect_code_with_read_timeout(listener, expected_state, STRAY_CONNECTION_READ_TIMEOUT)
        .await
}

/// Same as [`await_redirect_code`], with the stray-connection read bound as a
/// parameter so tests can use a short one instead of the real 5s — production
/// always goes through `await_redirect_code`, which fixes it at
/// `STRAY_CONNECTION_READ_TIMEOUT`.
async fn await_redirect_code_with_read_timeout(
    listener: tokio::net::TcpListener,
    expected_state: &str,
    stray_read_timeout: Duration,
) -> Result<String> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    loop {
        let (mut socket, _) = listener.accept().await?;
        let mut buf = [0u8; 2048];
        let read = match tokio::time::timeout(stray_read_timeout, socket.read(&mut buf)).await {
            Ok(result) => result.unwrap_or(0),
            Err(_) => continue, // Silent peer: drop it and keep waiting.
        };
        let request_line = String::from_utf8_lossy(&buf[..read])
            .lines()
            .next()
            .unwrap_or("")
            .to_string();

        match parse_redirect_request(&request_line, expected_state) {
            Ok(code) => {
                let _ = socket.write_all(REDIRECT_RESPONSE.as_bytes()).await;
                let _ = socket.flush().await;
                return Ok(code);
            }
            Err(e) if request_line.contains("code=") || request_line.contains("error=") => {
                // A real redirect that failed validation: report it.
                let _ = socket
                    .write_all(b"HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n")
                    .await;
                return Err(e);
            }
            Err(_) => {
                // Stray request (favicon, probe): dismiss and keep waiting.
                let _ = socket
                    .write_all(b"HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n")
                    .await;
            }
        }
    }
}

/// Exchange the authorization code for tokens (PKCE; client secret only when
/// the client was issued one).
async fn exchange_code(code: &str, verifier: &str, redirect_uri: &str) -> Result<OAuthTokens> {
    let mut params = vec![
        ("client_id", OAUTH_CLIENT_ID),
        ("code", code),
        ("code_verifier", verifier),
        ("redirect_uri", redirect_uri),
        ("grant_type", "authorization_code"),
    ];
    if !OAUTH_CLIENT_SECRET.is_empty() {
        params.push(("client_secret", OAUTH_CLIENT_SECRET));
    }

    // Without an explicit timeout, reqwest's default client never times out a
    // request; a blackholed connection (captive portal, dropped route) would
    // hang interactive_login() forever with no way to cancel. REDIRECT_TIMEOUT
    // only bounds the browser leg, not this one.
    //
    // `.build()` is fallible; `unwrap_or_default()` would fall back to
    // `Client::new()`, which reqwest documents as panicking if the TLS
    // backend or resolver fails to initialize — a fallback that panics on the
    // condition it appears to absorb, and one that (had it not panicked)
    // would silently carry no timeout at all. Propagate the error instead.
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
        .map_err(|e| anyhow!("Failed to build the HTTP client: {}", e))?;

    let response = client
        .post(TOKEN_ENDPOINT)
        .form(&params)
        .send()
        .await
        .map_err(|e| anyhow!("Token request failed: {}", e))?;

    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        return Err(anyhow!(
            "Token exchange failed ({}): {}",
            status,
            crate::redact::redact_sensitive(&body)
        ));
    }

    let body: serde_json::Value = response
        .json()
        .await
        .map_err(|e| anyhow!("Token response was not valid JSON: {}", e))?;

    let access_token = body["access_token"]
        .as_str()
        .ok_or_else(|| anyhow!("Token response has no access_token"))?
        .to_string();
    // Without a refresh token the session cannot be restored later, so this is
    // a hard failure rather than a degraded success.
    let refresh_token = body["refresh_token"]
        .as_str()
        .ok_or_else(|| anyhow!("Token response has no refresh_token"))?
        .to_string();
    let id_token = body["id_token"]
        .as_str()
        .ok_or_else(|| anyhow!("Token response has no id_token"))?;
    let expires_in_secs = body["expires_in"].as_u64().unwrap_or(3600);

    Ok(OAuthTokens {
        email: email_from_id_token(id_token)?,
        refresh_token,
        access_token,
        expires_in_secs,
    })
}

/// Run the full interactive sign-in: open the browser, capture the loopback
/// redirect and exchange the code for tokens.
pub async fn interactive_login() -> Result<OAuthTokens> {
    let (verifier, challenge) = generate_pkce();
    let state = generate_state();

    // Loopback only: the redirect must never be reachable off-host.
    let port = crate::tunnel::get_free_port()?;
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", port))
        .await
        .map_err(|e| anyhow!("Failed to open the loopback listener: {}", e))?;
    let redirect_uri = format!("http://127.0.0.1:{}", port);

    let auth_url = build_auth_url(OAUTH_CLIENT_ID, &redirect_uri, &challenge, &state)?;
    // Printed before waiting so a caller with no working `xdg-open` (SSH,
    // headless, minimal container) has a URL to open by hand, and the port to
    // correlate against `ss -ltnp` for manual QA. No long-lived secret is in
    // this URL — the PKCE verifier never appears in it, only its SHA-256
    // challenge; `state` is a one-time anti-CSRF nonce that the browser
    // itself echoes back over the same redirect, not a bearer credential.
    println!("Sign in at (listening on 127.0.0.1:{}):", port);
    println!("  {}", auth_url);
    std::process::Command::new("xdg-open")
        .arg(&auth_url)
        .spawn()
        .map_err(|e| anyhow!("Failed to open the browser (xdg-open): {}", e))?;

    // The listener is dropped when this scope ends, on every path.
    let code = tokio::time::timeout(REDIRECT_TIMEOUT, await_redirect_code(listener, &state))
        .await
        .map_err(|_| anyhow!("Timed out waiting for the browser sign-in to complete"))??;

    exchange_code(&code, &verifier, &redirect_uri).await
}

/// An access token obtained by refreshing a stored refresh token.
pub struct RefreshedToken {
    pub access_token: String,
    pub expires_in_secs: u64,
}

/// Outcome of a refresh attempt. `NeedsReauth` means the stored refresh token
/// is dead and only an interactive sign-in can recover it; anything else that
/// goes wrong is an `Err`, and callers must not treat those as reauth.
pub enum RefreshOutcome {
    Token(RefreshedToken),
    NeedsReauth,
}

/// Whether a non-200 token response means the stored refresh token is dead.
///
/// Google reports a revoked, expired or reauth-requiring grant as
/// `invalid_grant`; Workspace accounts under session control additionally use
/// `rapt_required` / `invalid_rapt`. Everything else (5xx, network) is
/// transient and must not send the user through a sign-in.
fn refresh_failure_needs_reauth(body: &str) -> bool {
    body.contains("invalid_grant")
        || body.contains("rapt_required")
        || body.contains("invalid_rapt")
}

/// Exchange a stored refresh token for an access token. No browser involved.
pub async fn refresh_access_token(refresh_token: &str) -> Result<RefreshOutcome> {
    let mut params = vec![
        ("client_id", OAUTH_CLIENT_ID),
        ("refresh_token", refresh_token),
        ("grant_type", "refresh_token"),
    ];
    if !OAUTH_CLIENT_SECRET.is_empty() {
        params.push(("client_secret", OAUTH_CLIENT_SECRET));
    }

    // Same reasoning as the code exchange: an explicit timeout, and `build()`
    // propagated rather than unwrapped, so a blackholed network cannot hang the
    // caller forever.
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
        .map_err(|e| anyhow!("Failed to build the HTTP client: {}", e))?;

    let response = client
        .post(TOKEN_ENDPOINT)
        .form(&params)
        .send()
        .await
        .map_err(|e| anyhow!("Token refresh request failed: {}", e))?;

    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        if refresh_failure_needs_reauth(&body) {
            return Ok(RefreshOutcome::NeedsReauth);
        }
        return Err(anyhow!(
            "Token refresh failed ({}): {}",
            status,
            crate::redact::redact_sensitive(&body)
        ));
    }

    let body: serde_json::Value = response
        .json()
        .await
        .map_err(|e| anyhow!("Token refresh response was not valid JSON: {}", e))?;

    let access_token = body["access_token"]
        .as_str()
        .ok_or_else(|| anyhow!("Token refresh response has no access_token"))?
        .to_string();
    let expires_in_secs = body["expires_in"].as_u64().unwrap_or(3600);

    Ok(RefreshOutcome::Token(RefreshedToken {
        access_token,
        expires_in_secs,
    }))
}

/// Revoke a refresh token at Google, so it stops working everywhere — not just
/// on this machine.
///
/// `gcloud auth revoke` does exactly this, and dropping it when the account
/// store went native would have left every "removed" account's refresh token
/// valid indefinitely.
pub async fn revoke_refresh_token(refresh_token: &str) -> Result<()> {
    revoke_refresh_token_at(REVOKE_ENDPOINT, refresh_token).await
}

/// The endpoint is a parameter so the failure path can be exercised against a
/// loopback server; production always goes through [`revoke_refresh_token`].
async fn revoke_refresh_token_at(endpoint: &str, refresh_token: &str) -> Result<()> {
    // Same reasoning as `refresh_access_token`: explicit timeout, and `build()`
    // propagated rather than unwrapped.
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
        .map_err(|e| anyhow!("Failed to build the HTTP client: {}", e))?;

    let response = client
        .post(endpoint)
        .form(&[("token", refresh_token)])
        .send()
        .await
        .map_err(|e| anyhow!("Token revocation request failed: {}", e))?;

    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        // The token never appears here: only Google's answer, redacted.
        return Err(anyhow!(
            "Token revocation failed ({}): {}",
            status,
            crate::redact::redact_sensitive(&body)
        ));
    }

    debug!("Revoked a stored refresh token at Google");
    Ok(())
}

/// Run a blocking keyring call off the async runtime.
///
/// `token_store` is synchronous and its keyring backend (zbus with the `tokio`
/// feature) drives its own runtime through `block_on`. Calling it directly from
/// a tokio worker panics with "Cannot start a runtime from within a runtime",
/// so every keyring call reached from an `async` path — `token_store` from this
/// module and from `gcp_rest_client`, and `windows_credentials::storage` —
/// goes through here.
pub(crate) async fn store_call<T, F>(f: F) -> Result<T>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
{
    tokio::task::spawn_blocking(f)
        .await
        .map_err(|e| anyhow!("Token store task failed: {}", e))
}

/// Run the interactive sign-in and persist the account. Returns the e-mail.
///
/// This is the bridge D1 and D2 lacked: without it the token store is never
/// written to. `save_account` marks the account active only when none was.
///
/// Invalidates the process token cache after a successful save: this is
/// reachable directly (not only through `ensure_signed_in`'s `NeedsReauth`
/// branch) — a future "add account" / "switch account" action can call it —
/// and every path here starts a session for a possibly different account, so
/// anything cached for the old one must not be served. Safe with respect to
/// `TOKEN_CACHE`'s lock: this function is never reachable from
/// `get_access_token`, so it never runs while that lock is held.
pub async fn sign_in_and_store() -> Result<String> {
    let tokens = interactive_login().await?;
    let email = tokens.email;
    let refresh_token = tokens.refresh_token;

    let stored_email = email.clone();
    store_call(move || crate::token_store::save_account(&stored_email, &refresh_token)).await??;

    crate::gcp_rest_client::invalidate_cached_access_token().await;

    Ok(email)
}

/// Ensure there is a usable session: refresh the active account's token and, if
/// the refresh token is rejected — or the index names an account whose keyring
/// entry is gone (cleared keyring, new login keychain, deleted out of band) —
/// run the interactive sign-in again. Returns the e-mail of the usable
/// account.
///
/// This is the ONLY place that may open a browser. `get_access_token` must not:
/// background health checks and the Doctor call it, and a browser appearing
/// from an arbitrary API call would be a nasty surprise.
pub async fn ensure_signed_in() -> Result<String> {
    let active = store_call(crate::token_store::active_account).await?;

    let email = match active {
        None => {
            debug!("No active account; starting interactive sign-in");
            return sign_in_and_store().await;
        }
        Some(email) => email,
    };

    let load_email = email.clone();
    let load_result =
        store_call(move || crate::token_store::load_refresh_token(&load_email)).await?;

    let refresh_token = match load_result {
        Ok(token) => token,
        // Distinct, stable wording from `token_store::load_refresh_token`:
        // the index still lists this account but its keyring entry is gone.
        // Without this the app would be wedged forever with no way out short
        // of hand-editing `oauth_accounts.json`.
        Err(e) if e.to_string().starts_with("No stored session for") => {
            debug!(
                "Active account {} has no keyring entry; starting interactive sign-in",
                email
            );
            return sign_in_and_store().await;
        }
        // Anything else (e.g. the keyring itself is unavailable) is not
        // "no usable session" and must not be reinterpreted as one.
        Err(e) => return Err(e),
    };

    debug!("Probing refresh token for {}", email);

    // The probe's token is deliberately discarded: only attempting the refresh
    // reveals a rejected refresh token, which is exactly what this function
    // exists to detect and repair. Do NOT hand it to TOKEN_CACHE from here —
    // this runs outside that lock, and reaching in would risk a deadlock.
    match refresh_access_token(&refresh_token).await? {
        RefreshOutcome::Token(_) => Ok(email),
        RefreshOutcome::NeedsReauth => {
            debug!("Refresh token rejected for {}; starting interactive sign-in", email);
            sign_in_and_store().await
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};

    /// Vector conocido de la RFC 7636 (sección 4.2): fija que el challenge es
    /// base64url-sin-padding de SHA-256(verifier), no otra codificación.
    #[test]
    fn pkce_challenge_matches_rfc7636_vector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
        assert_eq!(
            challenge_from_verifier(verifier),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        );
    }

    #[test]
    fn generate_pkce_is_random_and_consistent() {
        let (v1, c1) = generate_pkce();
        let (v2, _) = generate_pkce();
        assert_ne!(v1, v2, "cada login debe usar un verifier nuevo");
        // RFC 7636: el verifier mide entre 43 y 128 caracteres.
        assert!((43..=128).contains(&v1.len()), "longitud inválida: {}", v1.len());
        assert_eq!(c1, challenge_from_verifier(&v1));
    }

    #[test]
    fn auth_url_carries_the_required_params() {
        let url = build_auth_url(
            "client-abc.apps.googleusercontent.com",
            "http://127.0.0.1:41234",
            "challenge-xyz",
            "state-123",
        )
        .expect("auth url");
        assert!(url.starts_with(AUTH_ENDPOINT));
        assert!(url.contains("client_id=client-abc.apps.googleusercontent.com"));
        assert!(url.contains("code_challenge=challenge-xyz"));
        assert!(url.contains("code_challenge_method=S256"));
        assert!(url.contains("state=state-123"));
        assert!(url.contains("response_type=code"));
        // Sin ambos, Google no devuelve refresh_token en logins repetidos.
        assert!(url.contains("access_type=offline"));
        assert!(url.contains("prompt=consent"));
        // El redirect y los scopes viajan url-encoded.
        assert!(url.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A41234"));
        assert!(url.contains("cloud-platform"));
        // openid + email son los scopes que producen el id_token y su claim
        // `email`; sin ellos la identificación de la cuenta no funciona.
        assert!(url.contains("openid"));
        assert!(url.contains("email"));
    }

    #[test]
    fn redirect_yields_code_when_state_matches() {
        let line = "GET /?code=4/abc-DEF_123&state=st-1 HTTP/1.1";
        assert_eq!(parse_redirect_request(line, "st-1").unwrap(), "4/abc-DEF_123");
    }

    #[test]
    fn redirect_rejects_state_mismatch() {
        let line = "GET /?code=4/abc&state=attacker HTTP/1.1";
        let err = parse_redirect_request(line, "st-1").unwrap_err().to_string();
        assert!(err.contains("state"), "mensaje inesperado: {}", err);
    }

    #[test]
    fn redirect_surfaces_user_denial() {
        let line = "GET /?error=access_denied&state=st-1 HTTP/1.1";
        let err = parse_redirect_request(line, "st-1").unwrap_err().to_string();
        assert!(err.contains("access_denied"), "mensaje inesperado: {}", err);
    }

    #[test]
    fn redirect_rejects_request_without_code() {
        let line = "GET /favicon.ico HTTP/1.1";
        assert!(parse_redirect_request(line, "st-1").is_err());
    }

    #[test]
    fn redirect_rejects_unexpected_path_even_with_valid_state() {
        // Our own redirect_uri has no path; a request against any other path
        // is not the OAuth redirect, whatever query string it carries.
        let line = "GET /callback?code=4/abc&state=st-1 HTTP/1.1";
        let err = parse_redirect_request(line, "st-1").unwrap_err().to_string();
        assert!(err.contains("path"), "mensaje inesperado: {}", err);
    }

    #[test]
    fn redirect_state_is_checked_before_error() {
        // A forged error= with the wrong state must be rejected as a state
        // mismatch, not accepted as a genuine (if negative) redirect.
        let line = "GET /?error=access_denied&state=attacker HTTP/1.1";
        let err = parse_redirect_request(line, "st-1").unwrap_err().to_string();
        assert!(err.contains("state"), "mensaje inesperado: {}", err);
    }

    #[test]
    fn redirect_rejects_empty_code() {
        let line = "GET /?code=&state=st-1 HTTP/1.1";
        let err = parse_redirect_request(line, "st-1").unwrap_err().to_string();
        assert!(err.contains("empty"), "mensaje inesperado: {}", err);
    }

    #[tokio::test]
    async fn stray_request_is_dismissed_then_real_redirect_returns_code() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move { await_redirect_code(listener, "st-1").await });

        // Stray connection (favicon/probe): gets a 404 and must not end the wait.
        let mut stray = tokio::net::TcpStream::connect(addr).await.unwrap();
        stray
            .write_all(b"GET /favicon.ico HTTP/1.1\r\n\r\n")
            .await
            .unwrap();
        let mut buf = [0u8; 256];
        let n = stray.read(&mut buf).await.unwrap();
        assert!(String::from_utf8_lossy(&buf[..n]).starts_with("HTTP/1.1 404"));
        drop(stray);

        // Real redirect on a second connection: valid code + matching state
        // gets a 200 and unblocks the wait.
        let mut real = tokio::net::TcpStream::connect(addr).await.unwrap();
        real.write_all(b"GET /?code=abc123&state=st-1 HTTP/1.1\r\n\r\n")
            .await
            .unwrap();
        let mut buf = [0u8; 256];
        let n = real.read(&mut buf).await.unwrap();
        assert!(String::from_utf8_lossy(&buf[..n]).starts_with("HTTP/1.1 200"));

        let code = server.await.unwrap().unwrap();
        assert_eq!(code, "abc123");
    }

    #[tokio::test]
    async fn silent_peer_is_dropped_after_read_timeout_then_real_redirect_succeeds() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        // A short read timeout keeps this test fast; production always goes
        // through await_redirect_code(), which fixes the bound at the real
        // 5s STRAY_CONNECTION_READ_TIMEOUT.
        let server = tokio::spawn(async move {
            await_redirect_code_with_read_timeout(listener, "st-1", Duration::from_millis(50))
                .await
        });

        // Silent peer: completes the TCP handshake, never writes — mirrors a
        // Chromium-family speculative pre-connect. Held open past the
        // assertion below so the read timeout, not a disconnect, is what
        // unblocks the loop.
        let silent = tokio::net::TcpStream::connect(addr).await.unwrap();

        // Real redirect on a second connection: the loop must have returned
        // to accept() despite the still-open silent peer.
        let mut real = tokio::net::TcpStream::connect(addr).await.unwrap();
        real.write_all(b"GET /?code=xyz789&state=st-1 HTTP/1.1\r\n\r\n")
            .await
            .unwrap();
        let mut buf = [0u8; 256];
        let n = real.read(&mut buf).await.unwrap();
        assert!(String::from_utf8_lossy(&buf[..n]).starts_with("HTTP/1.1 200"));

        let code = server.await.unwrap().unwrap();
        assert_eq!(code, "xyz789");
        drop(silent);
    }

    #[test]
    fn email_is_read_from_the_id_token_payload() {
        let payload = URL_SAFE_NO_PAD.encode(br#"{"email":"user@example.com","sub":"1"}"#);
        let token = format!("header.{}.signature", payload);
        assert_eq!(email_from_id_token(&token).unwrap(), "user@example.com");
    }

    #[test]
    fn email_extraction_rejects_malformed_tokens() {
        assert!(email_from_id_token("not-a-jwt").is_err());
        let no_email = URL_SAFE_NO_PAD.encode(br#"{"sub":"1"}"#);
        assert!(email_from_id_token(&format!("h.{}.s", no_email)).is_err());
    }

    #[test]
    fn dead_grants_are_classified_as_needing_reauth() {
        assert!(refresh_failure_needs_reauth(
            r#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#
        ));
        assert!(refresh_failure_needs_reauth(r#"{"error":"rapt_required"}"#));
        assert!(refresh_failure_needs_reauth(r#"{"error":"invalid_rapt"}"#));
    }

    #[test]
    fn other_refresh_failures_are_treated_as_transient() {
        assert!(!refresh_failure_needs_reauth(r#"{"error":"internal_failure"}"#));
        assert!(!refresh_failure_needs_reauth("502 Bad Gateway"));
        assert!(!refresh_failure_needs_reauth(""));
    }

    /// Servidor HTTP de un solo uso: lee la petición y contesta con
    /// `status_line` y `body`. Devuelve la URL a la que apuntar y un canal por
    /// el que llega la petición recibida, tal cual, para poder afirmar sobre
    /// ella: sin eso, el **nombre del campo** del formulario no lo cubre nada,
    /// y renombrarlo dejaría la revocación muerta con la suite en verde.
    async fn one_shot_http(
        status_line: &'static str,
        body: &'static str,
    ) -> (String, tokio::sync::oneshot::Receiver<String>) {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let (tx, rx) = tokio::sync::oneshot::channel();
        tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut buf = [0u8; 2048];
            let n = socket.read(&mut buf).await.unwrap_or(0);
            let _ = tx.send(String::from_utf8_lossy(&buf[..n]).into_owned());
            let response = format!(
                "{}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                status_line,
                body.len(),
                body
            );
            let _ = socket.write_all(response.as_bytes()).await;
            let _ = socket.shutdown().await;
        });
        (format!("http://{}", addr), rx)
    }

    #[tokio::test]
    async fn revoke_succeeds_on_200() {
        let (url, request) = one_shot_http("HTTP/1.1 200 OK", "").await;
        assert!(revoke_refresh_token_at(&url, "rt-abc").await.is_ok());

        // Google exige el campo `token`. Con otro nombre contesta 400,
        // `revoke_then_delete` se traga el error por diseño y la cuenta se
        // borra en local con el refresh token vivo: regresión silenciosa.
        let request = request.await.expect("el servidor debe haber leído la petición");
        assert!(
            request.contains("token=rt-abc"),
            "la petición de revocación no lleva `token=<refresh token>`: {}",
            request
        );
    }

    /// Un fallo de revocación no puede filtrar el token en el mensaje: ese
    /// mensaje acaba en el log y en la UI.
    #[tokio::test]
    async fn a_failed_revoke_never_names_the_token() {
        let (url, _request) = one_shot_http(
            "HTTP/1.1 400 Bad Request",
            r#"{"error":"invalid_token"}"#,
        )
        .await;

        let err = revoke_refresh_token_at(&url, "rt-SUPER-SECRET-123")
            .await
            .expect_err("un 400 debe ser error")
            .to_string();

        assert!(
            !err.contains("rt-SUPER-SECRET-123"),
            "el mensaje de error filtró el refresh token: {}",
            err
        );
        assert!(err.contains("400"), "el mensaje debe conservar el status: {}", err);
    }
}
