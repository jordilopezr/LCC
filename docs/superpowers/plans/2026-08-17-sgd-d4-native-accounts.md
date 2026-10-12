# D4 — Gestión de cuentas nativa: plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Que list / switch / add / remove de cuentas y `list_projects_for_account` funcionen sobre el almacén nativo de tokens en vez de sobre el CLI de `gcloud`, detrás del flag `LCC_AUTH_ENGINE=native`, sin cambiar el interfaz Dart.

**Architecture:** Un módulo fachada `native/src/accounts.rs` concentra el despacho por motor y la implementación nativa; los wrappers de `api.rs` quedan en una línea. La implementación nativa compone `token_store` (cuentas), `oauth` (login, refresco, revocación) y `gcp_rest_client` (proyectos por REST). El núcleo decidible —despacho, mapeo a `GcloudAccount`, política de estado, orden revocar/borrar— se extrae como funciones puras para poder probarlo sin keyring ni red.

**Tech Stack:** Rust (tokio, reqwest, anyhow, tracing), flutter_rust_bridge 2.11.1, Flutter/Dart con Riverpod.

**Spec:** [`docs/superpowers/specs/2026-08-17-d4-native-account-management-design.md`](../specs/2026-08-17-d4-native-account-management-design.md)

## Global Constraints

- **Flag:** `LCC_AUTH_ENGINE=native` activa la ruta nativa. Ausente o cualquier otro valor ⇒ `AuthEngine::Gcloud`, y el comportamiento debe ser **idéntico al actual**. `oauth::auth_engine()` ya implementa esa polaridad; no se toca.
- **Interfaz Dart estable:** `AccountNotifier`, `accountProvider` y los nombres del bridge (`listGcloudAccounts`, `switchGcloudAccount`, `addGcloudAccount`, `removeGcloudAccount`, `listProjectsForAccount`, `getGcloudAccountEmail`) se mantienen. Renombrar es trabajo de SG-E.
- **`GcloudAccount { account: String, status: String }` no cambia.** El Dart distingue la cuenta activa por `status == "ACTIVE"`; el resto lleva `""`.
- **Toda llamada a `crate::token_store` va envuelta en `crate::oauth::store_call`** (que es `spawn_blocking`). zbus conduce su propio runtime con `block_on` y entra en pánico si se le invoca desde un worker de tokio.
- **Secretos jamás en logs ni en mensajes de error.** Ni refresh tokens ni access tokens. Los cuerpos de respuestas de error pasan por `crate::redact::redact_sensitive` antes de llegar a un log o a un `anyhow!`.
- **Prohibido `#[allow(dead_code)]`** y cualquier otro silenciado de lints. Si algo queda sin usar, se borra.
- **Literales de error que son contrato:** `"No active GCP account"` y `invalid_grant` los reconoce `classifyRustError` en `lib/src/features/app_error.dart`. Cambiar esa redacción rompe la clasificación sin que ningún test lo note.
- **NO ejecutar `dart format`** en ningún momento.
- Rama de trabajo: `27H1-Preview`. Los commits de código **no** llevan trailer `Co-Authored-By`.

## File Structure

| Fichero | Responsabilidad | Tarea |
|---|---|---|
| `native/src/oauth.rs` (modificar) | Añade la revocación del refresh token en Google | 1 |
| `native/src/gcp_rest_client.rs` (modificar) | Extrae el parseo y la petición de proyectos para poder servirlos con un token arbitrario | 2 |
| `native/src/accounts.rs` (**crear**) | Núcleo puro: despacho, mapeo, política de estado, orden revocar/borrar | 3 |
| `native/src/accounts.rs` (ampliar) | Las siete operaciones públicas, despachadas por motor | 4 |
| `native/src/lib.rs` (modificar) | Declara el módulo `accounts` | 3 |
| `native/src/api.rs` (modificar) | Wrappers delegando + `check_auth_status` | 5 |
| `lib/src/bridge/api.dart/` (regenerado) | Bridge | 5 |
| `lib/src/features/gcloud_provider.dart` (modificar) | `gcloudStatusProvider` pasa a una sola llamada | 6 |
| `docs/superpowers/plans/2026-08-17-sgd-d4-native-accounts-manual-qa.md` (**crear**) | Checklist de QA con la evidencia de divergencia exigida | 7 |

---

### Task 1: Revocación del refresh token en Google

**Files:**
- Modify: `native/src/oauth.rs`
- Test: `native/src/oauth.rs` (módulo `#[cfg(test)] mod tests` al final del fichero)

**Interfaces:**
- Consumes: nada de tareas anteriores.
- Produces: `pub async fn revoke_refresh_token(refresh_token: &str) -> anyhow::Result<()>`, que la tarea 4 usa desde `accounts::remove`.

**Contexto que necesitas:** `oauth.rs` ya tiene `refresh_access_token`, que construye su cliente `reqwest` con timeout explícito y propaga el error de `build()` en vez de hacer `unwrap()` (un `Client::default()` haría panic si falla la inicialización de TLS). Copia ese patrón exactamente. El endpoint de revocación es distinto del de tokens y necesita su propia constante.

El endpoint se inyecta en una función interna **solo para poder probarlo** contra un servidor de loopback: el repo no tiene librería de mocking HTTP y los tests existentes de `oauth.rs` (`stray_request_is_dismissed_then_real_redirect_returns_code`) levantan un `tokio::net::TcpListener` a pelo. Sigue ese estilo.

- [ ] **Step 1: Escribe los tests que fallan**

Añádelos dentro del `mod tests` que ya existe al final de `native/src/oauth.rs`:

```rust
    /// Servidor HTTP de un solo uso: lee la petición y contesta con
    /// `status_line` y `body`. Devuelve la URL a la que apuntar.
    async fn one_shot_http(status_line: &'static str, body: &'static str) -> String {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut buf = [0u8; 2048];
            let _ = socket.read(&mut buf).await;
            let response = format!(
                "{}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                status_line,
                body.len(),
                body
            );
            let _ = socket.write_all(response.as_bytes()).await;
            let _ = socket.shutdown().await;
        });
        format!("http://{}", addr)
    }

    #[tokio::test]
    async fn revoke_succeeds_on_200() {
        let url = one_shot_http("HTTP/1.1 200 OK", "").await;
        assert!(revoke_refresh_token_at(&url, "rt-abc").await.is_ok());
    }

    /// Un fallo de revocación no puede filtrar el token en el mensaje: ese
    /// mensaje acaba en el log y en la UI.
    #[tokio::test]
    async fn a_failed_revoke_never_names_the_token() {
        let url = one_shot_http(
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
```

- [ ] **Step 2: Ejecuta los tests y comprueba que fallan**

```bash
cd native && cargo test --lib oauth::tests::revoke
```

Esperado: FAIL de compilación — `cannot find function revoke_refresh_token_at in this scope`.

- [ ] **Step 3: Implementa**

Añade la constante junto a las otras (`TOKEN_ENDPOINT` está en la cabecera del fichero):

```rust
const REVOKE_ENDPOINT: &str = "https://oauth2.googleapis.com/revoke";
```

Y las dos funciones, junto a `refresh_access_token`:

```rust
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
```

- [ ] **Step 4: Ejecuta los tests y comprueba que pasan**

```bash
cd native && cargo test --lib oauth::
```

Esperado: PASS, incluidos `revoke_succeeds_on_200` y `a_failed_revoke_never_names_the_token`.

- [ ] **Step 5: Commit**

```bash
git add native/src/oauth.rs
git commit -m "feat(oauth): revoke a refresh token at Google

gcloud auth revoke invalidates the token at Google, not just locally.
The native account store needs the same, or every removed account would
keep a refresh token that works forever."
```

---

### Task 2: Servir proyectos con un token arbitrario

**Files:**
- Modify: `native/src/gcp_rest_client.rs:381-455` (`ResourceManagerClient::list_projects`)
- Test: `native/src/gcp_rest_client.rs` (módulo de tests del fichero)

**Interfaces:**
- Consumes: nada de tareas anteriores.
- Produces: `pub(crate) async fn list_projects_with_token(token: &str) -> anyhow::Result<Vec<GcpProject>>`, que la tarea 4 usa desde `accounts::projects_for`. `GcpProject` es el alias de `GcpProjectClientLib { project_id: String, name: Option<String>, project_number: String, state: String }` que ya existe en ese fichero.

**Contexto que necesitas:** `ResourceManagerClient::list_projects` saca el token de `self.auth`, que es el de la **cuenta activa**, y su caché (`TOKEN_CACHE`) pertenece a esa cuenta. Listar proyectos de otra cuenta con ese cliente devolvería los proyectos equivocados — el fallo silencioso más probable de todo D4. La ruta nueva recibe el token como parámetro y **no toca `GcpAuthClient` ni `TOKEN_CACHE`**.

- [ ] **Step 1: Escribe el test que falla**

El parseo es lo único puro y lo único que se puede probar sin red. Añádelo al módulo de tests de `native/src/gcp_rest_client.rs`:

```rust
    #[test]
    fn parses_projects_including_both_project_number_shapes() {
        // La API devuelve projectNumber unas veces como número y otras como
        // cadena; ambas formas tienen que sobrevivir.
        let json: serde_json::Value = serde_json::from_str(
            r#"{"projects":[
                {"projectId":"p-1","name":"Uno","projectNumber":12345,"lifecycleState":"ACTIVE"},
                {"projectId":"p-2","projectNumber":"67890"}
            ]}"#,
        )
        .unwrap();

        let projects = super::parse_projects(&json).unwrap();

        assert_eq!(projects.len(), 2);
        assert_eq!(projects[0].project_id, "p-1");
        assert_eq!(projects[0].name.as_deref(), Some("Uno"));
        assert_eq!(projects[0].project_number, "12345");
        assert_eq!(projects[0].state, "ACTIVE");
        assert_eq!(projects[1].name, None);
        assert_eq!(projects[1].project_number, "67890");
        assert_eq!(projects[1].state, "UNKNOWN", "sin lifecycleState debe quedar UNKNOWN");
    }

    #[test]
    fn a_response_without_a_projects_array_is_an_error() {
        let json: serde_json::Value = serde_json::from_str(r#"{"unexpected":true}"#).unwrap();
        assert!(super::parse_projects(&json).is_err());
    }
```

- [ ] **Step 2: Ejecuta el test y comprueba que falla**

```bash
cd native && cargo test --lib gcp_rest_client::tests::parses_projects
```

Esperado: FAIL de compilación — `cannot find function parse_projects`.

- [ ] **Step 3: Extrae el parseo y la petición**

Añade, a nivel de módulo en `native/src/gcp_rest_client.rs` (fuera del `impl`):

```rust
/// Parse a Resource Manager v1 `projects.list` response.
///
/// Pure, so the shape handling (`projectNumber` arriving as a number or a
/// string, a missing `lifecycleState`) is testable without a network call.
fn parse_projects(response_json: &serde_json::Value) -> Result<Vec<GcpProject>> {
    let projects_array = response_json["projects"]
        .as_array()
        .ok_or_else(|| anyhow!("No projects array in response"))?;

    let mut projects = Vec::new();
    for project_obj in projects_array {
        projects.push(GcpProject {
            project_id: project_obj["projectId"].as_str().unwrap_or_default().to_string(),
            name: project_obj["name"].as_str().map(|s| s.to_string()),
            project_number: project_obj["projectNumber"]
                .as_u64()
                .map(|n| n.to_string())
                .or_else(|| project_obj["projectNumber"].as_str().map(|s| s.to_string()))
                .unwrap_or_default(),
            state: project_obj["lifecycleState"].as_str().unwrap_or("UNKNOWN").to_string(),
        });
    }
    Ok(projects)
}

/// GET the project list from Resource Manager with an explicit bearer token.
async fn fetch_projects(
    client: &reqwest::Client,
    base_url: &str,
    token: &str,
) -> Result<Vec<GcpProject>> {
    let url = format!("{}/projects", base_url);
    debug!("Making request to: {}", url);

    let response = client
        .get(&url)
        .bearer_auth(token)
        .header("Content-Type", "application/json")
        .send()
        .await
        .map_err(|e| anyhow!("Failed to send request: {}", e))?;

    if !response.status().is_success() {
        let status = response.status();
        let error_text = response.text().await.unwrap_or_default();
        // SECURITY: Redact sensitive data from error logs
        error!("API request failed: {} - {}", status, redact_sensitive(&error_text));
        return Err(anyhow!("API error {}: {}", status, redact_sensitive(&error_text)));
    }

    let response_text = response.text().await?;
    debug!("Response received: {} bytes", response_text.len());
    let response_json: serde_json::Value = serde_json::from_str(&response_text)
        .map_err(|e| anyhow!("Failed to parse JSON: {}", e))?;
    parse_projects(&response_json)
}

/// List projects for whoever owns `token`, with no reference to the active
/// account's `GcpAuthClient` or `TOKEN_CACHE`.
///
/// The token is a parameter precisely so this cannot serve the active
/// account's projects by accident: that would be a silent, plausible-looking
/// wrong answer.
pub(crate) async fn list_projects_with_token(token: &str) -> Result<Vec<GcpProject>> {
    let base_url = "https://cloudresourcemanager.googleapis.com/v1";
    validate_gcp_url(base_url)?;
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
        .map_err(|e| anyhow!("Failed to build the HTTP client: {}", e))?;
    fetch_projects(&client, base_url, token).await
}
```

Sustituye el cuerpo de `ResourceManagerClient::list_projects` (desde `// Usar el HTTP client cacheado` hasta el `Ok(projects)` final) para que use la función compartida, conservando el log de tiempos:

```rust
    pub async fn list_projects(&self) -> Result<Vec<GcpProject>> {
        info!("📁 Listing GCP projects via REST API");
        let start = Instant::now();

        let token = self.auth.get_access_token().await?;
        let projects = fetch_projects(&self.http_client, &self.base_url, &token).await?;

        info!(
            "✓ Listed {} projects in {:?} (Client Library)",
            projects.len(),
            start.elapsed()
        );
        Ok(projects)
    }
```

Si `Duration` no está ya importado en el fichero, añádelo al `use std::time::…` existente.

- [ ] **Step 4: Ejecuta los tests y comprueba que pasan**

```bash
cd native && cargo test --lib gcp_rest_client::
```

Esperado: PASS.

**Un warning esperado:** `list_projects_with_token` todavía no tiene consumidor
—lo estrena la tarea 4—, así que `cargo build` avisará de
`function \`list_projects_with_token\` is never used`. Es correcto que aparezca
ahora y desaparecerá en la tarea 4. **No lo silencies**: nada de
`#[allow(dead_code)]`, ni `_` delante del nombre, ni un uso ficticio. Anótalo en
el informe y sigue.

- [ ] **Step 5: Commit**

```bash
git add native/src/gcp_rest_client.rs
git commit -m "refactor(rest): serve the project list from an explicit token

Listing another account's projects through ResourceManagerClient would
use the active account's token and cache, and return a wrong answer that
looks right. The token is now a parameter."
```

---

### Task 3: Núcleo puro de `accounts.rs`

**Files:**
- Create: `native/src/accounts.rs`
- Modify: `native/src/lib.rs` (declarar el módulo)
- Test: `native/src/accounts.rs` (módulo `#[cfg(test)] mod tests`)

**Interfaces:**
- Consumes: `crate::oauth::AuthEngine { Gcloud, Native }` (ya existe, `#[derive(Debug, Clone, Copy, PartialEq, Eq)]`); `crate::gcloud::GcloudAccount { account: String, status: String }` (ya existe).
- Produces, para la tarea 4:
  - `enum Route { Gcloud, Native }` (privado al módulo: nadie fuera despacha)
  - `fn route(engine: AuthEngine) -> Route`
  - `fn to_accounts(emails: Vec<String>, active: Option<String>) -> Vec<GcloudAccount>`
  - `pub struct AuthStatus { pub gcloud_installed: bool, pub authenticated: bool }`
  - `fn auth_status_for(engine: AuthEngine, gcloud_installed: bool, gcloud_authenticated: bool, native_has_active: bool) -> AuthStatus`
  - `async fn revoke_then_delete<R, RF, D>(email: &str, revoke: R, delete: D) -> anyhow::Result<()>`

`AuthStatus` se declara aquí y la tarea 5 lo devuelve desde `api.rs`; flutter_rust_bridge genera igual para tipos de otros módulos (`api.rs` ya devuelve `crate::gcloud::GcpProject`).

- [ ] **Step 1: Declara el módulo**

En `native/src/lib.rs`, junto a las otras declaraciones (`pub mod token_store;` está al final del bloque):

```rust
pub mod accounts;  // 27H1 SG-D/D4: account management over the native token store
```

- [ ] **Step 2: Escribe los tests que fallan**

Crea `native/src/accounts.rs` con **solo** el módulo de tests (la implementación llega en el paso 4):

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::oauth::AuthEngine;

    #[test]
    fn the_active_account_is_the_only_one_marked_active() {
        let accounts = to_accounts(
            vec!["a@x.com".into(), "b@x.com".into(), "c@x.com".into()],
            Some("b@x.com".into()),
        );
        let statuses: Vec<&str> = accounts.iter().map(|a| a.status.as_str()).collect();
        assert_eq!(statuses, vec!["", "ACTIVE", ""]);
        // El orden del índice se conserva: la UI lo muestra tal cual.
        let emails: Vec<&str> = accounts.iter().map(|a| a.account.as_str()).collect();
        assert_eq!(emails, vec!["a@x.com", "b@x.com", "c@x.com"]);
    }

    #[test]
    fn without_an_active_account_none_is_marked() {
        let accounts = to_accounts(vec!["a@x.com".into()], None);
        assert_eq!(accounts[0].status, "");
    }

    #[test]
    fn an_empty_store_lists_nothing() {
        assert!(to_accounts(Vec::new(), None).is_empty());
    }

    #[test]
    fn an_active_email_missing_from_the_list_does_not_invent_an_entry() {
        // El índice puede quedar inconsistente (borrado fuera de banda); la
        // lista es la lista, y nadie sale marcado.
        let accounts = to_accounts(vec!["a@x.com".into()], Some("ghost@x.com".into()));
        assert_eq!(accounts.len(), 1);
        assert_eq!(accounts[0].status, "");
    }

    #[test]
    fn the_engine_decides_the_route_in_both_directions() {
        assert!(matches!(route(AuthEngine::Gcloud), Route::Gcloud));
        assert!(matches!(route(AuthEngine::Native), Route::Native));
    }

    /// La guarda de la pieza que hace D4 alcanzable: con motor nativo, tener
    /// sesión NO puede depender de que gcloud esté instalado. El provider Dart
    /// cortocircuitaba justo ahí, y sin esto el diálogo de cuentas no llega
    /// nunca a pedir la lista.
    #[test]
    fn native_auth_does_not_depend_on_gcloud_being_installed() {
        let status = auth_status_for(AuthEngine::Native, false, false, true);
        assert!(status.authenticated, "una cuenta activa nativa es sesión válida");
        assert!(!status.gcloud_installed, "y gcloud sigue reportándose como ausente");
    }

    #[test]
    fn native_without_a_stored_account_is_not_authenticated() {
        let status = auth_status_for(AuthEngine::Native, true, true, false);
        assert!(!status.authenticated, "gcloud autenticado no da sesión nativa");
    }

    #[test]
    fn gcloud_engine_keeps_todays_semantics() {
        assert!(auth_status_for(AuthEngine::Gcloud, true, true, false).authenticated);
        assert!(!auth_status_for(AuthEngine::Gcloud, true, false, true).authenticated);
        // Sin gcloud instalado no hay sesión gcloud, haya lo que haya nativo.
        assert!(!auth_status_for(AuthEngine::Gcloud, false, true, true).authenticated);
    }

    /// Si Google no contesta, la entrada local se borra igual: dejarla sería
    /// mostrar al usuario una cuenta rota que no puede quitar.
    #[tokio::test]
    async fn a_failed_revocation_still_deletes_the_local_entry() {
        use std::sync::atomic::{AtomicBool, Ordering};
        use std::sync::Arc;

        let deleted = Arc::new(AtomicBool::new(false));
        let flag = deleted.clone();

        let result = revoke_then_delete(
            "a@x.com",
            |_email| async { Err(anyhow::anyhow!("network down")) },
            move |_email| {
                flag.store(true, Ordering::SeqCst);
                Ok(())
            },
        )
        .await;

        assert!(deleted.load(Ordering::SeqCst), "no se borró la entrada local");
        assert!(result.is_ok(), "un fallo de revocación no debe fallar el remove");
    }

    #[tokio::test]
    async fn a_failed_local_delete_is_an_error() {
        let result = revoke_then_delete(
            "a@x.com",
            |_email| async { Ok(()) },
            |_email| Err(anyhow::anyhow!("keyring unavailable")),
        )
        .await;
        assert!(result.is_err(), "si el borrado local falla, remove falla");
    }
}
```

- [ ] **Step 3: Ejecuta los tests y comprueba que fallan**

```bash
cd native && cargo test --lib accounts::
```

Esperado: FAIL de compilación — `cannot find function to_accounts`, `cannot find type Route`, etc.

- [ ] **Step 4: Implementa el núcleo**

Escribe esto **encima** del `mod tests` en `native/src/accounts.rs`:

```rust
//! Account management: list, switch, add, remove, and the projects visible to
//! each account.
//!
//! This module is the single place that decides whether an account operation
//! is served by the `gcloud` CLI or by LCC's own token store, so D5 removes
//! one arm from one file rather than unpicking six `match` blocks scattered
//! across the bridge wrappers.

use anyhow::Result;
use std::future::Future;

use crate::gcloud::GcloudAccount;
use crate::oauth::AuthEngine;

/// Which implementation serves an account operation. Private: dispatching is
/// this module's job and nobody else's.
enum Route {
    Gcloud,
    Native,
}

/// Every public operation in this module decides with this and nothing else.
/// A hardwired arm — or an operation that forgets to ask — is the failure this
/// separation exists to make visible.
fn route(engine: AuthEngine) -> Route {
    match engine {
        AuthEngine::Gcloud => Route::Gcloud,
        AuthEngine::Native => Route::Native,
    }
}

/// Present the stored accounts in the shape the Dart layer already consumes.
///
/// `status` is `"ACTIVE"` for the active account and `""` for the rest —
/// the exact contract `AccountNotifier` reads. Order follows the index, which
/// is the order the dialog shows.
fn to_accounts(emails: Vec<String>, active: Option<String>) -> Vec<GcloudAccount> {
    emails
        .into_iter()
        .map(|email| {
            let is_active = active.as_deref() == Some(email.as_str());
            GcloudAccount {
                account: email,
                status: if is_active { "ACTIVE".to_string() } else { String::new() },
            }
        })
        .collect()
}

/// Whether gcloud is present, and whether there is a usable session.
pub struct AuthStatus {
    pub gcloud_installed: bool,
    pub authenticated: bool,
}

/// Decide the session state from the engine and the two sources.
///
/// The native arm deliberately ignores `gcloud_installed`: the Dart provider
/// used to short-circuit on it, so on a machine without gcloud the account
/// dialog never even asked for the list — no matter how native the store
/// behind it was. `gcloud_installed` keeps telling the truth about gcloud
/// either way, because Doctor and the dependency row read it.
fn auth_status_for(
    engine: AuthEngine,
    gcloud_installed: bool,
    gcloud_authenticated: bool,
    native_has_active: bool,
) -> AuthStatus {
    let authenticated = match route(engine) {
        Route::Gcloud => gcloud_installed && gcloud_authenticated,
        Route::Native => native_has_active,
    };
    AuthStatus { gcloud_installed, authenticated }
}

/// Revoke at Google, then delete locally — and delete locally even when the
/// revocation failed.
///
/// Keeping the local entry because Google did not answer is the worse of the
/// two outcomes: the user is left looking at an account that no longer works
/// and cannot remove it. The revocation failure is logged, not propagated.
async fn revoke_then_delete<R, RF, D>(email: &str, revoke: R, delete: D) -> Result<()>
where
    R: FnOnce(String) -> RF,
    RF: Future<Output = Result<()>>,
    D: FnOnce(String) -> Result<()>,
{
    if let Err(e) = revoke(email.to_string()).await {
        tracing::warn!(
            error = %e,
            "Could not revoke the account at Google; removing it locally anyway"
        );
    }
    delete(email.to_string())
}
```

- [ ] **Step 5: Ejecuta los tests y comprueba que pasan**

```bash
cd native && cargo test --lib accounts::
```

Esperado: PASS, los nueve tests.

**Warnings esperados aquí también:** en una compilación sin tests
(`cargo build`), `to_accounts`, `revoke_then_delete` y `AuthStatus` aún no
tienen consumidor —los estrena la tarea 4— y el compilador los marcará como no
usados. Igual que en la tarea 2: **no los silencies de ninguna forma**. Anótalos
en el informe.

- [ ] **Step 6: Commit**

```bash
git add native/src/accounts.rs native/src/lib.rs
git commit -m "feat(accounts): pure core for native account management

Dispatch, the GcloudAccount mapping, the session-state policy and the
revoke-then-delete order, extracted so they are testable without a
keyring or a network."
```

---

### Task 4: Las siete operaciones despachadas

**Files:**
- Modify: `native/src/accounts.rs`
- Test: `native/src/accounts.rs` (mismo módulo de tests)

**Interfaces:**
- Consumes:
  - de la tarea 1: `crate::oauth::revoke_refresh_token(&str) -> Result<()>`
  - de la tarea 2: `crate::gcp_rest_client::list_projects_with_token(&str) -> Result<Vec<GcpProjectClientLib>>`
  - de la tarea 3: `Route`, `route`, `to_accounts`, `AuthStatus`, `auth_status_for`, `revoke_then_delete`
  - ya existentes: `crate::token_store::{list_accounts, active_account, set_active_account, delete_account, load_refresh_token}`; `crate::oauth::{auth_engine, store_call, sign_in_and_store, refresh_access_token, RefreshOutcome}`; `crate::gcloud::{list_gcloud_accounts_async, switch_gcloud_account_async, add_gcloud_account, remove_gcloud_account_async, get_gcloud_account, get_projects_for_account_async, is_gcloud_installed, is_gcloud_authenticated}`; `crate::gcp_rest_client::invalidate_cached_access_token`; `crate::validation::validate_email`
- Produces, para la tarea 5:
  - `pub async fn list() -> Result<Vec<GcloudAccount>>`
  - `pub async fn switch(email: &str) -> Result<()>`
  - `pub async fn add() -> Result<()>`
  - `pub async fn remove(email: &str) -> Result<()>`
  - `pub async fn active_email() -> Result<String>`
  - `pub async fn projects_for(email: &str) -> Result<Vec<crate::gcloud::GcpProject>>`
  - `pub async fn auth_status() -> AuthStatus`

**Contexto que necesitas:** `store_call` es `pub(crate) async fn store_call<T, F>(f: F) -> Result<T> where F: FnOnce() -> T + Send + 'static, T: Send + 'static`. Como el closure debe ser `'static`, hay que mover una `String` propia dentro, no una `&str`. Cuando la función envuelta devuelve `Result<_>`, el resultado es `Result<Result<_>>` y se desdobla con `??`.

`crate::gcloud::GcpProject { project_id: String, name: Option<String> }` tiene dos campos; `crate::gcp_rest_client::GcpProjectClientLib` tiene cuatro. `api.rs` ya hace esa conversión al listar proyectos; replícala.

- [ ] **Step 1: Escribe los tests que fallan**

Añádelos al `mod tests` de `native/src/accounts.rs`:

```rust
    /// Contrato con el clasificador Dart: `classifyRustError` mapea
    /// `invalid_grant` a `notAuthenticated`, que es lo que hace aparecer el
    /// banner de re-login. Sin ese literal, un token muerto sale como error
    /// genérico y el usuario no tiene salida.
    #[test]
    fn a_dead_refresh_token_surfaces_as_invalid_grant() {
        let err = token_from_outcome("a@x.com", crate::oauth::RefreshOutcome::NeedsReauth)
            .expect_err("NeedsReauth debe ser error");
        assert!(
            err.to_string().contains("invalid_grant"),
            "el banner de sesión no reconocerá este mensaje: {}",
            err
        );
    }

    #[test]
    fn a_live_refresh_token_yields_its_access_token() {
        let outcome = crate::oauth::RefreshOutcome::Token(crate::oauth::RefreshedToken {
            access_token: "ya29.token".into(),
            expires_in_secs: 3599,
        });
        assert_eq!(token_from_outcome("a@x.com", outcome).unwrap(), "ya29.token");
    }

    /// Otro literal que es contrato: `classifyRustError` lo mapea a
    /// `notAuthenticated`.
    #[test]
    fn the_no_active_account_error_keeps_its_wording() {
        assert!(no_active_account_error()
            .to_string()
            .contains("No active GCP account"));
    }
```

- [ ] **Step 2: Ejecuta los tests y comprueba que fallan**

```bash
cd native && cargo test --lib accounts::
```

Esperado: FAIL de compilación — `cannot find function token_from_outcome`.

- [ ] **Step 3: Implementa los ayudantes y las operaciones**

Añade a `native/src/accounts.rs`, encima del `mod tests`:

```rust
use anyhow::anyhow;
use crate::oauth::{RefreshOutcome, RefreshedToken};

/// The exact wording `classifyRustError` (Dart) maps to `notAuthenticated`.
fn no_active_account_error() -> anyhow::Error {
    anyhow!("No active GCP account")
}

/// Turn a refresh outcome into an access token, or into the signal the session
/// banner recognises.
fn token_from_outcome(email: &str, outcome: RefreshOutcome) -> Result<String> {
    match outcome {
        RefreshOutcome::Token(RefreshedToken { access_token, .. }) => Ok(access_token),
        // `invalid_grant` is what `classifyRustError` looks for; without it a
        // dead token reads as a generic failure and offers the user no way out.
        RefreshOutcome::NeedsReauth => Err(anyhow!(
            "Session expired for {} (invalid_grant); sign in again",
            email
        )),
    }
}

/// An access token for `email`, minted from that account's stored refresh
/// token. Never reads or writes the active account's token cache.
async fn access_token_for_account(email: &str) -> Result<String> {
    validate_email(email)?;
    let owned = email.to_string();
    let refresh_token =
        crate::oauth::store_call(move || crate::token_store::load_refresh_token(&owned)).await??;
    let outcome = crate::oauth::refresh_access_token(&refresh_token).await?;
    token_from_outcome(email, outcome)
}

// ==========================================
// Public operations — every one dispatches on `route(auth_engine())`
// ==========================================

/// Every known account, with the active one flagged.
pub async fn list() -> Result<Vec<GcloudAccount>> {
    match route(crate::oauth::auth_engine()) {
        Route::Gcloud => crate::gcloud::list_gcloud_accounts_async().await,
        Route::Native => {
            let emails = crate::oauth::store_call(crate::token_store::list_accounts).await?;
            let active = crate::oauth::store_call(crate::token_store::active_account).await?;
            Ok(to_accounts(emails, active))
        }
    }
}

/// Make `email` the active account.
pub async fn switch(email: &str) -> Result<()> {
    match route(crate::oauth::auth_engine()) {
        Route::Gcloud => crate::gcloud::switch_gcloud_account_async(email).await,
        Route::Native => {
            validate_email(email)?;
            let owned = email.to_string();
            // Propagated, not swallowed: an unknown account must leave the
            // previous choice untouched and say so.
            crate::oauth::store_call(move || crate::token_store::set_active_account(&owned))
                .await??;
            // The cached token belongs to the account we just left.
            crate::gcp_rest_client::invalidate_cached_access_token().await;
            Ok(())
        }
    }
}

/// Sign in to another account and store it.
///
/// This does NOT make the new account active when one already is: switching is
/// `switch`, which is where the Dart layer disconnects tunnels and saves the
/// outgoing account's project selection. `save_account` sets the active
/// account only when there was none, which is what a first sign-in wants.
pub async fn add() -> Result<()> {
    match route(crate::oauth::auth_engine()) {
        Route::Gcloud => crate::gcloud::add_gcloud_account(),
        Route::Native => {
            crate::oauth::sign_in_and_store().await?;
            Ok(())
        }
    }
}

/// Revoke `email` at Google and forget it locally.
pub async fn remove(email: &str) -> Result<()> {
    match route(crate::oauth::auth_engine()) {
        Route::Gcloud => crate::gcloud::remove_gcloud_account_async(email).await,
        Route::Native => {
            validate_email(email)?;
            revoke_then_delete(
                email,
                |owned| async move {
                    let for_load = owned.clone();
                    let refresh_token = crate::oauth::store_call(move || {
                        crate::token_store::load_refresh_token(&for_load)
                    })
                    .await??;
                    crate::oauth::revoke_refresh_token(&refresh_token).await
                },
                |owned| {
                    // Blocking keyring work off the async path, like every
                    // other token_store call.
                    tokio::task::block_in_place(|| crate::token_store::delete_account(&owned))
                },
            )
            .await
        }
    }
}

/// The active account's e-mail.
pub async fn active_email() -> Result<String> {
    match route(crate::oauth::auth_engine()) {
        Route::Gcloud => crate::gcloud::get_gcloud_account(),
        Route::Native => crate::oauth::store_call(crate::token_store::active_account)
            .await?
            .ok_or_else(no_active_account_error),
    }
}

/// The projects visible to `email` — which need not be the active account.
pub async fn projects_for(email: &str) -> Result<Vec<crate::gcloud::GcpProject>> {
    match route(crate::oauth::auth_engine()) {
        Route::Gcloud => crate::gcloud::get_projects_for_account_async(email).await,
        Route::Native => {
            let token = access_token_for_account(email).await?;
            let projects = crate::gcp_rest_client::list_projects_with_token(&token).await?;
            Ok(projects
                .into_iter()
                .map(|p| crate::gcloud::GcpProject { project_id: p.project_id, name: p.name })
                .collect())
        }
    }
}

/// Whether gcloud is present and whether there is a usable session.
pub async fn auth_status() -> AuthStatus {
    let engine = crate::oauth::auth_engine();
    let gcloud_installed = crate::gcloud::is_gcloud_installed();
    let (gcloud_authenticated, native_has_active) = match route(engine) {
        // Only ask the source the engine will actually use: probing gcloud
        // under the native engine would shell out on every status poll.
        Route::Gcloud => (gcloud_installed && crate::gcloud::is_gcloud_authenticated(), false),
        Route::Native => (
            false,
            crate::oauth::store_call(crate::token_store::active_account)
                .await
                .ok()
                .flatten()
                .is_some(),
        ),
    };
    auth_status_for(engine, gcloud_installed, gcloud_authenticated, native_has_active)
}
```

Añade `use crate::validation::validate_email;` al bloque de `use` de la cabecera del módulo.

**Nota sobre `block_in_place` en `remove`:** `revoke_then_delete` recibe el borrado como closure síncrono, así que el `spawn_blocking` de `store_call` no encaja ahí; `block_in_place` cumple la misma función (sacar el trabajo bloqueante del hilo del reactor) y es válido en el runtime multi-hilo que usa la app. Si al ejecutar los tests aparece un panic de `block_in_place` bajo un runtime de un solo hilo, cambia la firma de `revoke_then_delete` para aceptar un closure asíncrono también en el borrado y usa `store_call` — y dilo en el informe.

- [ ] **Step 4: Ejecuta los tests y comprueba que pasan**

```bash
cd native && cargo test --lib accounts::
```

Esperado: PASS. Después, la suite entera:

```bash
cd native && cargo test
```

Esperado: PASS, y **sin warnings nuevos** respecto a los tres que ya existían antes (`unused import: super::*` en `tunnel.rs` y `windows_credentials/mod.rs`, y `unused import: Read` en `examples/transfer_bench.rs`).

- [ ] **Step 5: Comprobación de despacho (a mano, y va en el informe)**

```bash
cd native && grep -n 'crate::gcloud::' src/accounts.rs
```

Cada aparición debe estar dentro de un brazo `Route::Gcloud`. Ninguna función pública puede llamar a `crate::gcloud::` fuera de ahí, y ninguna puede saltarse el `match route(...)`. Pega la salida en el informe.

Comprueba además, leyendo el brazo nativo de `switch`, que el error de
`set_active_account` se **propaga** con `??` y no se descarta: una cuenta
desconocida tiene que fallar dejando la activa anterior intacta, y un `let _ =`
ahí sería un cambio silencioso de cuenta que ningún test de este módulo
detecta. Di explícitamente en el informe que lo has verificado.

- [ ] **Step 6: Commit**

```bash
git add native/src/accounts.rs
git commit -m "feat(accounts): serve list/switch/add/remove from the token store

Behind LCC_AUTH_ENGINE=native. gcloud stays the default until D5, and
its arm is byte-for-byte what the bridge called before."
```

---

### Task 5: Wrappers del bridge y regeneración

**Files:**
- Modify: `native/src/api.rs:80-82` (`get_gcloud_account_email`), `:121-143` (bloque de cuentas), y el bloque de status en `:68-75`
- Modify (regenerado): `lib/src/bridge/api.dart/`

**Interfaces:**
- Consumes de la tarea 4: las siete funciones públicas de `crate::accounts` y el tipo `crate::accounts::AuthStatus`.
- Produces para la tarea 6: la función Dart `checkAuthStatus()`, que devuelve un objeto con `gcloudInstalled` y `authenticated`.

**Contexto que necesitas:** el bridge se regenera con

```bash
flutter_rust_bridge_codegen generate --rust-input "crate::api" --rust-root native --dart-output lib/src/bridge/api.dart
```

(el binario está en `/home/jlopezre/.cargo/bin/flutter_rust_bridge_codegen`). **Cautela conocida:** una regeneración puede reescribir `GcpInstanceClientLib` u otras structs y romper call sites en `lib/src/features/gcloud_provider.dart` y `lib/src/features/manual_instance_dialog.dart`. Revísalos después y arregla a mano lo que haga falta; no reviertas la regeneración.

`add_gcloud_account` y `get_gcloud_account_email` pasan de `fn` a `async fn` en Rust. Los call sites Dart no cambian: el bridge devuelve `Future` en ambos casos y los tres consumidores (`gcloud_provider.dart:155`, `sshfs_mount_dialog.dart:77`, `windows_credentials_dialog.dart:88`) ya hacen `await`.

- [ ] **Step 1: Reescribe los wrappers**

En `native/src/api.rs`, sustituye el cuerpo de las funciones de cuenta por delegaciones, conservando nombres y firmas visibles:

```rust
/// Get the email of the currently active GCP account.
pub async fn get_gcloud_account_email() -> anyhow::Result<String> {
    crate::accounts::active_email().await
}
```

```rust
/// List all authenticated accounts
pub async fn list_gcloud_accounts() -> anyhow::Result<Vec<crate::gcloud::GcloudAccount>> {
    crate::accounts::list().await
}

/// Switch the active account
pub async fn switch_gcloud_account(email: String) -> anyhow::Result<()> {
    crate::accounts::switch(&email).await
}

/// Add a new account (opens browser)
pub async fn add_gcloud_account() -> anyhow::Result<()> {
    crate::accounts::add().await
}

/// Remove an account: revoked at Google, then forgotten locally
pub async fn remove_gcloud_account(email: String) -> anyhow::Result<()> {
    crate::accounts::remove(&email).await
}

/// List projects for a specific account (without changing global config)
pub async fn list_projects_for_account(email: String) -> anyhow::Result<Vec<crate::gcloud::GcpProject>> {
    crate::accounts::projects_for(&email).await
}

/// Whether gcloud is present, and whether there is a usable session.
///
/// One call rather than two, because under the native engine "is there a
/// session" must not be gated on gcloud being installed — and that decision
/// belongs where the engine flag lives.
pub async fn check_auth_status() -> crate::accounts::AuthStatus {
    crate::accounts::auth_status().await
}
```

**No toques** `check_gcloud_installed` ni `check_gcloud_auth`: Doctor y la fila de dependencias las siguen usando y deben seguir hablando de gcloud.

- [ ] **Step 2: Compila el lado Rust**

```bash
cd native && cargo build && cargo test
```

Esperado: PASS, sin warnings nuevos.

- [ ] **Step 3: Regenera el bridge**

```bash
cd /home/jlopezre/GitHub/LCC && flutter_rust_bridge_codegen generate --rust-input "crate::api" --rust-root native --dart-output lib/src/bridge/api.dart
```

- [ ] **Step 4: Comprueba que el proyecto Dart sigue analizando**

```bash
flutter analyze
```

Esperado: **cero líneas `error •`**. Los `info` y `warning` que ya existían (83 issues antes de empezar, en `notification_service.dart`, `storage_service.dart` y ficheros de `test/`) siguen ahí y no son tuyos. Si la regeneración rompió call sites en `gcloud_provider.dart` o `manual_instance_dialog.dart`, arréglalos a mano y explica qué cambió en el informe.

- [ ] **Step 5: Ejecuta la suite Flutter**

```bash
flutter test
```

Esperado: `All tests passed!`

- [ ] **Step 6: Commit**

```bash
git add native/src/api.rs lib/src/bridge/
git commit -m "feat(bridge): route account management through accounts.rs

The bridge names stay as they are — renaming the ones that no longer
call gcloud is SG-E. check_auth_status replaces the two-call status
probe so the engine decides what 'authenticated' means."
```

---

### Task 6: El provider de estado en Dart

**Files:**
- Modify: `lib/src/features/gcloud_provider.dart:248-254`

**Interfaces:**
- Consumes de la tarea 5: `checkAuthStatus()`, con campos `gcloudInstalled` y `authenticated`.
- Produces: nada nuevo. `gcloudStatusProvider` mantiene su tipo `FutureProvider<Map<String, bool>>` y sus claves `'installed'` y `'authenticated'`.

**Contexto que necesitas:** este provider es la guarda que hacía D4 inalcanzable. Hoy:

```dart
final gcloudStatusProvider = FutureProvider<Map<String, bool>>((ref) async {
  final installed = await checkGcloudInstalled();
  if (!installed) return {'installed': false, 'authenticated': false};

  final authenticated = await checkGcloudAuth();
  return {'installed': true, 'authenticated': authenticated};
});
```

El cortocircuito de la segunda línea es lo que hay que quitar. Sus consumidores (`AccountNotifier.build()` y la fila de dependencias) leen el mapa; **el mapa no cambia**, solo cambia de dónde sale.

**Sobre las pruebas de esta tarea:** no hay test automático posible. El bridge no es mockeable en tests de widget, así que un test de este provider probaría el mock y no el comportamiento. La guarda real de esta decisión es `native_auth_does_not_depend_on_gcloud_being_installed` (tarea 3), que prueba la política donde vive; aquí la verificación es que el análisis y la suite siguen verdes, y el resto lo cubre el QA manual de la tarea 7. No inventes un test para rellenar este hueco.

- [ ] **Step 1: Sustituye el cuerpo del provider**

```dart
/// Whether gcloud is installed and whether there is a usable session.
///
/// Both come from one Rust call, because under the native auth engine having a
/// session must not depend on gcloud being installed — this used to
/// short-circuit on `installed`, so on a machine without gcloud the account
/// dialog never asked for the list at all. The map's shape is unchanged for
/// its consumers.
final gcloudStatusProvider = FutureProvider<Map<String, bool>>((ref) async {
  final status = await checkAuthStatus();
  return {
    'installed': status.gcloudInstalled,
    'authenticated': status.authenticated,
  };
});
```

- [ ] **Step 2: Analiza**

```bash
flutter analyze
```

Esperado: cero líneas `error •`. Si `checkGcloudInstalled` o `checkGcloudAuth` quedan sin usar en Dart, **no los borres**: Doctor y la fila de dependencias los usan; comprueba con

```bash
grep -rn 'checkGcloudInstalled\|checkGcloudAuth' lib/ --include=*.dart
```

y pega la salida en el informe.

- [ ] **Step 3: Ejecuta la suite Flutter**

```bash
flutter test
```

Esperado: `All tests passed!`

- [ ] **Step 4: Commit**

```bash
git add lib/src/features/gcloud_provider.dart
git commit -m "fix(auth): stop gating the session on gcloud being installed

The provider short-circuited on 'gcloud not installed', so the account
dialog never asked for the list on a machine without gcloud — however
native the store behind it. Same shape as D3's ADC gate."
```

---

### Task 7: Checklist de QA manual con la evidencia exigida

**Files:**
- Create: `docs/superpowers/plans/2026-08-17-sgd-d4-native-accounts-manual-qa.md`

**Interfaces:**
- Consumes: todo lo anterior.
- Produces: el documento que el usuario ejecuta a mano.

**Contexto que necesitas:** el [estándar de verificación](../specs/2026-08-12-gcloud-removal-roadmap.md) es vinculante para D4. Tres sub-proyectos de esta misma iniciativa pasaron su QA en verde sin funcionar. Cada ítem del checklist **debe nombrar la evidencia exacta** —una línea de log, el contenido de un fichero, la salida de un comando—, nunca una impresión de pantalla. El índice de cuentas nativo vive en `oauth_accounts.json`, dentro del directorio de datos de la app (`app_dirs::migrated_app_dir(dirs::data_local_dir())`).

- [ ] **Step 1: Escribe el documento**

Crea `docs/superpowers/plans/2026-08-17-sgd-d4-native-accounts-manual-qa.md` con exactamente esta estructura y contenido:

````markdown
# QA manual — D4: gestión de cuentas nativa

**Build:** (rellenar con el `kBuild` que se pruebe)
**Requisito:** lanzar la app con `LCC_AUTH_ENGINE=native`.

Cada ítem nombra la evidencia que lo demuestra. Un ítem sin esa evidencia
**no está verificado**, por muy bien que se vea la pantalla.

## Preparación

```bash
# Índice de cuentas nativo
find ~/.local/share -name oauth_accounts.json 2>/dev/null
# Cuentas que conoce gcloud
gcloud auth list
```

Anota ambas salidas **antes** de empezar. La prueba central es que difieran.

## 1. Divergencia: gcloud tiene una cuenta que el almacén nativo no

- [ ] Existe en `gcloud auth list` una cuenta que **no** aparece en
      `oauth_accounts.json`.
- [ ] Esa cuenta **no** aparece en el diálogo de cuentas de la app.

**Evidencia:** las tres salidas a la vez — `gcloud auth list`, el contenido de
`oauth_accounts.json`, y la lista en pantalla.
**Si las tres coinciden, esta prueba no vale.** En esta iniciativa la UI ya
mostró una vez la cuenta corporativa de gcloud mientras el token era de una
cuenta personal del almacén nativo: coincidieron por azar, no por integración.

## 2. Divergencia en el otro sentido

- [ ] Hay en `oauth_accounts.json` una cuenta que **no** está en
      `gcloud auth list`.
- [ ] Esa cuenta **sí** aparece en el diálogo.

**Evidencia:** las mismas tres salidas.

## 3. Entorno hostil: sin gcloud en el PATH

Lanza la app con gcloud fuera del alcance:

```bash
env -u LCC_TUNNEL_ENGINE LCC_AUTH_ENGINE=native PATH=/usr/bin:/bin ./build/linux/x64/release/bundle/lightweight_cloud_connector
```

(comprueba antes que `PATH=/usr/bin:/bin which gcloud` no devuelve nada)

- [ ] La app arranca con sesión: el diálogo de cuentas **lista** las cuentas del
      almacén nativo.
- [ ] Se pueden listar proyectos e instancias.

**Evidencia:** la salida de `which gcloud` con ese `PATH`, y la lista en
pantalla. Sin este ítem, la guarda de estado no está verificada — y es
justamente la pieza cuyo fallo sería invisible en la máquina de desarrollo.

## 4. Cambiar de cuenta

- [ ] Cambiar a otra cuenta actualiza la marca de activa en el diálogo.
- [ ] Los proyectos que se listan tras el cambio son los de la cuenta nueva.

**Evidencia:** `oauth_accounts.json` muestra el nuevo valor en `active`, y la
lista de proyectos cambia. Si la lista de proyectos **no** cambia, el token
cacheado no se invalidó.

## 5. Añadir una cuenta no cambia la activa

- [ ] Con una cuenta activa, añadir otra abre el navegador y la nueva aparece
      en la lista.
- [ ] La cuenta activa **sigue siendo la anterior**.

**Evidencia:** `active` en `oauth_accounts.json` no cambió; `accounts` tiene una
entrada más.

## 6. Quitar una cuenta revoca de verdad

- [ ] Antes de quitarla, copia su refresh token del keyring:

```bash
secret-tool lookup service linux-cloud-connector username oauth::TU@EMAIL
```

- [ ] Quita la cuenta desde el diálogo.
- [ ] Desaparece de `oauth_accounts.json` y del keyring.
- [ ] El refresh token copiado **ya no sirve**:

```bash
# El client_secret de una app de escritorio no es un secreto real —va embebido
# en el binario—, pero no se copia aquí: se lee de la fuente al ejecutar.
SECRET=$(grep -oP 'OAUTH_CLIENT_SECRET: &str = "\K[^"]+' native/src/oauth.rs)
curl -s -X POST https://oauth2.googleapis.com/token \
  -d client_id=743123147934-plp891qo2a44ie5jop1ud7n445gduk0h.apps.googleusercontent.com \
  -d client_secret="$SECRET" \
  -d grant_type=refresh_token -d refresh_token='<el copiado>' | grep invalid_grant
```

**Evidencia:** ese `grep` encuentra `invalid_grant`. Si el refresco funciona, la
revocación no ocurrió y el borrado fue solo local.

## 7. Proyectos de una cuenta que no es la activa

- [ ] En el selector de proyectos por cuenta, elegir una cuenta **no activa**
      lista **sus** proyectos, no los de la activa.

**Evidencia:** los dos conjuntos de proyectos son distintos. Si ambas cuentas
ven los mismos proyectos, este ítem no prueba nada: usa dos cuentas con acceso a
proyectos distintos, o el ítem queda como no verificado.

## 8. No hay regresión con el motor gcloud

Relanza **sin** `LCC_AUTH_ENGINE`:

- [ ] El diálogo de cuentas se comporta exactamente como antes de D4:
      lista, cambia, añade y quita.

**Evidencia:** la lista coincide con `gcloud auth list`, incluida la cuenta que
en el ítem 1 no aparecía.
````

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/plans/2026-08-17-sgd-d4-native-accounts-manual-qa.md
git commit -m "docs(qa): manual QA checklist for SG-D/D4 native accounts

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Cierre

Tras la tarea 7, antes de dar D4 por terminado:

1. `cd native && cargo test` — verde, sin warnings nuevos.
2. `flutter analyze` — cero líneas `error •`.
3. `flutter test` — `All tests passed!`
4. Subir `kBuild` en `lib/src/version.dart` y compilar `cargo build --release` + `flutter build linux --release` para que el usuario pueda ejecutar el QA manual.
5. Revisión final de toda la rama.

El **criterio de corte** no es que la suite esté verde: es el checklist de la
tarea 7 ejecutado, y en particular los ítems 1, 2, 3 y 6. Sin la divergencia
demostrada en los dos sentidos, D4 no está verificado.
