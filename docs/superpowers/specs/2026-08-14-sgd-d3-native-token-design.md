# Diseño: SG-D / D3 — adquisición de token nativa (login→almacén, refresco y reauth)

**Fecha:** 2026-08-14
**Rama objetivo:** `27H1-Preview`
**Estado:** Aprobado
**Tipo:** Cambio Rust interno (sin bridge, sin Dart). Tercera pieza de **SG-D** — ver `docs/superpowers/specs/2026-08-12-gcloud-removal-roadmap.md`.

## Objetivo

Cerrar el ciclo de sesión propia: guardar la cuenta tras el login de D1, obtener access tokens refrescando el refresh token guardado por D2, y recuperarse cuando Google lo rechaza. Todo detrás de un flag, con gcloud intacto como comportamiento por defecto.

Es la pieza donde el antiguo **SG-C** queda absorbido: el token nativo solo es viable ahora que existe un login interactivo propio al que recurrir cuando Workspace exige reautenticación — la causa del `invalid_rapt` que bloqueó SG-C como paso independiente.

## Contexto (verificado)

- **Punto de integración único:** `GcpAuthClient::get_access_token()` (`native/src/gcp_rest_client.rs:148`). Los 10 call sites del crate (5 en `doctor.rs`, 4 en `gcp_rest_client.rs`) pasan por ahí. Hoy: `gcloud auth print-access-token` primero, refresco de ADC como fallback.
- **`TOKEN_CACHE`** (`gcp_rest_client.rs:94`) es un `tokio::sync::Mutex<Option<CachedToken>>` con TTL de 300 s. El lock se sostiene durante toda la obtención: sirve de caché **y** serializa. `invalidate_cached_access_token()` (`:100`) **toma ese mismo lock** — llamarla mientras se sostiene sería un deadlock (el mutex de tokio no es reentrante).
- **D1 aporta** `interactive_login() -> Result<OAuthTokens>` (`oauth.rs:320`), con `OAuthTokens { email, refresh_token, access_token, expires_in_secs }`. Las constantes `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET` y `TOKEN_ENDPOINT` son **privadas** de `oauth.rs`.
- **D2 aporta** `save_account`, `load_refresh_token`, `list_accounts`, `delete_account`, `active_account`, `set_active_account` — todas **síncronas**.
- **Trampa documentada por la revisión de D2:** la feature `tokio` de keyring/zbus usa un runtime propio vía `block_on`, que **paniquea** ("Cannot start a runtime from within a runtime") si se llama a `token_store` desde un worker de tokio ya activo. `get_access_token()` es async y corre exactamente ahí.
- **Nada conecta aún D1 con D2**: el almacén está siempre vacío, así que un D3 que solo leyera sería intestable.

## Decisiones

| Decisión | Elección |
|---|---|
| Flag | `LCC_AUTH_ENGINE=native` opta al camino nativo; sin variable (o `gcloud`) → comportamiento actual intacto. Precedente: `LCC_TUNNEL_ENGINE`, `LCC_SSH_FORWARD_ENGINE`. |
| Fallback | **Ninguno.** Con el flag activo el token sale solo del refresh token propio; si falla, error claro. Nunca se cae a gcloud en silencio (mismo criterio que SG-B). |
| Alcance | Ciclo cerrado: **login→almacén + refresco + reauth**. Sin ese puente el almacén nunca se llena. |
| Dónde se relanza el login | En una función **explícita** (`ensure_signed_in`), **nunca** dentro de `get_access_token()`. |
| Llamadas a `token_store` | **Siempre** vía `tokio::task::spawn_blocking`. |
| Constantes OAuth | El refresco vive **en `oauth.rs`**, así las constantes siguen privadas. |
| Bridge / Dart / UI | Sin cambios. |

## Diseño

### 1. El flag (`native/src/oauth.rs`)

Helper puro + wrapper, espejo de `parse_tunnel_engine` en `tunnel.rs`:

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthEngine { Gcloud, Native }

/// Pure parse of the auth engine selector (testable without env).
/// gcloud is the default; only an explicit `native` opts in.
fn parse_auth_engine(val: Option<&str>) -> AuthEngine {
    match val {
        Some("native") => AuthEngine::Native,
        _ => AuthEngine::Gcloud,
    }
}

pub fn auth_engine() -> AuthEngine {
    parse_auth_engine(std::env::var("LCC_AUTH_ENGINE").ok().as_deref())
}
```

Nótese la polaridad **inversa** a `parse_tunnel_engine`: allí Native es el default; aquí lo nativo es opt-in, porque la autenticación aún no se ha validado en campo. D5 invertirá esta polaridad.

### 2. Refresco del access token (`oauth.rs`)

```rust
pub struct RefreshedToken {
    pub access_token: String,
    pub expires_in_secs: u64,
}

/// Exchange a stored refresh token for an access token. No browser involved.
pub async fn refresh_access_token(refresh_token: &str) -> Result<RefreshedToken>;
```

`POST` a `TOKEN_ENDPOINT` con `grant_type=refresh_token`, `client_id`, `client_secret` (no vacío) y `refresh_token`, reutilizando el cliente HTTP con timeout de 30 s del canje de D1. El cuerpo de un error no-200 pasa por `redact_sensitive` antes de aparecer en ningún mensaje.

**Clasificación del fallo** — función pura y testeable:

```rust
/// Whether a non-200 token response means the stored refresh token is dead and
/// only an interactive sign-in can recover (as opposed to a transient failure).
fn refresh_failure_needs_reauth(body: &str) -> bool;
```

Devuelve `true` para `invalid_grant` (revocado, caducado, o reauth de Workspace exigida) y para el `rapt_required`/`invalid_rapt` de cuentas corporativas; `false` para el resto (5xx, red), que se tratan como transitorios.

### 3. El puente D1→D2 (`oauth.rs`)

```rust
/// Run the interactive sign-in and persist the account. Returns the e-mail.
pub async fn sign_in_and_store() -> Result<String>;
```

`interactive_login()` y luego `token_store::save_account(&email, &refresh_token)` **dentro de `spawn_blocking`**. Recuerda que `save_account` marca la cuenta como activa solo si no había ninguna (regla de D2).

### 4. Recuperación explícita (`oauth.rs`)

```rust
/// Ensure there is a usable session: refresh the active account's token and,
/// if the refresh token is rejected, run the interactive sign-in again.
/// Returns the e-mail of the usable account.
pub async fn ensure_signed_in() -> Result<String>;
```

Sin cuenta activa → `sign_in_and_store()`. Con cuenta activa → intenta `refresh_access_token`; si `refresh_failure_needs_reauth`, vuelve a firmar y guardar; si el fallo es transitorio, lo propaga sin abrir navegador.

Al terminar con éxito llama a `invalidate_cached_access_token()` para que el caché no sirva un token de la sesión anterior. **Nunca se llama sosteniendo el lock de `TOKEN_CACHE`** — de ahí que `ensure_signed_in` viva fuera de `get_access_token`.

**El refresco de `ensure_signed_in` es un sondeo y su token se descarta.** Es deliberado: solo intentando el refresco se descubre que el refresh token está rechazado, que es justo lo que esta función existe para detectar y arreglar. El coste es un canje extra; la siguiente llamada a `get_access_token` hará el suyo y cacheará. **No** se debe "optimizar" pasando ese token al caché desde fuera: `ensure_signed_in` corre fuera del lock, y hacerlo reintroduciría el riesgo de deadlock que motiva esta separación.

### 5. El camino nativo en `get_access_token()`

Con `auth_engine() == Native`, dentro del lock de `TOKEN_CACHE` que ya existe (caché + serialización), y tras el chequeo de frescura actual:

1. `active_account()` (en `spawn_blocking`) → si es `None`, error accionable: no hay sesión iniciada; hay que ejecutar el login.
2. `load_refresh_token(email)` (en `spawn_blocking`).
3. `refresh_access_token(...)` → cachear y devolver.
4. Si `refresh_failure_needs_reauth`, devolver un error de **reauth reconocible**, con un texto estable que D4 podrá clasificar y enganchar al `GcpSessionBanner` existente.

**No** se relanza el navegador aquí: esta función la llaman chequeos de salud en segundo plano y el Doctor; abrir un navegador desde una llamada arbitraria sería una sorpresa. El camino gcloud actual queda **intacto** cuando el flag está apagado.

## Errores

Cuatro casos distinguibles, en inglés (la localización llega en D4):

- **Sin cuenta activa**: indica que no hay sesión propia y que hay que iniciarla.
- **Reauth necesaria** (refresh token rechazado): texto estable para que D4 lo clasifique; nunca se confunde con un fallo de red.
- **Fallo transitorio del refresco** (5xx, red, timeout): se propaga tal cual, sin sugerir reauth.
- **Keyring no disponible**: llega de D2 con su mensaje accionable, sin reinterpretar.

## Testing

- **Puros (`cargo test`)**: `parse_auth_engine` (unset / `native` / `gcloud` / basura → default gcloud) y `refresh_failure_needs_reauth` (cuerpos con `invalid_grant`, `rapt_required`, un 5xx y un error de red → clasificación correcta).
- **Ejemplo ejecutable** `native/examples/auth_native.rs` (patrón de `oauth_login.rs`): ejecuta `ensure_signed_in()`, luego un `get_access_token()` con el flag puesto, e imprime el email y un prefijo corto del access token. Es el QA end-to-end del ciclo cerrado, incluida la persistencia entre ejecuciones (la segunda vez **no** debe abrir el navegador).
- **QA manual**: con `LCC_AUTH_ENGINE=native`, la app lista proyectos e instancias sin que intervenga gcloud; sin la variable, todo se comporta como hoy.
- `cargo build --release` sin warnings nuevos y `flutter test` intacto (D3 no toca Dart).

## Alcance / fuera de alcance

- **Dentro:** el flag y su parseo; `refresh_access_token` + `refresh_failure_needs_reauth`; `sign_in_and_store`; `ensure_signed_in`; el camino nativo en `get_access_token`; `spawn_blocking` en toda llamada a `token_store`; el ejemplo; tests puros.
- **Fuera:** bridge, UI y enganche del banner de reauth (**D4**); poner lo nativo por defecto y retirar gcloud (**D5**); multi-cuenta y cambio de cuenta (**D4**); revocación/logout; localización de los mensajes.

## Verificación

- `cargo test` verde con los tests puros nuevos; `cargo build --release` limpio; `flutter test` verde.
- Con el flag apagado, `get_access_token` se comporta exactamente como hoy (camino gcloud sin tocar).
- `cargo run --example auth_native` completa el ciclo, y una **segunda** ejecución obtiene token **sin abrir el navegador** — la prueba de que el refresco desde el almacén funciona.
- Ninguna llamada a `token_store` ocurre fuera de `spawn_blocking`.
