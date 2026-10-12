# SG-D / D3: adquisición de token nativa — Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cerrar el ciclo de sesión propia — guardar la cuenta tras el login de D1, obtener access tokens refrescando el refresh token de D2, y recuperarse cuando Google lo rechaza — todo detrás de un flag, con gcloud intacto por defecto.

**Architecture:** Todo lo nuevo vive en `native/src/oauth.rs` (flag, refresco, puente al almacén, recuperación) más una rama nativa en `GcpAuthClient::get_access_token()`, el único punto por el que pasan los 10 call sites del crate. `token_store` es síncrono y su backend de keyring arrastra su propio runtime, así que **toda** llamada desde aquí va por `spawn_blocking`.

**Tech Stack:** Rust, `reqwest`, `tokio`, `anyhow`, `serde_json` (todas ya presentes; **cero dependencias nuevas**).

**Spec:** `docs/superpowers/specs/2026-08-14-sgd-d3-native-token-design.md`

## Global Constraints

- **Solo Rust**, y solo estos ficheros: `native/src/oauth.rs`, `native/src/gcp_rest_client.rs`, `native/examples/auth_native.rs`, más un doc de QA. No Dart, no regen del bridge, no `dart format`.
- **Cero dependencias nuevas.**
- **Flag:** `LCC_AUTH_ENGINE=native` opta al camino nativo; sin variable (o `gcloud`) → comportamiento actual **intacto**. Polaridad **inversa** a `parse_tunnel_engine` de `tunnel.rs`: allí Native es el default, aquí es opt-in.
- **Sin fallback:** con el flag activo el token sale solo del refresh token propio. Un fallo se reporta, nunca se cae a gcloud en silencio.
- **`spawn_blocking` obligatorio** en toda llamada a `token_store`: es síncrono y su backend (zbus con feature `tokio`) usa su propio runtime vía `block_on`, que **paniquea** ("Cannot start a runtime from within a runtime") si se le llama desde un worker de tokio activo. `get_access_token()` corre exactamente ahí.
- **Nunca abrir el navegador desde `get_access_token()`**: lo llaman chequeos de salud en segundo plano y el Doctor. El relanzamiento del login vive solo en `ensure_signed_in()`.
- **`invalidate_cached_access_token()` toma el lock de `TOKEN_CACHE`** y el mutex de tokio no es reentrante: **jamás** llamarla sosteniendo ese lock.
- **El token del sondeo de `ensure_signed_in` se descarta**; no pasarlo al caché desde fuera (reintroduciría el deadlock anterior).
- Secretos nunca en claro: cuerpos de error por `redact::redact_sensitive`; el ejemplo imprime como mucho un prefijo del access token.
- Mensajes de error **en inglés** (se localizan en D4). El texto de reauth debe ser **estable**: D4 lo clasificará.
- **Prohibido `#[allow(dead_code)]`** o silenciar lints.
- Verificar: `cargo test` verde, `cargo build --release` sin warnings nuevos, `flutter test` intacto.
- **Commits de código NO llevan trailer `Co-Authored-By`** (solo docs). Rama `27H1-Preview`.

---

### Task 1: Flag, refresco y clasificación del fallo (TDD)

Las piezas puras y la llamada de refresco. Sin tocar el almacén ni `get_access_token` todavía.

**Files:**
- Modify: `native/src/oauth.rs`

**Interfaces:**
- Consume (ya en el fichero): las constantes privadas `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET`, `TOKEN_ENDPOINT`; `crate::redact::redact_sensitive`.
- Produce: `pub enum AuthEngine { Gcloud, Native }`; `pub fn auth_engine() -> AuthEngine`; `pub struct RefreshedToken { pub access_token: String, pub expires_in_secs: u64 }`; `pub enum RefreshOutcome { Token(RefreshedToken), NeedsReauth }`; `pub async fn refresh_access_token(&str) -> Result<RefreshOutcome>`; y los privados `parse_auth_engine`, `refresh_failure_needs_reauth`.

- [ ] **Step 1: Escribir los tests**

En el módulo `mod tests` de `native/src/oauth.rs`, añadir al final:

```rust
    #[test]
    fn auth_engine_defaults_to_gcloud() {
        assert_eq!(parse_auth_engine(None), AuthEngine::Gcloud);
        assert_eq!(parse_auth_engine(Some("gcloud")), AuthEngine::Gcloud);
        assert_eq!(parse_auth_engine(Some("garbage")), AuthEngine::Gcloud);
    }

    #[test]
    fn auth_engine_native_is_opt_in() {
        assert_eq!(parse_auth_engine(Some("native")), AuthEngine::Native);
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
```

- [ ] **Step 2: Verificar que fallan (no compila)**

Run: `cd native && cargo test oauth 2>&1 | tail -15`
Expected: error de compilación — `cannot find function \`parse_auth_engine\``, `cannot find type \`AuthEngine\``, etc. RED del TDD.

- [ ] **Step 3: Implementar el flag**

En `native/src/oauth.rs`, tras las constantes (después de `const REDIRECT_TIMEOUT`), añadir:

```rust
/// Which credential source serves access tokens.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthEngine {
    Gcloud,
    Native,
}

/// Pure parse of the auth engine selector (testable without env).
///
/// gcloud is the default and only an explicit `native` opts in — the opposite
/// polarity to `tunnel::parse_tunnel_engine`, whose native path is already the
/// default. LCC's own session has not been field-validated yet; D5 flips this.
fn parse_auth_engine(val: Option<&str>) -> AuthEngine {
    match val {
        Some("native") => AuthEngine::Native,
        _ => AuthEngine::Gcloud,
    }
}

/// Read `LCC_AUTH_ENGINE`. gcloud is the default; `native` opts into LCC's own
/// OAuth session. Rollout aid; deliberately not exposed in Settings.
pub fn auth_engine() -> AuthEngine {
    parse_auth_engine(std::env::var("LCC_AUTH_ENGINE").ok().as_deref())
}
```

- [ ] **Step 4: Implementar el refresco y su clasificación**

Al final de `native/src/oauth.rs`, **antes** del `#[cfg(test)] mod tests`, añadir:

```rust
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
```

- [ ] **Step 5: Verificar que pasan**

Run: `cd native && cargo test oauth 2>&1 | tail -15`
Expected: los 4 tests nuevos pasan, junto a los ya existentes del módulo.

- [ ] **Step 6: Suite y release**

Run: `cd native && cargo test 2>&1 | tail -6`
Expected: suite Rust verde.

Run: `cd native && cargo build --release 2>&1 | tail -5`
Expected: sin warnings nuevos. (`parse_auth_engine` lo consume `auth_engine`, y `refresh_failure_needs_reauth` lo consume `refresh_access_token`, así que no queda código sin usar.)

- [ ] **Step 7: Commit** (código — SIN trailer `Co-Authored-By`)

```bash
cd /home/jlopezre/GitHub/LCC
git add native/src/oauth.rs
git commit -m "feat(auth): LCC_AUTH_ENGINE flag and native refresh-token exchange"
```

---

### Task 2: Puente al almacén y recuperación explícita

Conecta D1 con D2 (hoy nadie escribe en el almacén) y añade la única función que puede relanzar el navegador.

**Files:**
- Modify: `native/src/oauth.rs`

**Interfaces:**
- Consume: `interactive_login() -> Result<OAuthTokens>` con `OAuthTokens { email, refresh_token, access_token, expires_in_secs }` (mismo fichero); `refresh_access_token(&str) -> Result<RefreshOutcome>` y `RefreshOutcome::{Token, NeedsReauth}` (Task 1); `crate::token_store::{active_account, load_refresh_token, save_account}` (síncronas); `crate::gcp_rest_client::invalidate_cached_access_token()`.
- Produce: `pub async fn sign_in_and_store() -> Result<String>`; `pub async fn ensure_signed_in() -> Result<String>`.

- [ ] **Step 1: Añadir el helper de `spawn_blocking`**

En `native/src/oauth.rs`, tras `refresh_access_token`, añadir:

```rust
/// Run a `token_store` call off the async runtime.
///
/// `token_store` is synchronous and its keyring backend (zbus with the `tokio`
/// feature) drives its own runtime through `block_on`. Calling it directly from
/// a tokio worker panics with "Cannot start a runtime from within a runtime",
/// so every call from this module goes through here.
async fn store_call<T, F>(f: F) -> Result<T>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
{
    tokio::task::spawn_blocking(f)
        .await
        .map_err(|e| anyhow!("Token store task failed: {}", e))
}
```

- [ ] **Step 2: Añadir el puente D1→D2**

A continuación:

```rust
/// Run the interactive sign-in and persist the account. Returns the e-mail.
///
/// This is the bridge D1 and D2 lacked: without it the token store is never
/// written to. `save_account` marks the account active only when none was.
pub async fn sign_in_and_store() -> Result<String> {
    let tokens = interactive_login().await?;
    let email = tokens.email;
    let refresh_token = tokens.refresh_token;

    let stored_email = email.clone();
    store_call(move || crate::token_store::save_account(&stored_email, &refresh_token)).await??;

    Ok(email)
}
```

- [ ] **Step 3: Añadir la recuperación explícita**

A continuación:

```rust
/// Ensure there is a usable session: refresh the active account's token and, if
/// the refresh token is rejected, run the interactive sign-in again. Returns
/// the e-mail of the usable account.
///
/// This is the ONLY place that may open a browser. `get_access_token` must not:
/// background health checks and the Doctor call it, and a browser appearing
/// from an arbitrary API call would be a nasty surprise.
pub async fn ensure_signed_in() -> Result<String> {
    let active = store_call(crate::token_store::active_account).await?;

    let email = match active {
        None => return sign_in_and_store().await,
        Some(email) => email,
    };

    let load_email = email.clone();
    let refresh_token =
        store_call(move || crate::token_store::load_refresh_token(&load_email)).await??;

    // The probe's token is deliberately discarded: only attempting the refresh
    // reveals a rejected refresh token, which is exactly what this function
    // exists to detect and repair. Do NOT hand it to TOKEN_CACHE from here —
    // this runs outside that lock, and reaching in would risk a deadlock.
    match refresh_access_token(&refresh_token).await? {
        RefreshOutcome::Token(_) => Ok(email),
        RefreshOutcome::NeedsReauth => {
            let email = sign_in_and_store().await?;
            // A fresh session invalidates anything cached for the old one.
            crate::gcp_rest_client::invalidate_cached_access_token().await;
            Ok(email)
        }
    }
}
```

- [ ] **Step 4: Compilar y correr la suite**

Run: `cd native && cargo test 2>&1 | tail -6`
Expected: compila y la suite sigue verde. (Estas funciones no tienen test unitario: abren navegador y tocan el keyring; las cubre el ejemplo de la Task 3.)

Run: `cd native && cargo build --release 2>&1 | tail -5`
Expected: sin warnings nuevos.

- [ ] **Step 5: Verificar la regla de `spawn_blocking`**

Run: `cd native && grep -n 'token_store::' src/oauth.rs`
Expected: **toda** aparición está dentro de un `store_call(...)`. Si alguna llamada a `token_store` quedara fuera, corregirla antes de commitear — es la trampa que paniquea en runtime.

- [ ] **Step 6: Commit** (código — SIN trailer `Co-Authored-By`)

```bash
cd /home/jlopezre/GitHub/LCC
git add native/src/oauth.rs
git commit -m "feat(auth): persist the sign-in and add explicit session recovery"
```

---

### Task 3: Rama nativa en `get_access_token` + ejemplo ejecutable

El punto de integración y su verificación de punta a punta.

**Files:**
- Modify: `native/src/gcp_rest_client.rs` (`get_access_token`, ~líneas 148-183)
- Create: `native/examples/auth_native.rs`

**Interfaces:**
- Consume: `crate::oauth::{auth_engine, AuthEngine, refresh_access_token, RefreshOutcome, ensure_signed_in}`; `crate::token_store::{active_account, load_refresh_token}`.
- Produce: `GcpAuthClient::token_from_native_session()` (privada).

- [ ] **Step 1: Añadir la rama nativa en `get_access_token`**

En `native/src/gcp_rest_client.rs`, dentro de `get_access_token`, sustituir:

```rust
        let token = match self.token_from_gcloud_cli().await {
```
por:

```rust
        if crate::oauth::auth_engine() == crate::oauth::AuthEngine::Native {
            let token = self.token_from_native_session().await?;
            *cache = Some(CachedToken {
                token: token.clone(),
                fetched_at: Instant::now(),
            });
            return Ok(token);
        }

        let token = match self.token_from_gcloud_cli().await {
```

El resto de la función (la cadena gcloud→ADC y el cacheo final) **no se toca**: con el flag apagado el comportamiento es idéntico al actual.

- [ ] **Step 2: Añadir el obtentor nativo**

En el mismo `impl GcpAuthClient`, tras `get_access_token`, añadir:

```rust
    /// Access token from LCC's own stored session (SG-D). No gcloud and no
    /// fallback: a failure here is reported, never masked.
    ///
    /// Every `token_store` call goes through `spawn_blocking` — the store is
    /// synchronous and its keyring backend drives its own runtime, which panics
    /// if entered from a tokio worker. This function runs on one.
    async fn token_from_native_session(&self) -> Result<String> {
        let active = tokio::task::spawn_blocking(crate::token_store::active_account)
            .await
            .map_err(|e| anyhow!("Token store task failed: {}", e))?;
        let email = active.ok_or_else(|| {
            anyhow!("No signed-in Google Cloud account. Sign in to continue.")
        })?;

        let load_email = email.clone();
        let refresh_token =
            tokio::task::spawn_blocking(move || crate::token_store::load_refresh_token(&load_email))
                .await
                .map_err(|e| anyhow!("Token store task failed: {}", e))??;

        match crate::oauth::refresh_access_token(&refresh_token).await? {
            crate::oauth::RefreshOutcome::Token(t) => Ok(t.access_token),
            // Stable wording: D4 classifies on it to raise the reauth banner.
            // The browser is NOT opened here — see oauth::ensure_signed_in.
            crate::oauth::RefreshOutcome::NeedsReauth => Err(anyhow!(
                "Your Google Cloud session needs to be renewed: sign in again."
            )),
        }
    }
```

- [ ] **Step 3: Crear el ejemplo**

Crear `native/examples/auth_native.rs`:

```rust
//! Manual end-to-end check of LCC's own token session (SG-D / D3).
//!
//! Usage: LCC_AUTH_ENGINE=native cargo run --example auth_native
//!
//! Ensures a stored session exists — signing in through the browser only when
//! there is none or the stored refresh token was rejected — and then asks the
//! REST client for an access token through the native path.
//!
//! Run it TWICE: the second run must NOT open a browser. That is the proof the
//! refresh token in the keyring is doing its job. Secrets are never printed in
//! full: only a short prefix of the access token.

fn main() {
    let result = native::logging::block_on(async {
        let email = native::oauth::ensure_signed_in().await?;
        let auth = native::gcp_rest_client::GcpAuthClient::get_or_init()?;
        let token = auth.get_access_token().await?;
        Ok::<_, anyhow::Error>((email, token))
    });

    match result {
        Ok((email, token)) => {
            let prefix: String = token.chars().take(12).collect();
            println!("✓ Session ready for: {}", email);
            println!("  engine:       {:?}", native::oauth::auth_engine());
            println!("  access token: {}… ({} chars)", prefix, token.len());
        }
        Err(e) => {
            eprintln!("✗ Native auth failed: {}", e);
            std::process::exit(1);
        }
    }
}
```

- [ ] **Step 4: Compilar el ejemplo**

Run: `cd native && cargo build --example auth_native 2>&1 | tail -6`
Expected: compila sin errores ni warnings.

- [ ] **Step 5: Verificar que el camino gcloud sigue intacto**

Run: `cd native && cargo test 2>&1 | tail -6`
Expected: suite Rust verde.

Run: `cd native && cargo build --release 2>&1 | tail -5`
Expected: sin warnings nuevos.

Run: `cd /home/jlopezre/GitHub/LCC && flutter test 2>&1 | tail -5`
Expected: suite Flutter verde (D3 no toca Dart).

**No ejecutes el ejemplo**: abre navegador y necesita una cuenta Google real. Lo cubre el QA humano.

- [ ] **Step 6: Commit** (código — SIN trailer `Co-Authored-By`)

```bash
cd /home/jlopezre/GitHub/LCC
git add native/src/gcp_rest_client.rs native/examples/auth_native.rs
git commit -m "feat(auth): native token path in get_access_token plus a runnable example"
```

---

### Task 4: Checklist de QA manual

**Files:**
- Create: `docs/superpowers/plans/2026-08-14-sgd-d3-native-token-manual-qa.md`

- [ ] **Step 1: Confirmar la verja**

Run: `cd native && cargo test 2>&1 | tail -6` — Expected: verde.
Run: `cd /home/jlopezre/GitHub/LCC && flutter test 2>&1 | tail -6` — Expected: verde.

- [ ] **Step 2: Escribir el checklist**

Crear `docs/superpowers/plans/2026-08-14-sgd-d3-native-token-manual-qa.md`:

```markdown
# QA manual — SG-D / D3: adquisición de token nativa

El canje real necesita Google y un navegador, así que no es testeable en CI.
Ejecutar desde `native/`.

Prerrequisito: cuenta añadida como test user en la pantalla de consentimiento, y
un Secret Service vivo (GNOME Keyring o KWallet).

- [ ] **Primera ejecución**: `LCC_AUTH_ENGINE=native cargo run --example auth_native` abre el navegador, completas el consentimiento, e imprime `✓ Session ready for: <tu email>`, `engine: Native` y un prefijo del access token.
- [ ] **Segunda ejecución** (la prueba clave): el mismo comando **NO abre el navegador** y vuelve a imprimir el token. Eso demuestra que el refresh token guardado en el keyring se está usando.
- [ ] **La cuenta quedó registrada**: `cat ~/.local/share/lightweight_cloud_connector/oauth_accounts.json` muestra tu email en `accounts` y en `active` — y ningún token.
- [ ] **El flag apagado no cambia nada**: `cargo run --example auth_native` **sin** la variable sigue funcionando vía el camino de siempre, y la app normal (sin la variable) lista proyectos e instancias como antes.
- [ ] **La app con el flag**: lanzar LCC con `LCC_AUTH_ENGINE=native` lista proyectos e instancias correctamente, **sin** que intervenga gcloud (comprobable con `ps aux | grep 'gcloud auth'` mientras navegas: no debe aparecer).
- [ ] **Recuperación**: borrar la cuenta del keyring (`cargo test --lib token_store -- --ignored` deja el almacén limpio, o usar el gestor de contraseñas del escritorio) y volver a ejecutar el ejemplo → detecta que no hay sesión y abre el navegador de nuevo, sin quedarse colgado.
- [ ] **Sin secretos en la salida**: ni el refresh token ni el access token completo aparecen en consola (solo un prefijo de 12 caracteres).
```

- [ ] **Step 3: Commit** (docs)

```bash
cd /home/jlopezre/GitHub/LCC
git add docs/superpowers/plans/2026-08-14-sgd-d3-native-token-manual-qa.md
git commit -m "docs(qa): manual QA checklist for SG-D/D3 native token acquisition"
```

---

## Self-Review

**1. Spec coverage:**
- Flag `LCC_AUTH_ENGINE` con helper puro + polaridad inversa documentada → Task 1 Step 3. ✓
- `refresh_access_token` reutilizando cliente con timeout y `redact_sensitive` → Task 1 Step 4. ✓
- `refresh_failure_needs_reauth` pura y testeable → Task 1 Step 4 + 4 tests en Step 1. ✓
- `sign_in_and_store` (puente D1→D2) → Task 2 Step 2. ✓
- `ensure_signed_in` con sondeo, relanzamiento e invalidación de caché → Task 2 Step 3. ✓
- Rama nativa en `get_access_token`, sin fallback, camino gcloud intacto → Task 3 Steps 1-2. ✓
- Nunca abrir navegador desde `get_access_token` → Task 3 Step 2 (comentario) + Global Constraints. ✓
- `spawn_blocking` en toda llamada a `token_store` → Task 2 Step 1 (`store_call`) + Task 3 Step 2, verificado por grep en Task 2 Step 5. ✓
- No llamar `invalidate_cached_access_token` con el lock tomado → se llama solo desde `ensure_signed_in`, que vive fuera. ✓
- Token del sondeo descartado, sin pasarlo al caché → Task 2 Step 3 (comentario explícito). ✓
- Cuatro errores distinguibles (sin cuenta / reauth / transitorio / keyring) → Task 3 Step 2 y Task 1 Step 4; el de keyring llega tal cual de D2. ✓
- Texto de reauth estable para D4 → Task 3 Step 2 (comentario). ✓
- Ejemplo `auth_native.rs` con la prueba de la segunda ejecución → Task 3 Step 3 + Task 4. ✓
- Verificación cargo test + release + flutter + QA manual → Task 3 Step 5 + Task 4. ✓

**2. Placeholder scan:** Sin TBD/TODO. Todo el código (flag, refresco, helper, puente, recuperación, rama nativa, ejemplo, tests y checklist) está escrito literalmente. ✓

**3. Type consistency:** `AuthEngine`, `RefreshOutcome::{Token, NeedsReauth}`, `RefreshedToken`, `refresh_access_token`, `store_call`, `sign_in_and_store`, `ensure_signed_in` se definen en las Tasks 1-2 y se usan con esos nombres exactos en la Task 3 y el ejemplo. `OAuthTokens` tiene los campos `email`/`refresh_token` que consume `sign_in_and_store` (verificado en `oauth.rs:27-32`). `token_store::active_account` devuelve `Option<String>` y `load_refresh_token` devuelve `Result<String>` — de ahí el `?` simple tras `store_call` en el primero y el doble `??` en el segundo. `GcpAuthClient::get_or_init()` es `pub` y `gcp_rest_client` es `pub mod`, así que el ejemplo compila. `AuthEngine` deriva `PartialEq` para el `==` de la Task 3 y `Debug` para el `{:?}` del ejemplo. ✓
