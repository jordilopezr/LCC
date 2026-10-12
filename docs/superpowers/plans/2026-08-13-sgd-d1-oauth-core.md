# SG-D / D1: núcleo OAuth propio — Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implementar el flujo OAuth interactivo propio de LCC (authorization code + PKCE S256 + redirección loopback) como módulo Rust autocontenido, con las partes puras cubiertas por tests y un ejemplo ejecutable que valida el flujo real.

**Architecture:** Un módulo nuevo `native/src/oauth.rs` con cuatro helpers **puros** (PKCE, URL de autorización, parseo del redirect, email del `id_token`) testeables sin red, más `interactive_login()`, que orquesta: listener loopback en puerto efímero → `xdg-open` → validación del redirect → canje del código. Sin bridge, sin Dart, sin regen.

**Tech Stack:** Rust (`native/`), `tokio` (net/time), `reqwest` (form POST + `Url` para query strings), `sha2` (nueva), `base64`, `rand`, `serde_json`. `cargo test` + `cargo run --example`.

**Spec:** `docs/superpowers/specs/2026-08-13-sgd-d1-oauth-core-design.md`

## Global Constraints

- **Solo Rust**, únicamente `native/` (`Cargo.toml`, `src/lib.rs`, `src/oauth.rs`, `examples/oauth_login.rs`) + un doc de QA. **No** Dart, **no** regen del bridge, **no** `dart format`.
- **Una sola dependencia nueva: `sha2`.** No añadir servidor HTTP ni crates de OAuth.
- Constantes exactas (van embebidas; el client_id es público por diseño en clients de escritorio):
  - `OAUTH_CLIENT_ID = "743123147934-plp891qo2a44ie5jop1ud7n445gduk0h.apps.googleusercontent.com"`
  - `OAUTH_CLIENT_SECRET = ""` (vacío = solo PKCE; si la consola emitió secreto se rellena después, y el canje lo incluye **solo** si no está vacío)
  - `AUTH_ENDPOINT = "https://accounts.google.com/o/oauth2/v2/auth"`
  - `TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token"`
  - `SCOPES = "https://www.googleapis.com/auth/cloud-platform openid email"`
  - `REDIRECT_TIMEOUT = Duration::from_secs(300)`
- La URL de autorización **debe** incluir `code_challenge_method=S256`, `access_type=offline` y `prompt=consent` (sin `prompt=consent`, Google omite el `refresh_token` en logins posteriores).
- **Seguridad:** listener **solo** en `127.0.0.1` (nunca `0.0.0.0`), cerrado siempre (éxito, error o timeout); `state` comparado en **tiempo constante**; **jamás** loguear ni imprimir el `refresh_token` ni el `access_token` completo; usar `redact_sensitive()` en cualquier traza de error de red.
- Error explícito si la respuesta del canje no trae `refresh_token`.
- Mensajes de error en **inglés** (capa Rust, sin localizar en esta fase).
- Verificar: `cargo test` verde, `cargo build --release` limpio y sin warnings nuevos, `flutter test` (suite) verde.
- **Commits de código NO llevan trailer `Co-Authored-By`** (solo docs). Rama `27H1-Preview`.

---

### Task 1: Dependencia, módulo y los cuatro helpers puros (TDD)

Todo lo testeable sin red ni navegador. Deliverable: `oauth.rs` compila y sus tests puros pasan.

**Files:**
- Modify: `native/Cargo.toml` (añadir `sha2`)
- Modify: `native/src/lib.rs` (añadir `pub mod oauth;`)
- Create: `native/src/oauth.rs` (constantes + 5 fns puras + módulo de tests)

**Interfaces:**
- Produce (consumido por Task 2): `fn challenge_from_verifier(&str) -> String`, `fn generate_pkce() -> (String, String)`, `fn build_auth_url(client_id: &str, redirect_uri: &str, challenge: &str, state: &str) -> Result<String>`, `fn parse_redirect_request(request_line: &str, expected_state: &str) -> Result<String>`, `fn email_from_id_token(id_token: &str) -> Result<String>`, y las constantes del bloque Global Constraints.

- [ ] **Step 1: Añadir la dependencia `sha2`**

En `native/Cargo.toml`, en `[dependencies]` (mantener el orden alfabético del bloque):

```toml
sha2 = "0.10"
```

- [ ] **Step 2: Declarar el módulo**

En `native/src/lib.rs`, junto a los demás `pub mod`, añadir:

```rust
pub mod oauth;  // 27H1 SG-D: own OAuth (authorization code + PKCE + loopback)
```

- [ ] **Step 3: Escribir los tests puros (fallan: el módulo aún no existe)**

Crear `native/src/oauth.rs` conteniendo **solo** el módulo de tests por ahora:

```rust
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
}
```

- [ ] **Step 4: Comprobar que fallan (no compila)**

Run: `cd native && cargo test oauth 2>&1 | tail -20`
Expected: error de compilación — `challenge_from_verifier`, `build_auth_url`, etc. no existen.

- [ ] **Step 5: Implementar las constantes y los helpers puros**

En `native/src/oauth.rs`, **encima** del módulo de tests:

```rust
//! LCC's own OAuth 2.0 client: authorization code + PKCE with a loopback
//! redirect, modelled on how IAP Desktop authenticates without the gcloud CLI.
//!
//! The client ID is public by design for installed apps — PKCE, not a secret,
//! is what protects the exchange.

use anyhow::{anyhow, Result};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use sha2::{Digest, Sha256};
use std::time::Duration;

const OAUTH_CLIENT_ID: &str =
    "743123147934-plp891qo2a44ie5jop1ud7n445gduk0h.apps.googleusercontent.com";
/// Desktop clients may be issued a non-confidential secret. Empty = PKCE only;
/// when set, it is sent with the code exchange.
const OAUTH_CLIENT_SECRET: &str = "";
const AUTH_ENDPOINT: &str = "https://accounts.google.com/o/oauth2/v2/auth";
const TOKEN_ENDPOINT: &str = "https://oauth2.googleapis.com/token";
const SCOPES: &str = "https://www.googleapis.com/auth/cloud-platform openid email";
const REDIRECT_TIMEOUT: Duration = Duration::from_secs(300);

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
/// (e.g. `GET /?code=…&state=… HTTP/1.1`), validating `state` first.
fn parse_redirect_request(request_line: &str, expected_state: &str) -> Result<String> {
    let target = request_line
        .split_whitespace()
        .nth(1)
        .ok_or_else(|| anyhow!("Malformed HTTP request from browser"))?;
    let url = reqwest::Url::parse(&format!("http://127.0.0.1{}", target))
        .map_err(|_| anyhow!("Malformed redirect URL from browser"))?;

    let (mut code, mut state, mut error) = (None, None, None);
    for (key, value) in url.query_pairs() {
        match key.as_ref() {
            "code" => code = Some(value.into_owned()),
            "state" => state = Some(value.into_owned()),
            "error" => error = Some(value.into_owned()),
            _ => {}
        }
    }

    if let Some(error) = error {
        return Err(anyhow!("Google returned an authorization error: {}", error));
    }
    let state = state.ok_or_else(|| anyhow!("Redirect carried no state parameter"))?;
    if !constant_time_eq(&state, expected_state) {
        return Err(anyhow!("OAuth state mismatch — ignoring the redirect"));
    }
    code.ok_or_else(|| anyhow!("Redirect carried no authorization code"))
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
```

**Nota sobre warnings:** en este task, `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET`, `TOKEN_ENDPOINT`, `REDIRECT_TIMEOUT`, `OAuthTokens`, `generate_state` y `generate_pkce` aún no tienen consumidor (llega en Task 2). Si `cargo build` avisa de código sin usar, **no** añadir `#[allow(dead_code)]`: Task 2 los consume y el aviso desaparece. Basta con que `cargo test` pase; comprobar en Task 2 que no queda ningún warning.

- [ ] **Step 6: Comprobar que pasan**

Run: `cd native && cargo test oauth 2>&1 | tail -20`
Expected: los 9 tests del módulo pasan.

- [ ] **Step 7: Suite Rust completa**

Run: `cd native && cargo test 2>&1 | tail -10`
Expected: toda la suite verde (nada roto por el módulo nuevo).

- [ ] **Step 8: Commit** (código — SIN trailer `Co-Authored-By`)

```bash
cd /home/jlopezre/GitHub/LCC
git add native/Cargo.toml native/Cargo.lock native/src/lib.rs native/src/oauth.rs
git commit -m "feat(oauth): PKCE, auth URL, redirect parsing and id_token email helpers"
```

---

### Task 2: `interactive_login()` + ejemplo ejecutable

La parte con efectos (listener, navegador, red). No es unit-testeable; se valida con el ejemplo.

**Files:**
- Modify: `native/src/oauth.rs` (añadir `interactive_login` y sus auxiliares)
- Create: `native/examples/oauth_login.rs`

**Interfaces:**
- Consume (de Task 1): `generate_pkce()`, `generate_state()`, `build_auth_url()`, `parse_redirect_request()`, `email_from_id_token()`, `OAuthTokens`, y las constantes `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET`, `TOKEN_ENDPOINT`, `REDIRECT_TIMEOUT`.
- Consume (existente en el repo): `crate::tunnel::get_free_port()` (es `pub(crate)`), `crate::redact::redact_sensitive()`.
- Produce: `pub async fn interactive_login() -> Result<OAuthTokens>`.

- [ ] **Step 1: Implementar el listener loopback**

En `native/src/oauth.rs`, añadir (debajo de los helpers puros):

```rust
/// Minimal page shown in the browser once the redirect has been captured.
/// Rust-produced string; not localized this phase.
const REDIRECT_RESPONSE: &str = "HTTP/1.1 200 OK\r\n\
Content-Type: text/html; charset=utf-8\r\n\
Connection: close\r\n\r\n\
<html><body style=\"font-family:sans-serif;text-align:center;padding-top:3em\">\
<h3>Signed in to Lightweight Cloud Connector</h3>\
<p>You can close this tab and return to the app.</p></body></html>";

/// Wait on the loopback listener until the browser delivers the OAuth redirect.
///
/// Browsers may hit the port with unrelated requests (favicon, probes), so
/// connections that carry no `code`/`error` are answered 404 and skipped
/// instead of consuming the one-shot wait. Returns the authorization code.
async fn await_redirect_code(
    listener: tokio::net::TcpListener,
    expected_state: &str,
) -> Result<String> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    loop {
        let (mut socket, _) = listener.accept().await?;
        let mut buf = [0u8; 2048];
        let read = socket.read(&mut buf).await.unwrap_or(0);
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
```

- [ ] **Step 2: Implementar el canje del código**

Añadir a `native/src/oauth.rs`:

```rust
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

    let response = reqwest::Client::new()
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
```

- [ ] **Step 3: Implementar `interactive_login`**

Añadir a `native/src/oauth.rs`:

```rust
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
```

- [ ] **Step 4: Escribir el ejemplo ejecutable**

Crear `native/examples/oauth_login.rs` (mismo estilo de cabecera que `native/examples/transfer_bench.rs`):

```rust
//! Manual end-to-end check of LCC's own OAuth sign-in (SG-D / D1).
//!
//! Usage: cargo run --example oauth_login
//!
//! Opens the browser, completes the authorization-code + PKCE flow against
//! LCC's OAuth client and prints who signed in. Secrets are never printed in
//! full: the refresh token is reported only as present/absent and the access
//! token only by a short prefix.

fn main() {
    let result = native::logging::block_on(native::oauth::interactive_login());

    match result {
        Ok(tokens) => {
            let prefix: String = tokens.access_token.chars().take(12).collect();
            println!("✓ Signed in as: {}", tokens.email);
            println!("  refresh token: {}", if tokens.refresh_token.is_empty() { "MISSING" } else { "received" });
            println!("  access token:  {}… ({} chars)", prefix, tokens.access_token.len());
            println!("  expires in:    {} s", tokens.expires_in_secs);
        }
        Err(e) => {
            eprintln!("✗ Sign-in failed: {}", e);
            std::process::exit(1);
        }
    }
}
```

- [ ] **Step 5: Compilar el ejemplo y la suite**

Run: `cd native && cargo build --example oauth_login 2>&1 | tail -10`
Expected: compila sin errores. Si aparece un warning de código sin usar de Task 1, resolverlo consumiendo el elemento o eliminándolo — **no** silenciarlo con `#[allow(dead_code)]`.

Run: `cd native && cargo test 2>&1 | tail -10`
Expected: la suite Rust sigue verde.

- [ ] **Step 6: Build release + suite Flutter**

Run: `cd native && cargo build --release 2>&1 | tail -6`
Expected: limpio, sin warnings nuevos.

Run: `cd /home/jlopezre/GitHub/LCC && flutter test 2>&1 | tail -6`
Expected: suite Flutter verde (D1 no toca Dart).

- [ ] **Step 7: Commit** (código — SIN trailer `Co-Authored-By`)

```bash
cd /home/jlopezre/GitHub/LCC
git add native/src/oauth.rs native/examples/oauth_login.rs
git commit -m "feat(oauth): interactive loopback sign-in flow plus a runnable example"
```

---

### Task 3: Checklist de QA manual

El flujo real necesita un navegador y una cuenta Google; esto documenta la validación humana.

**Files:**
- Create: `docs/superpowers/plans/2026-08-13-sgd-d1-oauth-core-manual-qa.md`

- [ ] **Step 1: Confirmar la verja**

Run: `cd native && cargo test 2>&1 | tail -6` — Expected: verde.
Run: `cd /home/jlopezre/GitHub/LCC && flutter test 2>&1 | tail -6` — Expected: suite verde.

- [ ] **Step 2: Escribir el checklist**

Crear `docs/superpowers/plans/2026-08-13-sgd-d1-oauth-core-manual-qa.md`:

```markdown
# QA manual — SG-D / D1: núcleo OAuth

El flujo necesita navegador y cuenta Google real, así que no es testeable en CI.
Ejecutar desde `native/`: `cargo run --example oauth_login`

Requisito previo: la cuenta debe estar añadida como **test user** en la pantalla
de consentimiento (estado *Testing*) del proyecto dueño del client OAuth.

- [ ] Se abre el navegador en la pantalla de consentimiento de Google.
- [ ] La pantalla muestra los permisos esperados (Google Cloud + email) y el nombre de la app.
- [ ] Tras aceptar, el navegador muestra "Signed in to Lightweight Cloud Connector" y se puede cerrar la pestaña.
- [ ] La consola imprime el **email correcto** de la cuenta usada.
- [ ] La consola indica `refresh token: received` (no `MISSING`).
- [ ] **Segundo login** con la misma cuenta: vuelve a indicar `refresh token: received` (esto valida `prompt=consent`).
- [ ] **Cancelar** el consentimiento en el navegador: el ejemplo termina con un error que menciona `access_denied`, sin quedarse colgado.
- [ ] **Timeout**: lanzar el ejemplo y no completar el login deja el proceso esperando y termina con error de timeout (no requiere esperar los 5 min completos si se cancela a mano).
- [ ] Ni el refresh token ni el access token completo aparecen en la salida (solo "received" y un prefijo corto).
- [ ] Tras cerrar el ejemplo, el puerto local queda libre (`ss -ltnp | grep 127.0.0.1` no muestra el listener).
```

- [ ] **Step 3: Commit** (docs)

```bash
cd /home/jlopezre/GitHub/LCC
git add docs/superpowers/plans/2026-08-13-sgd-d1-oauth-core-manual-qa.md
git commit -m "docs(qa): manual QA checklist for SG-D/D1 OAuth core"
```

---

## Self-Review

**1. Spec coverage:**
- Módulo `oauth.rs` + `pub mod oauth;` + dependencia `sha2` → Task 1 Steps 1-2, 5. ✓
- Constantes exactas (client_id, secret condicional, endpoints, scopes, timeout) → Task 1 Step 5 + Global Constraints. ✓
- `OAuthTokens` + `interactive_login()` como superficie pública → Task 1 Step 5 (struct) y Task 2 Step 3 (fn). ✓
- Flujo de 7 pasos (PKCE → listener → navegador → redirect → respuesta HTML → canje → email) → Task 2 Steps 1-3. ✓
- Seguridad: loopback-only, listener cerrado siempre, `state` en tiempo constante, sin secretos en logs, error si falta refresh_token → Task 2 Steps 1-3 + Global Constraints. ✓
- Cuatro grupos de helpers puros con tests (PKCE/RFC 7636, auth URL, parseo redirect, email) → Task 1 Steps 3, 5-6. ✓
- `access_type=offline` + `prompt=consent` → Task 1 Step 5 y aserción en el test del Step 3. ✓
- Ejemplo ejecutable → Task 2 Step 4. ✓
- Verificación (cargo test, build release, flutter test, QA manual) → Task 2 Steps 5-6 + Task 3. ✓
- Sin bridge/Dart/regen → Global Constraints. ✓

**2. Placeholder scan:** Sin TBD/TODO. Todo el código (helpers, tests, flujo, ejemplo, checklist) está escrito. `OAUTH_CLIENT_SECRET = ""` no es un placeholder: es la rama documentada "solo PKCE", con el comportamiento condicional especificado.

**Desviación consciente respecto al spec, señalada:** el spec dice "aceptar **una** conexión"; el plan implementa un bucle que descarta peticiones sin `code`/`error` (favicon, sondas del navegador) y solo entonces resuelve. Mantiene las propiedades de seguridad (loopback-only, cerrado siempre, un único redirect atendido) y evita que una petición perdida consuma la espera. ✓

**3. Type consistency:** `challenge_from_verifier(&str) -> String`, `generate_pkce() -> (String, String)`, `generate_state() -> String`, `build_auth_url(&str,&str,&str,&str) -> Result<String>`, `parse_redirect_request(&str,&str) -> Result<String>`, `email_from_id_token(&str) -> Result<String>` coinciden entre definición (Task 1), tests (Task 1 Step 3) y uso (Task 2). `OAuthTokens{email, refresh_token, access_token, expires_in_secs}` coincide entre struct (Task 1), `exchange_code` (Task 2 Step 2) y el ejemplo (Task 2 Step 4). El ejemplo usa `native::logging::block_on` y `native::oauth::interactive_login`, ambos `pub`. `get_free_port()` es `pub(crate)` y se llama desde dentro del crate. ✓
